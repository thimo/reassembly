//
//  LivePhotoFixture.swift
//  ReassemblyTests
//
//  Fabriceert een echte Live Photo voor tests: een still (JPEG met Apple
//  maker-note 17) plus een gekoppelde video (MOV met dezelfde content
//  identifier en een still-image-time-metadatatrack). Samen als .photo +
//  .pairedVideo aan PHAssetCreationRequest voeren levert een asset met
//  mediaSubtype .photoLive op.
//

import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum LivePhotoFixture {

    /// Maakt still + video in de temp-map; opruimen is aan de aanroeper.
    static func make() async throws -> (stillURL: URL, videoURL: URL) {
        let id = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
        let stillURL = dir.appendingPathComponent("live-\(id).jpg")
        let videoURL = dir.appendingPathComponent("live-\(id).mov")
        try writeStill(to: stillURL, identifier: id)
        try await writeVideo(to: videoURL, identifier: id)
        return (stillURL, videoURL)
    }

    /// Liggende (400×300) effen still met de content identifier in de Apple
    /// maker note (sleutel "17" — daar zoekt Photos 'm).
    private static func writeStill(to url: URL, identifier: String) throws {
        let size = CGSize(width: 400, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let cg = image.cgImage,
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }

        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
        ]
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Eén seconde effen video met de twee Live Photo-metadata-ingrediënten:
    /// de content identifier op containerniveau en een timed-metadata-track
    /// met still-image-time.
    private static func writeVideo(to url: URL, identifier: String) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let idItem = AVMutableMetadataItem()
        idItem.key = "com.apple.quicktime.content.identifier" as NSString
        idItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        idItem.value = identifier as NSString
        idItem.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [idItem]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 400,
            AVVideoHeightKey: 300,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 400,
                kCVPixelBufferHeightKey as String: 300,
            ])
        writer.add(videoInput)

        var desc: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
                    "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
                    "com.apple.metadata.datatype.int8",
            ]] as CFArray,
            formatDescriptionOut: &desc)
        let metaInput = AVAssetWriterInput(
            mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
        let metaAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)
        writer.add(metaInput)

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        let stillTime = AVMutableMetadataItem()
        stillTime.key = "com.apple.quicktime.still-image-time" as NSString
        stillTime.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        stillTime.value = 0 as NSNumber
        stillTime.dataType = "com.apple.metadata.datatype.int8"
        metaAdaptor.append(AVTimedMetadataGroup(
            items: [stillTime],
            timeRange: CMTimeRange(start: .zero,
                                   duration: CMTime(value: 1, timescale: 100))))

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 400, 300, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        for frame in 0..<30 {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        videoInput.markAsFinished()
        metaInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}
