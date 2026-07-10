//
//  ReassemblyTests.swift
//  ReassemblyTests
//
//  Draait in de app-host op de testsimulator en kan dus echt tegen PhotoKit
//  aan (Photos-permissie is daar eenmalig toegekend, zie UI-test-opzet).
//

import Testing
import Photos
import UIKit
@testable import Reassembly

struct ReassemblyTests {

    /// Rotatie end-to-end met een JPEG-foto (zoals de simulator-camera).
    @Test @MainActor func rotateSwapsDimensions() async throws {
        let data = Self.testImage.jpegData(compressionQuality: 0.9)!
        try await assertRotateSwapsDimensions(data: data)
    }

    /// Zelfde, maar met HEIC — het formaat van echte camerafoto's. Ving de
    /// device-bug waarbij Photos JPEG-bytes in een HEIC-bestemming afkeurde
    /// (PHPhotosErrorDomain 3302 invalidResource).
    @Test @MainActor func rotateSwapsDimensionsForHEIC() async throws {
        let ciImage = CIImage(image: Self.testImage)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotatetest-\(UUID().uuidString).heic")
        try CIContext().writeHEIFRepresentation(
            of: ciImage, to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertRotateSwapsDimensions(data: Data(contentsOf: url))
    }

    /// Zelfde, maar met een Live Photo — het pad via PHLivePhotoEditingContext.
    /// Reproduceert het toestel-scenario (foto's uit de standaard Camera-app
    /// zijn Live) dat op het toestel met 3302 faalde.
    @Test @MainActor func rotateSwapsDimensionsForLivePhoto() async throws {
        let store = PhotoLibraryStore()
        try #require(store.hasFullAccess, "Testsimulator heeft geen Photos-toegang")

        let (stillURL, videoURL) = try await LivePhotoFixture.make()
        defer {
            try? FileManager.default.removeItem(at: stillURL)
            try? FileManager.default.removeItem(at: videoURL)
        }

        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: stillURL, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            id = request.placeholderForCreatedAsset?.localIdentifier
        }
        let assetID = try #require(id)
        let asset = try #require(PHAsset
            .fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
        try #require(asset.mediaSubtypes.contains(.photoLive),
                     "Fixture is geen Live Photo geworden")
        let width = asset.pixelWidth
        let height = asset.pixelHeight
        #expect(width > height, "Testfoto hoort liggend te zijn")

        try await store.rotateCounterclockwise(asset)

        let rotated = try #require(PHAsset
            .fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
        #expect(rotated.pixelWidth == height, "Breedte niet gewisseld na rotatie")
        #expect(rotated.pixelHeight == width, "Hoogte niet gewisseld na rotatie")
        #expect(rotated.mediaSubtypes.contains(.photoLive),
                "Foto is z'n liveness kwijt na rotatie")
    }

    /// Liggende testfoto (400×300) zodat de wissel meetbaar is. Scale expliciet
    /// op 1: de renderer volgt anders de schermschaal van de simulator.
    @MainActor
    private static var testImage: UIImage {
        let size = CGSize(width: 400, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemPurple.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Testfoto de library in, 90° draaien via de store, en controleren dat
    /// breedte/hoogte gewisseld zijn.
    ///
    /// Geen cleanup: een asset verwijderen toont een systeem-bevestiging die
    /// een unit-test niet kan wegtikken. De testfoto blijft dus achter op de
    /// (dedicated, wegwerpbare) testsimulator.
    @MainActor
    private func assertRotateSwapsDimensions(data: Data) async throws {
        let store = PhotoLibraryStore()
        try #require(store.hasFullAccess, "Testsimulator heeft geen Photos-toegang")

        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            id = request.placeholderForCreatedAsset?.localIdentifier
        }
        let assetID = try #require(id)
        let asset = try #require(PHAsset
            .fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
        let width = asset.pixelWidth
        let height = asset.pixelHeight
        #expect(width > height, "Testfoto hoort liggend te zijn")

        try await store.rotateCounterclockwise(asset)

        let rotated = try #require(PHAsset
            .fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
        #expect(rotated.pixelWidth == height, "Breedte niet gewisseld na rotatie")
        #expect(rotated.pixelHeight == width, "Hoogte niet gewisseld na rotatie")
    }
}
