//
//  ProjectsListView.swift
//  Reassembly
//
//  Scherm 1: de projectenlijst. Eén niveau van de Photos-hiërarchie; folders
//  navigeren recursief naar hetzelfde scherm een niveau dieper. Nieuw
//  aangemaakte projecten worden meteen geopend.
//

import SwiftUI
import Photos

/// Root-scherm: bezit de NavigationStack + het gedeelde pad, en start op het
/// rootniveau (parent nil). De navigatie-bestemming staat hier één keer, zodat
/// zowel tikken als auto-open na aanmaken via hetzelfde pad lopen.
struct ProjectsListView: View {
    let store: PhotoLibraryStore
    @State private var path: [Project] = []
    @State private var restored = false

    private let router = QuickActionRouter.shared

    /// UserDefaults-sleutel: de localIdentifiers van het open pad, root → diepst.
    private static let pathKey = "navigationPath"

    var body: some View {
        NavigationStack(path: $path) {
            ProjectsLevel(store: store, parent: nil, title: "Re-assembly", path: $path)
                .navigationDestination(for: Project.self) { project in
                    switch project.kind {
                    case .album(let album):
                        AlbumView(store: store, album: album, title: project.title)
                    case .folder(let folder):
                        ProjectsLevel(store: store, parent: folder,
                                      title: project.title, path: $path)
                    }
                }
        }
        .onAppear(perform: restore)
        .onChange(of: path) {
            guard restored else { return }
            UserDefaults.standard.set(path.map(\.id), forKey: Self.pathKey)
        }
        // Quick action (shortcut item / intent) terwijl de app al draait.
        .onChange(of: router.pending) { navigateToQuickAction() }
    }

    /// Herstelt het navigatiepad van de vorige sessie, ook na force-quit.
    /// Onvindbare items (buitenom verwijderd in Photos) kappen het pad af;
    /// je landt dan op het diepste niveau dat nog bestaat. Een quick action
    /// (koude start vanaf een shortcut item) wint van het bewaarde pad.
    private func restore() {
        guard !restored else { return }
        restored = true
        if ProcessInfo.processInfo.arguments.contains("--reset-navigation") {
            UserDefaults.standard.removeObject(forKey: Self.pathKey)
            return
        }
        if navigateToQuickAction() { return }
        let ids = UserDefaults.standard.stringArray(forKey: Self.pathKey) ?? []
        var result: [Project] = []
        for id in ids {
            guard let project = store.project(withLocalIdentifier: id) else { break }
            result.append(project)
        }
        path = result
    }

    /// Navigeert naar het album van een openstaande quick action. De camera-
    /// vraag blijft in de router staan; de AlbumView consumeert die zodra 'ie
    /// verschijnt.
    @discardableResult
    private func navigateToQuickAction() -> Bool {
        guard let request = router.pending,
              let target = store.path(toAlbumWithIdentifier: request.albumID)
        else { return false }
        path = target
        return true
    }
}

/// Eén niveau in de boom. Laadt z'n eigen kinderen en herlaadt bij elke
/// library-wijziging (via `store.changeToken`).
private struct ProjectsLevel: View {
    let store: PhotoLibraryStore
    /// De folder waarvan we de inhoud tonen; nil = de root-folder.
    let parent: PHCollectionList?
    let title: String
    @Binding var path: [Project]

    @State private var showingNewAlbum = false
    @State private var showingNewFolder = false
    @State private var newName = ""
    @State private var errorMessage: String?
    @State private var renaming: Project?
    @State private var renameText = ""

