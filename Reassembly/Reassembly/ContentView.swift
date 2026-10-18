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
    let store: PhotoLibraryStore

    var body: some View {
        Group {
            if store.hasFullAccess {
                ProjectsListView(store: store)
                #if DEBUG
                    .task { await DemoSeed.run(store: store) }
                #endif
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
        // Zelfde volwaardige CTA-maat als de lege-staat-knoppen.
        .controlSize(.large)
        .padding(40)
    }

    private var title: String {
        switch store.authorization {
        case .notDetermined: String(localized: "Access to your photos")
        case .limited:       String(localized: "Limited access")
        default:             String(localized: "No access to Photos")
        }
    }

    private var message: String {
        switch store.authorization {
        case .notDetermined:
            String(localized: "Re-assembly stores your teardown photos as albums in your Photos library. In the next step, iOS asks whether to allow this.")
        case .limited:
            String(localized: "You chose limited access. Re-assembly works with albums, which Photos only provides with full access. You can change this in Settings.")
        default:
            String(localized: "Turn on access to Photos in Settings to use Re-assembly.")
        }
    }

    @ViewBuilder
    private var action: some View {
        switch store.authorization {
        case .notDetermined:
            Button("Continue") {
                Task { await store.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        default:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView(store: PhotoLibraryStore())
}
