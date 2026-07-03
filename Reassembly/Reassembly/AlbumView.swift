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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { cameraButton }
        .task(id: store.changeToken) { reload() }
        .fullScreenCover(item: $viewerIndex) { state in
            PhotoViewer(store: store, assets: assets, index: state.index)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.day) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(group.assets, id: \.localIdentifier) { asset in
                                Thumbnail(asset: asset)
                                    .onTapGesture { open(asset) }
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
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showingCamera = true
            } else {
                cameraUnavailable = true
            }
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
            .contentShape(Rectangle())
            .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let scale = UIScreen.main.scale
        let target = CGSize(width: 216 * scale, height: 216 * scale)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        PHImageManager.default().requestImage(
            for: asset, targetSize: target, contentMode: .aspectFill, options: options
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.offset) { i, asset in
                    FullImage(asset: asset).tag(i)
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
                Button { deleteCurrent() } label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding()
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
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let scale = UIScreen.main.scale
        let target = CGSize(width: UIScreen.main.bounds.width * scale,
                            height: UIScreen.main.bounds.height * scale)
        PHImageManager.default().requestImage(
            for: asset, targetSize: target, contentMode: .aspectFit, options: options
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
