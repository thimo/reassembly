//
//  AlbumView.swift
//  Reassembly
//
//  Scherm 2: fotogrid van één album, per dag gegroepeerd met datum-header,
//  nieuwste bovenaan. Prominente cameraknop opent de eigen camera (scherm 3).
//

import SwiftUI
import Photos
import UIKit

struct AlbumView: View {
    let store: PhotoLibraryStore
    let album: PHAssetCollection
    let title: String

    @State private var assets: [PHAsset] = []
    @State private var showingCamera = false
    @State private var cameraUnavailable = false
    @State private var viewerIndex: ViewerState?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var errorMessage: String?
    @State private var showingRename = false
    @State private var renameText = ""

    private let router = QuickActionRouter.shared

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 2)]

    var body: some View {
        Group {
            if assets.isEmpty {
                ContentUnavailableView {
                    Label("No Photos Yet", systemImage: "camera")
                } description: {
                    Text("Tap the camera button to take your first teardown photo.")
                }
            } else {
                grid
            }
        }
        .navigationTitle(currentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar } else { cameraButton }
        }
        .toolbar {
            // Titel + fotoaantal, tikbaar voor hernoemen.
            ToolbarItem(placement: .principal) {
                TitleMenu(title: currentTitle, subtitle: countLabel) {
                    renameText = currentTitle
                    showingRename = true
                }
            }
            if !assets.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        // Kruisje in plaats van "Done", zoals Photos.
                        Button {
                            withAnimation { setSelecting(false) }
                        } label: {
                            Label("Done", systemImage: "xmark")
                        }
                    } else {
                        Button("Select") {
                            withAnimation { setSelecting(true) }
                        }
                    }
                }
            }
        }
        .task(id: store.changeToken) { reload() }
        .fullScreenCover(item: $viewerIndex) { state in
            PhotoViewer(store: store, assets: assets, index: state.index)
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Rename", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { performRename() }
        }
        .onAppear {
            ActiveProject.set(id: album.localIdentifier, title: currentTitle)
            handleCameraRequest()
        }
        .onChange(of: router.pending) { handleCameraRequest() }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    /// Titel vers uit Photos (via changeToken), zodat hernoemen — hier of in de
    /// Photos-app — meteen zichtbaar is.
    private var currentTitle: String {
        _ = store.changeToken
        return store.project(withLocalIdentifier: album.localIdentifier)?.title ?? title
    }

    private var countLabel: String {
        assets.count == 1
            ? String(localized: "1 photo")
            : String(localized: "\(assets.count) photos")
    }

    private func performRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            guard let project = store.project(withLocalIdentifier: album.localIdentifier) else { return }
            do {
                try await store.rename(project, to: name)
                // Actief-project-titel meebewegen (voedt de shortcut items).
                if ActiveProject.id == album.localIdentifier {
                    ActiveProject.set(id: album.localIdentifier, title: name)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Quick action (shortcut item / intent): open de camera zodra dit album
    /// het doelwit is.
    private func handleCameraRequest() {
        guard router.consumeCameraRequest(for: album.localIdentifier) else { return }
        openCamera()
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showingCamera = true
        } else {
            cameraUnavailable = true
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.day) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(group.assets, id: \.localIdentifier) { asset in
                                cell(for: asset)
                            }
                        }
                    } header: {
                        dateHeader(group.day)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var cameraButton: some View {
        Button {
            openCamera()
        } label: {
            Image(systemName: "camera.fill")
                .font(.title2)
                .frame(width: 66, height: 66)
        }
        // Gekleurd Liquid Glass in plaats van een platte accentcirkel.
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .padding(.bottom, 10)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView(store: store, album: album, title: title)
        }
        .alert("Camera Unavailable", isPresented: $cameraUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The simulator has no camera. Test on a device.")
        }
    }

    // Eén grid-cel. In selectiemodus toggelt een tik de selectie; anders opent
    // 'ie de viewer. Long-press geeft altijd een contextmenu (verwijderen /
    // selecteren).
    @ViewBuilder
    private func cell(for asset: PHAsset) -> some View {
        let thumb = Thumbnail(
            asset: asset,
            token: store.changeToken,
            selecting: isSelecting,
            selected: selection.contains(asset.localIdentifier)
        )
        .onTapGesture { tap(asset) }

        if isSelecting {
            thumb
        } else {
            thumb.contextMenu { menu(for: asset) }
        }
    }

    @ViewBuilder
    private func menu(for asset: PHAsset) -> some View {
        if asset.mediaType == .image {
            Button {
                rotate(asset)
            } label: {
                Label("Rotate 90°", systemImage: "rotate.left")
            }
        }
        Button(role: .destructive) {
            deleteSingle(asset)
        } label: {
            Label("Delete Photo", systemImage: "trash")
        }
        Button {
            withAnimation { enterSelection(with: asset) }
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
    }

    // Zoals Photos: teller als kale tekst in het midden, prullenbak los in een
    // glascirkel rechts. Links een balans-spacer (Photos heeft daar delen; dat
    // hebben wij niet).
    private var selectionBar: some View {
        HStack {
            Color.clear.frame(width: 44, height: 44)
            Spacer()
            Text(selectedLabel)
                .font(.headline)
            Spacer()
            Button(action: deleteSelected) {
                Image(systemName: "trash")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            // Donker glyph zoals Photos, niet de accentkleur.
            .tint(.primary)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var selectedLabel: String {
        switch selection.count {
        case 0: String(localized: "Select Photos")
        case 1: String(localized: "1 Photo Selected")
        default: String(localized: "\(selection.count) Photos Selected")
        }
    }

    private func tap(_ asset: PHAsset) {
        if isSelecting {
            let id = asset.localIdentifier
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            open(asset)
        }
    }

    private func setSelecting(_ on: Bool) {
        isSelecting = on
        if !on { selection.removeAll() }
    }

    private func enterSelection(with asset: PHAsset) {
        isSelecting = true
        selection = [asset.localIdentifier]
    }

    private func deleteSingle(_ asset: PHAsset) {
        Task {
            // userCancelled of andere fouten: stil laten, foto blijft staan.
            try? await store.deleteAsset(asset)
        }
    }

    private func rotate(_ asset: PHAsset) {
        Task {
            do { try await store.rotateCounterclockwise(asset) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteSelected() {
        let toDelete = assets.filter { selection.contains($0.localIdentifier) }
        guard !toDelete.isEmpty else { return }
        Task {
            do {
                try await store.deleteAssets(toDelete)
                withAnimation { setSelecting(false) }
            } catch {
                // Geannuleerd of mislukt: selectie laten staan zodat je 't
                // opnieuw kunt proberen.
            }
        }
    }

    // Assets gegroepeerd per kalenderdag, nieuwste dag bovenaan.
    private var groups: [(day: Date, assets: [PHAsset])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: assets) { asset in
            calendar.startOfDay(for: asset.creationDate ?? .distantPast)
        }
        return grouped
            .map { (day: $0.key, assets: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func dateHeader(_ day: Date) -> some View {
        Text(headerTitle(day))
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(.regularMaterial)
    }

    private func headerTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.day().month(.wide).year())
    }

    private func open(_ asset: PHAsset) {
        if let index = assets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
            viewerIndex = ViewerState(index: index)
        }
    }

    private func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: album, options: options)
        var found: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in found.append(asset) }
        assets = found
    }
}

private struct ViewerState: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - Thumbnail

private struct Thumbnail: View {
    let asset: PHAsset
    /// Wisselt bij elke library-wijziging en triggert herladen. Nodig omdat
    /// PHAsset op localIdentifier vergelijkt: een vers gefetchte instantie is
    /// voor SwiftUI "gelijk" en zou anders geen re-render veroorzaken.
    let token: Int
    var selecting: Bool = false
    var selected: Bool = false
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay {
                if selecting && selected {
                    Color.accentColor.opacity(0.25)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selecting { badge }
            }
            .contentShape(Rectangle())
            // Herladen bij verschijnen én na elke library-wijziging (rotatie!).
            // PHImageManager cachet, dus her-opvragen is goedkoop.
            .task(id: token) { load() }
    }

    private var badge: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                selected ? Color.white : Color.white,
                selected ? Color.accentColor : Color.black.opacity(0.35)
            )
            .padding(5)
            .shadow(radius: 2)
    }

    private func load() {
        // Vers exemplaar ophalen: de meegegeven asset kan een verouderde
        // snapshot zijn die nog de oude rendition oplevert.
        let fresh = PHAsset
            .fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
            .firstObject ?? asset
        let scale = UIScreen.main.scale
        let target = CGSize(width: 216 * scale, height: 216 * scale)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        PHImageManager.default().requestImage(
            for: fresh, targetSize: target, contentMode: .aspectFill, options: options
        ) { result, _ in
            if let result { self.image = result }
        }
    }
}