    var body: some View {
        Group {
            if children.isEmpty {
                emptyState
            } else {
                list
            }
        }
        // changeToken echt gebruiken (geen dead-code-eliminatie): forceert een
        // verse render — en dus verse tellingen — bij elke library-wijziging.
        .id(store.changeToken)
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(parent == nil ? .large : .inline)
        .safeAreaInset(edge: .bottom) {
            if parent == nil {   // alleen op de voorpagina
                Text("Re-assembly is the reverse of disassembly.")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
        }
        // Toevoegen rechtsonder, in duimbereik — zelfde plek als de cameraknop
        // in een album.
        .overlay(alignment: .bottomTrailing) {
            addButton
        }
        .toolbar {
            if parent != nil {
                // Foldertitel + itemtelling, tikbaar voor hernoemen — zelfde
                // patroon als de albumtitel.
                ToolbarItem(placement: .principal) {
                    TitleMenu(title: currentTitle, subtitle: itemsLabel) {
                        startRenameParent()
                    }
                }
            }
        }
        .alert("Nieuw album", isPresented: $showingNewAlbum) {
            TextField("Naam", text: $newName)
            Button("Annuleer", role: .cancel) {}
            Button("Maak aan") { create(.album) }
        } message: {
            Text("Er wordt een album met deze naam in Photos aangemaakt.")
        }
        .alert("Nieuwe folder", isPresented: $showingNewFolder) {
            TextField("Naam", text: $newName)
            Button("Annuleer", role: .cancel) {}
            Button("Maak aan") { create(.folder) }
        } message: {
            Text("Een folder groepeert projecten — handig voor klant → project.")
        }
        .alert("Aanmaken mislukt", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Hernoemen", isPresented: renameBinding) {
            TextField("Naam", text: $renameText)
            Button("Annuleer", role: .cancel) {}
            Button("Bewaar") { performRename() }
        }
    }

    private var addButton: some View {
        Menu {
            Button("Nieuw album", systemImage: "photo.stack") {
                newName = ""; showingNewAlbum = true
            }
            Button("Nieuwe folder", systemImage: "folder") {
                newName = ""; showingNewFolder = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.accentColor))
                .shadow(radius: 8, y: 4)
        }
        .accessibilityLabel("Toevoegen")
        .padding(.trailing, 20)
        .padding(.bottom, 10)
    }

    /// Titel vers uit Photos (via changeToken): hernoemen is meteen zichtbaar.
    private var currentTitle: String {
        _ = store.changeToken
        guard let parent else { return title }
        return store.project(withLocalIdentifier: parent.localIdentifier)?.title ?? title
    }

    private var itemsLabel: String {
        children.count == 1 ? "1 item" : "\(children.count) items"
    }

    private func startRenameParent() {
        guard let parent,
              let project = store.project(withLocalIdentifier: parent.localIdentifier)
        else { return }
        renameText = project.title
        renaming = project
    }

    private var list: some View {
        List {
            ForEach(children) { project in
                NavigationLink(value: project) {
                    ProjectRow(project: project)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Geen role: .destructive — dat animeert de rij meteen weg,
                    // terwijl onze delete async is (+ annuleerbare systeemvraag).
                    // De rij verdwijnt pas als de verwijdering echt is doorgevoerd.
                    Button {
                        delete(project)
                    } label: {
                        Label("Verwijder + foto's", systemImage: "trash")
                    }
                    .tint(.red)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        renameText = project.title
                        renaming = project
                    } label: {
                        Label("Hernoem", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(parent == nil ? "Nog geen projecten" : "Lege folder",
                  systemImage: "shippingbox")
        } description: {
            Text("Maak een album aan voor je demontagefoto's, of een folder om projecten te groeperen.")
        } actions: {
            Button("Nieuw album") { newName = ""; showingNewAlbum = true }
                .buttonStyle(.borderedProminent)
            Button("Nieuwe folder") { newName = ""; showingNewFolder = true }
        }
    }

    private enum NewKind { case album, folder }

    private func create(_ kind: NewKind) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                let created: Project?
                switch kind {
                case .album:  created = try await store.createAlbum(named: name, in: parent)
                case .folder: created = try await store.createFolder(named: name, in: parent)
                }
                if let created { path.append(created) }   // meteen openen
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ project: Project) {
        Task {
            do {
                try await store.delete(project)
            } catch let error as PHPhotosError where error.code == .userCancelled {
                // Gebruiker annuleerde de systeem-bevestiging — niks doen.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performRename() {
        guard let project = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do { try await store.rename(project, to: name) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// De lijst is een pure afgeleide van de Photos-hiërarchie. Door changeToken
    /// te lezen her-evalueert de view bij elke wijziging (nieuwe foto, hernoem,
    /// nieuw album); bij terugkeren uit een album wordt sowieso opnieuw
    /// gerenderd — dus altijd verse tellingen en namen.
    private var children: [Project] {
        _ = store.changeToken
        return store.children(of: parent)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: project.isFolder ? "folder" : "photo.stack")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String? {
        if project.isFolder {
            guard let n = project.childCount else { return nil }
            return n == 1 ? "1 item" : "\(n) items"
        }
        guard let count = project.assetCount else { return nil }
        let photos = count == 1 ? "1 foto" : "\(count) foto's"
        guard let last = project.lastActivity else { return photos }
        return "\(photos) · \(last.formatted(.relative(presentation: .named)))"
    }
}
