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

    /// Rotatie end-to-end: liggende testfoto de library in, 90° draaien via de
    /// store, en controleren dat breedte/hoogte gewisseld zijn.
    ///
    /// Geen cleanup: een asset verwijderen toont een systeem-bevestiging die
    /// een unit-test niet kan wegtikken. De testfoto blijft dus achter op de
    /// (dedicated, wegwerpbare) testsimulator.
    @Test @MainActor func rotateSwapsDimensions() async throws {
        let store = PhotoLibraryStore()
        try #require(store.hasFullAccess, "Testsimulator heeft geen Photos-toegang")

        // Liggende foto (400×300) zodat de wissel meetbaar is.
        let size = CGSize(width: 400, height: 300)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.systemPurple.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            id = request.placeholderForCreatedAsset?.localIdentifier
        }
        let assetID = try #require(id)
        let asset = try #require(PHAsset
            .fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
        #expect(asset.pixelWidth == 400)
        #expect(asset.pixelHeight == 300)

        try await store.rotateClockwise(asset)

        let rotated = try #require(PHAsset
            .fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject)
        #expect(rotated.pixelWidth == 300, "Breedte niet gewisseld na rotatie")
        #expect(rotated.pixelHeight == 400, "Hoogte niet gewisseld na rotatie")
    }
}
