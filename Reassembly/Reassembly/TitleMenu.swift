//
//  TitleMenu.swift
//  Reassembly
//
//  Navigatiebalk-titel met ondertitel (aantal foto's/items), tikbaar als menu
//  voor hernoemen. Vervangt de standaardtitel via ToolbarItem(.principal).
//

import SwiftUI

struct TitleMenu: View {
    let title: String
    let subtitle: String
    let rename: () -> Void

    var body: some View {
        Menu {
            Button("Hernoem", systemImage: "pencil", action: rename)
        } label: {
            VStack(spacing: 0) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("titleMenu")
    }
}
