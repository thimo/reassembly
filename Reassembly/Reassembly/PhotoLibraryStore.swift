//
//  PhotoLibraryStore.swift
//  Reassembly
//
//  Photos ís de database. Deze store leest de hiërarchie onder de root-folder
//  "Reassembly" en schrijft er albums/folders bij — verder geen eigen state.
//

import Photos
import Observation
import UIKit
import CoreLocation
import UniformTypeIdentifiers

@Observable
@MainActor
final class PhotoLibraryStore: NSObject, PHPhotoLibraryChangeObserver {

    /// Naam van de root-folder in Photos waar al onze projecten onder hangen.
    static let rootFolderName = "Re-assembly"

    private(set) var authorization: PHAuthorizationStatus =
        PHPhotoLibrary.authorizationStatus(for: .readWrite)

    /// Wordt opgehoogd bij elke library-wijziging; views die ernaar kijken
    /// herladen hun eigen niveau. Zo blijft de hele boom in sync zonder dat de
    /// store alle niveaus tegelijk in geheugen houdt.
    private(set) var changeToken = 0

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - Toegang

    /// Volledige toegang is vereist: bij `.limited` ziet PhotoKit alleen de
    /// handmatig gedeelde foto's en kun je geen albums aanmaken/uitlezen.
    var hasFullAccess: Bool { authorization == .authorized }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Lezen

    /// Kinderen (albums + folders) van een niveau. `parent == nil` = de root;
    /// bestaat de root nog niet, dan is de lijst leeg.
    func children(of parent: PHCollectionList?) -> [Project] {
        guard hasFullAccess else { return [] }
        guard let target = parent ?? findRootFolder() else { return [] }
        return childProjects(of: target)
    }

    /// Zoekt een album of folder op localIdentifier — voor navigatie-herstel.
    /// Geeft nil als het item niet (meer) bestaat.
    func project(withLocalIdentifier id: String) -> Project? {
        guard hasFullAccess else { return nil }
        if let album = PHAssetCollection
            .fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
            .firstObject {
            return makeProject(album: album)
        }
        if let folder = PHCollectionList
            .fetchCollectionLists(withLocalIdentifiers: [id], options: nil)
            .firstObject {
            return makeProject(folder: folder)
        }
        return nil
    }

    /// De recentst gebruikte albums, waar ook in de boom — voor de dynamische
    /// shortcut items op het app-icoon.
    func recentAlbums(limit: Int) -> [Project] {
        guard hasFullAccess, let root = findRootFolder() else { return [] }
        return Array(
            collectAlbums(in: root)
                .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
                .prefix(limit)
        )
    }

    private func collectAlbums(in folder: PHCollectionList) -> [Project] {
        var result: [Project] = []
        PHCollection.fetchCollections(in: folder, options: nil)
            .enumerateObjects { collection, _, _ in
                if let album = collection as? PHAssetCollection {
                    result.append(self.makeProject(album: album))
                } else if let list = collection as? PHCollectionList {
                    result.append(contentsOf: self.collectAlbums(in: list))
                }
            }
        return result
    }

    /// Navigatiepad (root → album) naar een album, voor quick actions. Loopt
    /// omhoog langs de parent-folders tot aan de root; nil als het album niet
    /// (meer) bestaat.
    func path(toAlbumWithIdentifier id: String) -> [Project]? {
        guard hasFullAccess,
              let album = PHAssetCollection
                  .fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
                  .firstObject
        else { return nil }

        var chain: [Project] = [makeProject(album: album)]
        let rootID = findRootFolder()?.localIdentifier
        var current: PHCollection = album
        while let parent = PHCollectionList
            .fetchCollectionListsContaining(current, options: nil)
            .firstObject {
            if parent.localIdentifier == rootID { break }
            chain.insert(makeProject(folder: parent), at: 0)
            current = parent
        }
        return chain
    }

