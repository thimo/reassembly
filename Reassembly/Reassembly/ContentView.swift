//
//  ContentView.swift
//  Reassembly
//
//  Root: kiest tussen de projectenlijst en de permissie-gate op basis van de
//  Photos-autorisatie.
//

import SwiftUI
import Photos

struct ContentView: View {
    @State private var store = PhotoLibraryStore()

    var body: some View {
        Group {
            if store.hasFullAccess {
                ProjectsListView(store: store)
            } else {
                PermissionGate(store: store)
            }
        }
    }
}

/// Toont de juiste boodschap per autorisatie-status. Deze app heeft volledige
/// toegang nodig: albums aanmaken/uitlezen kan niet in de limited-modus.
private struct PermissionGate: View {
    let store: PhotoLibraryStore

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            action
        }
        .padding(40)
    }

    private var title: String {
        switch store.authorization {
        case .notDetermined: "Toegang tot je foto's"
        case .limited:       "Volledige toegang nodig"
        default:             "Geen toegang tot Photos"
        }
    }

    private var message: String {
        switch store.authorization {
        case .notDetermined:
            "Reassembly bewaart je demontagefoto's in Photos en beheert daar albums. Daarvoor is toegang nodig."
        case .limited:
            "Je gaf beperkte toegang. Reassembly kan alleen albums aanmaken en uitlezen met volledige toegang tot je fotobibliotheek."
        default:
            "Zet toegang tot Photos aan in Instellingen om Reassembly te gebruiken."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch store.authorization {
        case .notDetermined:
            Button("Geef toegang") {
                Task { await store.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        default:
            Button("Open Instellingen") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView()
}
