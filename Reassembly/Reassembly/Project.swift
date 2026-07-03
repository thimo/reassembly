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
    /// Aantal onderliggende albums/folders (nil voor albums).
    var childCount: Int? = nil
    /// Datum nieuwste asset — de "laatste activiteit" waarop we sorteren.
    let lastActivity: Date?
    /// Datum oudste asset — benadering van aanmaakdatum (alternatieve sortering).
    let firstActivity: Date?

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }
}

extension Project: Hashable {
    static func == (lhs: Project, rhs: Project) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
