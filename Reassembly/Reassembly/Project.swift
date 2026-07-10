//
//  Project.swift
//  Reassembly
//

import Photos

/// Een knoop in de Photos-hiërarchie onder de root-folder "Reassembly":
/// een album (bevat foto's) of een folder (kan nesten).
///
/// `id` is voorlopig de `localIdentifier` — stabiel binnen dit device, prima
/// als SwiftUI-identiteit. Voor cross-device verwijzingen komen later cloud
/// identifiers; die slaan we pas op als we echt eigen state nodig hebben.
struct Project: Identifiable {
    enum Kind {
        case album(PHAssetCollection)
        case folder(PHCollectionList)
    }

    let id: String
    let title: String
    let kind: Kind

    /// Aantal foto's (nil voor folders).
    let assetCount: Int?
    /// Nieuwste foto's (max 3, nieuwste eerst) voor de stapel in de lijst;
    /// leeg voor folders en lege albums.
    var coverAssets: [PHAsset] = []
    /// Aantal subfolders resp. albums direct hieronder (nil voor albums).
    var folderCount: Int? = nil
    var albumCount: Int? = nil
    /// Datum nieuwste asset — de "laatste activiteit" waarop we sorteren.
    let lastActivity: Date?
    /// Datum oudste asset — benadering van aanmaakdatum (alternatieve sortering).
    let firstActivity: Date?

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }
}

extension Project {
    /// Nette inhoudsomschrijving van een folder: "1 folder, 2 albums",
    /// "2 albums", of "leeg". Gebruikt in de titelbalk én de rij-subtitel.
    static func contentsLabel(folders: Int, albums: Int) -> String {
        let folderPart = folders == 1
            ? String(localized: "1 folder")
            : String(localized: "\(folders) folders")
        let albumPart = albums == 1
            ? String(localized: "1 album")
            : String(localized: "\(albums) albums")
        switch (folders > 0, albums > 0) {
        case (true, true):   return "\(folderPart), \(albumPart)"
        case (true, false):  return folderPart
        case (false, true):  return albumPart
        case (false, false): return String(localized: "empty")
        }
    }
}

extension Project: Hashable {
    static func == (lhs: Project, rhs: Project) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
