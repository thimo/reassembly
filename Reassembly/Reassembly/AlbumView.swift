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
                    Label("Nog geen foto's", systemImage: "camera")
                } description: {
                    Text("Tik op de cameraknop om je eerste demontagefoto te maken.")
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
                    Button(isSelecting ? "Klaar" : "Selecteer") {
                        withAnimation { setSelecting(!isSelecting) }
                    }
                }
            }
        }
        .task(id: store.changeToken) { reload() }
        .fullScreenCover(item: $viewerIndex) { state in
            PhotoViewer(store: store, assets: assets, index: state.index)
        }
        .alert("Er ging iets mis", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Hernoemen", isPresented: $showingRename) {
            TextField("Naam", text: $renameText)
            Button("Annuleer", role: .cancel) {}
            Button("Bewaar") { performRename() }
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
        assets.count == 1 ? "1 foto" : "\(assets.count) foto's"
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
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(Circle().fill(Color.accentColor))
                .shadow(radius: 8, y: 4)
        }
        .padding(.bottom, 10)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView(store: store, album: album, title: title)
        }
        .alert("Camera niet beschikbaar", isPresented: $cameraUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("De simulator heeft geen camera. Test op een toestel.")
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
                Label("Draai 90°", systemImage: "rotate.left")
            }
        }
        Button(role: .destructive) {
            deleteSingle(asset)
        } label: {
            Label("Verwijder foto", systemImage: "trash")
        }
        Button {
            withAnimation { enterSelection(with: asset) }
        } label: {
            Label("Selecteer", systemImage: "checkmark.circle")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Button(role: .destructive, action: deleteSelected) {
                Label(
                    selection.isEmpty ? "Verwijder" : "Verwijder (\(selection.count))",
                    systemImage: "trash"
                )
                .font(.body.weight(.semibold))
            }
            .disabled(selection.isEmpty)

            Spacer()

            Button(selection.count == assets.count ? "Deselecteer alles" : "Selecteer alles") {
                if selection.count == assets.count {
                    selection.removeAll()
                } else {
                    selection = Set(assets.map(\.localIdentifier))
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.regularMaterial)
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
        if calendar.isDateInToday(day) { return "Vandaag" }
        if calendar.isDateInYesterday(day) { return "Gisteren" }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.offset) { i, asset in
                    FullImage(asset: asset, token: store.changeToken).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                if assets.indices.contains(index), assets[index].mediaType == .image {
                    Button { rotateCurrent() } label: {
                        Image(systemName: "rotate.left.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Button { deleteCurrent() } label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding()
        }
        .alert("Draaien mislukt", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
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
                dismiss()   // gelukt → sluit viewer; het grid ververst zelf
            } catch let error as PHPhotosError where error.code == .userCancelled {
                // Gebruiker annuleerde de systeem-bevestiging — niks doen.
            } catch {
                // Stil laten; de foto blijft staan.
            }
        }
    }
}

private struct FullImage: View {
    let asset: PHAsset
    /// Zie Thumbnail.token: verse PHAsset-instanties zijn voor SwiftUI "gelijk",
    /// dus we herladen op library-wijziging.
    let token: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
            } else {
                ProgressView().tint(.white)
            }
        }
        // Herladen bij verschijnen én na een bewerking; het oude beeld blijft
        // staan tot de nieuwe versie binnen is (geen flits naar de spinner).
        .task(id: token) { load() }
    }

    private func load() {
        // Vers exemplaar: de array-snapshot van de viewer kan verouderd zijn.
        let fresh = PHAsset
            .fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
            .firstObject ?? asset
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let scale = UIScreen.main.scale
        let target = CGSize(width: UIScreen.main.bounds.width * scale,
                            height: UIScreen.main.bounds.height * scale)
        PHImageManager.default().requestImage(
            for: fresh, targetSize: target, contentMode: .aspectFit, options: options
        ) { result, _ in
            if let result { self.image = result }
        }
    }
}

// MARK: - Zoombare foto (pinch + dubbeltik + pan)

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

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