    private func findRootFolder() -> PHCollectionList? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", Self.rootFolderName)
        return PHCollectionList
            .fetchCollectionLists(with: .folder, subtype: .any, options: options)
            .firstObject
    }

    private func childProjects(of folder: PHCollectionList) -> [Project] {
        var result: [Project] = []
        PHCollection.fetchCollections(in: folder, options: nil)
            .enumerateObjects { collection, _, _ in
                if let album = collection as? PHAssetCollection {
                    result.append(self.makeProject(album: album))
                } else if let list = collection as? PHCollectionList {
                    result.append(self.makeProject(folder: list))
                }
            }
        // Sorteren op laatste activiteit, nieuwste bovenaan. Lege items
        // (lastActivity nil) zet de view in een aparte sectie "Leeg".
        return result.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    private func makeProject(album: PHAssetCollection) -> Project {
        let count = PHAsset.fetchAssets(in: album, options: nil).count
        return Project(
            id: album.localIdentifier,
            title: album.localizedTitle ?? "Naamloos album",
            kind: .album(album),
            assetCount: count,
            lastActivity: newestAssetDate(in: album),
            firstActivity: oldestAssetDate(in: album)
        )
    }

    private func makeProject(folder: PHCollectionList) -> Project {
        let childCount = PHCollection.fetchCollections(in: folder, options: nil).count
        return Project(
            id: folder.localIdentifier,
            title: folder.localizedTitle ?? "Naamloze folder",
            kind: .folder(folder),
            assetCount: nil,
            childCount: childCount,
            // Activiteit = nieuwste asset ergens onder deze folder (recursief).
            lastActivity: newestAssetDate(inFolder: folder),
            firstActivity: nil
        )
    }

    /// Datum van de nieuwste foto in een album.
    private func newestAssetDate(in album: PHAssetCollection) -> Date? {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        return PHAsset.fetchAssets(in: album, options: opts).firstObject?.creationDate
    }

    /// Datum van de oudste foto in een album (≈ aanmaak).
    private func oldestAssetDate(in album: PHAssetCollection) -> Date? {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.fetchLimit = 1
        return PHAsset.fetchAssets(in: album, options: opts).firstObject?.creationDate
    }

    /// Nieuwste asset ergens onder een folder — recursief door subfolders heen.
    private func newestAssetDate(inFolder folder: PHCollectionList) -> Date? {
        var newest: Date?
        PHCollection.fetchCollections(in: folder, options: nil)
            .enumerateObjects { collection, _, _ in
                let candidate: Date?
                if let album = collection as? PHAssetCollection {
                    candidate = self.newestAssetDate(in: album)
                } else if let list = collection as? PHCollectionList {
                    candidate = self.newestAssetDate(inFolder: list)
                } else {
                    candidate = nil
                }
                if let candidate, newest == nil || candidate > newest! {
                    newest = candidate
                }
            }
        return newest
    }

    // MARK: - Schrijven

    /// Maakt een nieuw album aan en geeft het terug (voor meteen openen).
    /// `parent == nil` = onder de root.
    @discardableResult
    func createAlbum(named name: String, in parent: PHCollectionList?) async throws -> Project? {
        let target = try await resolvedParent(parent)
        var newID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let albumRequest = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: name)
            let placeholder = albumRequest.placeholderForCreatedAssetCollection
            newID = placeholder.localIdentifier
            PHCollectionListChangeRequest(for: target)?
                .addChildCollections([placeholder] as NSArray)
        }
        changeToken &+= 1
        guard let id = newID,
              let album = PHAssetCollection
                  .fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
                  .firstObject
        else { return nil }
        return makeProject(album: album)
    }

    /// Maakt een nieuwe (sub)folder aan en geeft 'm terug (voor meteen openen).
    /// `parent == nil` = onder de root.
    @discardableResult
    func createFolder(named name: String, in parent: PHCollectionList?) async throws -> Project? {
        let target = try await resolvedParent(parent)
        var newID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let folderRequest = PHCollectionListChangeRequest
                .creationRequestForCollectionList(withTitle: name)
            let placeholder = folderRequest.placeholderForCreatedCollectionList
            newID = placeholder.localIdentifier
            PHCollectionListChangeRequest(for: target)?
                .addChildCollections([placeholder] as NSArray)
        }
        changeToken &+= 1
        guard let id = newID,
              let folder = PHCollectionList
                  .fetchCollectionLists(withLocalIdentifiers: [id], options: nil)
                  .firstObject
        else { return nil }
        return makeProject(folder: folder)
    }

    /// Hernoemt een album of folder.
    func rename(_ project: Project, to newName: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            switch project.kind {
            case .album(let album):
                PHAssetCollectionChangeRequest(for: album)?.title = newName
            case .folder(let folder):
                PHCollectionListChangeRequest(for: folder)?.title = newName
            }
        }
        changeToken &+= 1
    }

    /// Geeft de opgegeven parent terug, of de (zo nodig aangemaakte) root.
    private func resolvedParent(_ parent: PHCollectionList?) async throws -> PHCollectionList {
        if let parent { return parent }
        return try await ensuredRootFolder()
    }

    /// Zoekt de root-folder of maakt 'm aan als die nog niet bestaat.
    private func ensuredRootFolder() async throws -> PHCollectionList {
        if let existing = findRootFolder() { return existing }

        var newID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHCollectionListChangeRequest
                .creationRequestForCollectionList(withTitle: Self.rootFolderName)
            newID = request.placeholderForCreatedCollectionList.localIdentifier
        }
        if let id = newID,
           let created = PHCollectionList
               .fetchCollectionLists(withLocalIdentifiers: [id], options: nil)
               .firstObject {
            return created
        }
        if let existing = findRootFolder() { return existing }
        throw CocoaError(.featureUnsupported)
    }

    /// Verwijdert één foto uit de bibliotheek. iOS toont zelf de bevestiging;
    /// de foto belandt 30 dagen in "Recent verwijderd".
    func deleteAsset(_ asset: PHAsset) async throws {
        try await deleteAssets([asset])
    }

    /// Verwijdert meerdere foto's in één actie — dus één systeem-bevestiging in
    /// plaats van één per foto. Belanden 30 dagen in "Recent verwijderd".
    func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        changeToken &+= 1
    }

    /// Voegt een gemaakte foto (ruwe capture-data, met EXIF) toe aan een album,
    /// met optionele geotag. In-app camera's geotaggen niet vanzelf, dus we
    /// zetten de locatie zelf op de asset.
    func addPhoto(data: Data, location: CLLocation?, to album: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            request.location = location
            if let placeholder = request.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?
                    .addAssets([placeholder] as NSArray)
            }
        }
        changeToken &+= 1
    }

    // MARK: - Bewerken

    /// Draait een foto 90° met de klok mee. Non-destructief via Photos' eigen
    /// edit-pijplijn: het origineel blijft bewaard en "Herstel" in de Photos-app
    /// blijft werken. Eerdere bewerkingen worden ingebakken (wij lezen andermans
    /// adjustment data niet).
    func rotateClockwise(_ asset: PHAsset) async throws {
        let input = try await editingInput(for: asset)
        guard let url = input.fullSizeImageURL,
              let original = CIImage(contentsOf: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let upright = original.oriented(forExifOrientation: input.fullSizeImageOrientation)
        let rotated = upright.oriented(.right)

        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "nl.defrog.reassembly.rotate",
            formatVersion: "1",
            data: Data("cw90".utf8))
        // Photos bepaalt per asset/apparaat welk uitvoerformaat het wil (JPEG
        // op de simulator, HEIC voor camerafoto's op toestellen); schrijf dat
        // formaat, anders keurt Photos de edit af (3302 invalidResource).
        let type = output.defaultRenderedContentType ?? .jpeg
        let renderURL = try output.renderedContentURL(for: type)
        let colorSpace = rotated.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext()
        if type.conforms(to: .heic) || type.conforms(to: .heif) {
            try context.writeHEIFRepresentation(
                of: rotated, to: renderURL, format: .RGBA8, colorSpace: colorSpace)
        } else {
            try context.writeJPEGRepresentation(
                of: rotated, to: renderURL, colorSpace: colorSpace)
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
        changeToken &+= 1
    }

    /// Async-wrapper om de callback-API van PhotoKit; haalt zo nodig het
    /// origineel uit iCloud.
    private func editingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { _ in false }
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    let error = (info[PHContentEditingInputErrorKey] as? Error)
                        ?? CocoaError(.fileReadUnknown)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Verwijderen

    /// Verwijdert een project inclusief alle foto's, in één actie. iOS toont
    /// zelf de bevestiging voor de foto's — geen eigen confirm nodig.
    ///
    /// Let op: foto's verdwijnen library-breed (ook uit andere albums) en
    /// belanden 30 dagen in "Recent verwijderd" — herstelbaar.
    func delete(_ project: Project) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            switch project.kind {
            case .album(let album):   self.addDeletes(forAlbum: album)
            case .folder(let folder): self.addDeletes(forFolder: folder)
            }
        }
        changeToken &+= 1
    }

    /// Voegt de delete-requests voor één album + z'n foto's toe aan het lopende
    /// performChanges-blok.
    private func addDeletes(forAlbum album: PHAssetCollection) {
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        if assets.count > 0 {
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }
        PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
    }

    /// Recursief: alle onderliggende albums (met foto's) en subfolders, dan de
    /// folder zelf.
    private func addDeletes(forFolder folder: PHCollectionList) {
        PHCollection.fetchCollections(in: folder, options: nil)
            .enumerateObjects { collection, _, _ in
                if let album = collection as? PHAssetCollection {
                    self.addDeletes(forAlbum: album)
                } else if let list = collection as? PHCollectionList {
                    self.addDeletes(forFolder: list)
                }
            }
        PHCollectionListChangeRequest.deleteCollectionLists([folder] as NSArray)
    }

    // MARK: - PHPhotoLibraryChangeObserver

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // De gebruiker (of iCloud-sync) kan de structuur in Photos zelf wijzigen.
        Task { @MainActor in self.changeToken &+= 1 }
    }
}
