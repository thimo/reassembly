//
//  QuickActions.swift
//  Reassembly
//
//  Camera in het actieve project zonder door de app te navigeren:
//  icoon-long-press (UIApplicationShortcutItem) en een App Intent voor
//  Shortcuts, Siri en de Action Button. Dezelfde intent gaat later ook de
//  ControlWidget (Control Center / lock screen) voeden — dat vereist een
//  Widget Extension-target.
//

import SwiftUI
import AppIntents
import Photos

// MARK: - Actief project

/// Het album waar je het laatst mee bezig was (UserDefaults, per device).
/// localIdentifier volstaat: quick actions zijn per-device, net als de rest
/// van onze state.
enum ActiveProject {
    private static let idKey = "activeProjectID"
    private static let titleKey = "activeProjectTitle"

    static var id: String? { UserDefaults.standard.string(forKey: idKey) }
    static var title: String? { UserDefaults.standard.string(forKey: titleKey) }

    static func set(id: String, title: String) {
        UserDefaults.standard.set(id, forKey: idKey)
        UserDefaults.standard.set(title, forKey: titleKey)
    }
}

// MARK: - Router

/// Brengt een quick action (shortcut item of intent) naar de UI: de
/// projectenlijst navigeert naar het album, de AlbumView consumeert de
/// camera-vraag.
@Observable
@MainActor
final class QuickActionRouter {
    static let shared = QuickActionRouter()

    struct Request: Equatable {
        let albumID: String
        let openCamera: Bool
        /// Uniek per verzoek, zodat twee keer hetzelfde album opnieuw triggert.
        let token = UUID()
    }

    var pending: Request?

    func open(albumID: String, camera: Bool) {
        pending = Request(albumID: albumID, openCamera: camera)
    }

    /// Geeft één keer true als dit album de camera moet openen, en wist dan
    /// het verzoek.
    func consumeCameraRequest(for albumID: String) -> Bool {
        guard let pending, pending.albumID == albumID, pending.openCamera else { return false }
        self.pending = nil
        return true
    }

    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == QuickActions.captureType,
              let albumID = item.userInfo?["albumID"] as? String else { return false }
        open(albumID: albumID, camera: true)
        return true
    }
}

// MARK: - Shortcut items (icoon-long-press)

@MainActor
enum QuickActions {
    static let captureType = "nl.defrog.reassembly.capture"

    /// Herbouwt de dynamische shortcut items: het actieve project bovenaan,
    /// aangevuld met de recentste projecten. Aanroepen bij naar-achtergrond.
    static func refreshShortcutItems(store: PhotoLibraryStore) {
        var items: [UIApplicationShortcutItem] = []
        if let id = ActiveProject.id, let title = ActiveProject.title {
            items.append(item(albumID: id, title: title))
        }
        for album in store.recentAlbums(limit: 3) where album.id != ActiveProject.id {
            if items.count >= 3 { break }
            items.append(item(albumID: album.id, title: album.title))
        }
        UIApplication.shared.shortcutItems = items
    }

    private static func item(albumID: String, title: String) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: captureType,
            localizedTitle: String(localized: "Photo in \(title)"),
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "camera"),
            userInfo: ["albumID": albumID as NSString]
        )
    }
}

// MARK: - Scene-plumbing

/// Shortcut items komen alleen via de scene delegate binnen; SwiftUI heeft
/// daar geen eigen haakje voor.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Koude start vanaf een shortcut item.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            Task { @MainActor in _ = QuickActionRouter.shared.handle(item) }
        }
    }

    /// Warme start (app liep al).
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            completionHandler(QuickActionRouter.shared.handle(shortcutItem))
        }
    }
}

// MARK: - App Intent (Shortcuts / Siri / Action Button, straks ControlWidget)

struct CapturePhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Photo in Active Project"
    static let description = IntentDescription(
        "Opens the camera in the project you were last working on.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = ActiveProject.id else {
            throw CaptureError.noActiveProject
        }
        QuickActionRouter.shared.open(albumID: id, camera: true)
        return .result()
    }
}

enum CaptureError: Error, CustomLocalizedStringResourceConvertible {
    case noActiveProject

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noActiveProject:
            "There's no active project yet — open an album in Re-assembly first."
        }
    }
}

struct ReassemblyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CapturePhotoIntent(),
            phrases: ["Take a photo in \(.applicationName)"],
            shortTitle: "Photo in Active Project",
            systemImageName: "camera"
        )
    }
}
