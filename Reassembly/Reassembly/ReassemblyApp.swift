//
//  ReassemblyApp.swift
//  Reassembly
//
//  Created by Thimo Jansen on 03/07/2026.
//

import SwiftUI

@main
struct ReassemblyApp: App {
    /// Voor de scene delegate die shortcut items (icoon-long-press) doorgeeft.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PhotoLibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .onChange(of: scenePhase) {
            // Op weg naar de achtergrond de shortcut items verversen: actief
            // project + recentste projecten.
            if scenePhase == .background {
                QuickActions.refreshShortcutItems(store: store)
            }
        }
    }
}