// MARK: - Fullscreen viewer

private struct PhotoViewer: View {
    let store: PhotoLibraryStore
    let assets: [PHAsset]
    @State var index: Int
    @State private var errorMessage: String?
    @State private var manager = PHCachingImageManager()
    /// Laatste bladerrichting (1 = vooruit, -1 = terug) — bepaalt welke foto
    /// je na een delete te zien krijgt.
    @State private var browseDirection = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.offset) { i, asset in
                    FullImage(asset: asset, token: store.changeToken, manager: manager)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Acties in bubbles, zoals Photos: X linksboven, rotate (outline-
            // glyph, zoals Apple's eigen) rechtsboven.
            HStack {
                bubbleButton("xmark") { dismiss() }
                Spacer()
                if assets.indices.contains(index), assets[index].mediaType == .image {
                    bubbleButton("rotate.left") { rotateCurrent() }
                }
            }
            .padding()
        }
        .alert("Rotation Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        // Prullenbak geïsoleerd rechtsonder, zoals Photos: ruimtelijke afstand
        // tot de bewerk-acties voorkomt mistikken; de systeembevestiging bij
        // verwijderen blijft als tweede slot.
        .overlay(alignment: .bottomTrailing) {
            bubbleButton("trash") { deleteCurrent() }
                .padding()
        }
        // Swipe omlaag sluit de viewer. simultaneousGesture: de horizontale
        // swipe blijft van de pager.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.height > 80,
                   value.translation.height > abs(value.translation.width) * 1.5 {
                    dismiss()
                }
            }
        )
        // Buurfoto's alvast in de cache: als een buurpagina pas tijdens de
        // eerste swipe binnenkomt, reset die state-update de pager halverwege.
        .onAppear { prefetch() }
        .onChange(of: index) { oldValue, newValue in
            browseDirection = newValue >= oldValue ? 1 : -1
            prefetch()
        }
    }

    /// Actieknop in een Liquid Glass-bubble, in de donkere smaak van de zwarte
    /// viewer — ongeacht het systeemthema.
    private func bubbleButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func prefetch() {
        let neighbors = assets.indices
            .filter { abs($0 - index) <= 1 }
            .map { assets[$0] }
        manager.startCachingImages(
            for: neighbors, targetSize: ViewerImaging.targetSize,
            contentMode: .aspectFit, options: ViewerImaging.makeOptions())
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func rotateCurrent() {
        guard assets.indices.contains(index) else { return }
        let asset = assets[index]
        Task {
            // Grid en viewer verversen zelf via changeToken.
            do { try await store.rotateCounterclockwise(asset) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteCurrent() {
        guard assets.indices.contains(index) else { return }
        let asset = assets[index]
        Task {
            do {
                try await store.deleteAsset(asset)
                // Doorbladeren in plaats van sluiten: volgende of vorige foto,
                // afhankelijk van de richting waarin je aan het swipen was.
                let newCount = assets.count - 1
                if newCount <= 0 {
                    dismiss()
                } else {
                    // Na verwijderen schuift de array op: zelfde index = de
                    // volgende foto; terugbladeren = index - 1.
                    let target = browseDirection < 0 ? index - 1 : index
                    index = min(max(target, 0), newCount - 1)
                }
            } catch let error as PHPhotosError where error.code == .userCancelled {
                // Gebruiker annuleerde de systeem-bevestiging — niks doen.
            } catch {
                // Stil laten; de foto blijft staan.
            }
        }
    }
}

/// Gedeelde parameters voor viewer-afbeeldingen: aanvraag en prefetch moeten
/// dezelfde maat/opties gebruiken, anders mist de cache.
private enum ViewerImaging {
    @MainActor
    static var targetSize: CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: UIScreen.main.bounds.width * scale,
                      height: UIScreen.main.bounds.height * scale)
    }

    static func makeOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        // Opportunistic: eerst snel een (gecachete) voorvertoning, dan vol —
        // zo staat er al beeld vóór de eerste swipe klaar.
        options.deliveryMode = .opportunistic
        return options
    }
}

