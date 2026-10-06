//
//  DemoSeed.swift
//  Reassembly
//
//  Fills an empty simulator library with demo projects for App Store
//  screenshots. Debug builds only; triggered by the `--seed-demo` launch
//  argument plus the `REASSEMBLY_SEED_DIR` environment variable. The directory
//  holds one subdirectory per album; a `__` in the name nests it in a folder
//  ("Energica SS9__Accu" → folder "Energica SS9", album "Accu"). The simulator
//  has no camera, so this is the only way to get photos into the grid.
//

#if DEBUG
import Foundation
import Photos

enum DemoSeed {

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--seed-demo")
            && ProcessInfo.processInfo.environment["REASSEMBLY_SEED_DIR"] != nil
    }

    /// Idempotent: does nothing when the root folder already has children.
    @MainActor
    static func run(store: PhotoLibraryStore) async {
        guard isRequested,
              let dir = ProcessInfo.processInfo.environment["REASSEMBLY_SEED_DIR"],
              store.children(of: nil).isEmpty
        else { return }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        var folders: [String: PHCollectionList] = [:]

        // Oldest album first, so the project list ends up sorted the way the
        // directory names are.
        for (albumIndex, entry) in entries.sorted().reversed().enumerated() {
            let albumDir = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: albumDir, isDirectory: &isDir), isDir.boolValue else { continue }

            let parts = entry.components(separatedBy: "__")
            var parent: PHCollectionList?
            if parts.count == 2 {
                if let existing = folders[parts[0]] {
                    parent = existing
                } else if let created = try? await store.createFolder(named: parts[0], in: nil),
                          case .folder(let list) = created.kind {
                    folders[parts[0]] = list
                    parent = list
                }
            }

            guard let project = try? await store.createAlbum(named: parts.last ?? entry, in: parent),
                  case .album(let album) = project.kind
            else { continue }

            let files = ((try? fm.contentsOfDirectory(atPath: albumDir)) ?? [])
                .filter { $0.lowercased().hasSuffix(".jpeg") || $0.lowercased().hasSuffix(".jpg") }
                .sorted()
            // Spread each album over two days so the grid shows day headers,
            // and stagger albums so "latest activity" ordering is visible.
            let albumBase = Date().addingTimeInterval(-Double(albumIndex) * 3 * 86_400)
            for (photoIndex, file) in files.enumerated() {
                let path = (albumDir as NSString).appendingPathComponent(file)
                guard let data = fm.contents(atPath: path) else { continue }
                let dayOffset: Double = photoIndex < files.count / 2 ? -86_400 : 0
                let date = albumBase.addingTimeInterval(dayOffset - Double(files.count - photoIndex) * 420)
                try? await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                    request.creationDate = date
                    if let placeholder = request.placeholderForCreatedAsset {
                        PHAssetCollectionChangeRequest(for: album)?
                            .addAssets([placeholder] as NSArray)
                    }
                }
            }
        }
    }
}
#endif