private struct FullImage: View {
    let asset: PHAsset
    /// Zie Thumbnail.token: verse PHAsset-instanties zijn voor SwiftUI "gelijk",
    /// dus we herladen op library-wijziging.
    let token: Int
    let manager: PHImageManager
    @State private var image: UIImage?

    var body: some View {
        // Structuur bewust stabiel (geen spinner↔beeld-wissel): een structurele
        // swap terwijl de eerste swipe loopt laat de pager halverwege hangen.
        ZoomableImage(image: image)
            .overlay {
                if image == nil { ProgressView().tint(.white) }
            }
            // Laden bij verschijnen én na een bewerking; het oude beeld blijft
            // staan tot de nieuwe versie binnen is (geen flits naar de spinner).
            .task(id: token) { load() }
    }

    private func load() {
        // Vers exemplaar: de array-snapshot van de viewer kan verouderd zijn.
        let fresh = PHAsset
            .fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
            .firstObject ?? asset
        manager.requestImage(
            for: fresh, targetSize: ViewerImaging.targetSize,
            contentMode: .aspectFit, options: ViewerImaging.makeOptions()
        ) { result, _ in
            if let result { self.image = result }
        }
    }
}

// MARK: - Zoombare foto (pinch + dubbeltik + pan)

private struct ZoomableImage: UIViewRepresentable {
    /// nil zolang de foto laadt; de view zelf blijft dan gewoon staan.
    let image: UIImage?

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        // Niet ingezoomd valt er niks te pannen; laat de pan-gesture dan uit
        // staan zodat de paging-TabView de horizontale swipe ongestoord krijgt.
        // Anders kaapt deze scrollview soms de swipe half en blijft de pager
        // tussen twee foto's hangen. Pinch/dubbeltik-zoom staan los hiervan.
        scrollView.panGestureRecognizer.isEnabled = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        // Pan alleen toestaan zolang je ingezoomd bent; op zoomscale 1 hoort de
        // horizontale swipe bij de pager, niet bij deze scrollview.
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled =
                scrollView.zoomScale > scrollView.minimumZoomScale
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let newScale: CGFloat = 3
                let size = scrollView.bounds.size
                let rect = CGRect(
                    x: point.x - (size.width / newScale) / 2,
                    y: point.y - (size.height / newScale) / 2,
                    width: size.width / newScale,
                    height: size.height / newScale)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
