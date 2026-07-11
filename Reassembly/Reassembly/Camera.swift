//
//  Camera.swift
//  Reassembly
//
//  Scherm 3: eigen AVFoundation-camera. Geen "Use Photo"-bevestiging — elke
//  sluiterdruk schiet direct door en bewaart in het actieve album, inclusief
//  geotag. Het album blijft actief zodat een volgende foto één tik is.
//

import SwiftUI
import AVFoundation
import AVKit
import CoreLocation
import Photos
import UIKit

@MainActor @Observable
final class CameraModel: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "nl.defrog.reassembly.camera")
    private let locationProvider = LocationProvider()

    private weak var store: PhotoLibraryStore?
    private var album: PHAssetCollection?
    private var configured = false
    private var device: AVCaptureDevice?
    private var zoomAtGestureStart: CGFloat = 1
    /// Zoomfactor die "1×" voorstelt (bij een virtuele dual-wide-lens is de
    /// kale factor 1.0 juist de ultrawide, dus 0.5×).
    private var oneXFactor: CGFloat = 1

    /// Zoomniveau zoals de gebruiker het kent (0.5×, 1×, 2.3×).
    private(set) var displayZoom: Double = 1

    /// Zoomknoppen zoals de Camera-app, afgeleid van de echte lenzen: 0.5× als
    /// er een ultrawide is, 1×, het sensor-crop-punt (2×) en tele-lenzen.
    struct ZoomPreset: Identifiable, Equatable {
        let display: Double
        let factor: CGFloat
        var id: Double { display }
    }

    private(set) var zoomPresets: [ZoomPreset] = []

    /// De preset waar het huidige zoomniveau bij hoort (grootste ≤ huidige).
    var activeZoomPreset: ZoomPreset? {
        zoomPresets.last { $0.display <= displayZoom + 0.01 } ?? zoomPresets.first
    }

    func select(_ preset: ZoomPreset) {
        guard let device else { return }
        displayZoom = Double(preset.factor / oneXFactor)
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.ramp(toVideoZoomFactor: preset.factor, withRate: 8)
            device.unlockForConfiguration()
        }
    }

    private(set) var capturedCount = 0
    private(set) var lastThumbnail: UIImage?
    private(set) var lastCapture: UIImage?
    private(set) var accessDenied = false

    // MARK: - Oriëntatie

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    /// Koppelt de preview-layer zodra die bestaat. De RotationCoordinator geeft
    /// preview én capture de juiste hoek — zonder draaide het videobeeld in
    /// landscape een extra keer 90° mee met de interface.
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        setupRotationCoordinator()
    }

    private func setupRotationCoordinator() {
        guard let device, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
        ) { [weak previewLayer] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                previewLayer?.connection?.videoRotationAngle = angle
            }
        }
    }

    // MARK: - Torch (continu licht)

    private(set) var torchOn = false

    func toggleTorch() {
        guard let device, device.hasTorch else { return }
        torchOn.toggle()
        let on = torchOn
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    // MARK: - Focus

    /// AE/AF-vergrendeling actief (long-press, zoals de Camera-app).
    private(set) var focusLocked = false

    /// Tik: scherpstellen + belichten op dit punt (device-coördinaten 0–1).
    func focus(at devicePoint: CGPoint) {
        guard let device else { return }
        focusLocked = false
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    /// Long-press: scherpstellen + belichten op dit punt en dan vastzetten.
    func lockFocus(at devicePoint: CGPoint) {
        guard let device else { return }
        focusLocked = true
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
            // Even laten instellen, dan beide vergrendelen.
            self.sessionQueue.asyncAfter(deadline: .now() + 0.7) {
                guard (try? device.lockForConfiguration()) != nil else { return }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                device.unlockForConfiguration()
            }
        }
    }

    // MARK: - Raster

    /// Hulplijnen (regel van derden), onthouden tussen sessies.
    private(set) var showGrid = UserDefaults.standard.bool(forKey: "cameraGrid")

    func toggleGrid() {
        showGrid.toggle()
        UserDefaults.standard.set(showGrid, forKey: "cameraGrid")
    }

    /// Flitsstand, onthouden tussen sessies (werkplaatsen zijn donker).
    private(set) var flashMode: AVCaptureDevice.FlashMode = {
        AVCaptureDevice.FlashMode(
            rawValue: UserDefaults.standard.integer(forKey: "flashMode")) ?? .auto
    }()

    func cycleFlash() {
        flashMode = switch flashMode {
        case .auto: .on
        case .on: .off
        default: .auto
        }
        UserDefaults.standard.set(flashMode.rawValue, forKey: "flashMode")
    }

    // MARK: - Zoom

    /// Bij het begin van een pinch: het huidige niveau als referentie.
    func beginZoom() {
        zoomAtGestureStart = device?.videoZoomFactor ?? 1
    }

    /// Pinch-schaal toepassen op de referentie, begrensd door wat de lens kan.
    func zoom(scale: CGFloat) {
        guard let device else { return }
        let target = min(
            max(zoomAtGestureStart * scale, device.minAvailableVideoZoomFactor),
            min(device.maxAvailableVideoZoomFactor, 16))
        displayZoom = target / oneXFactor
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = target
            device.unlockForConfiguration()
        }
    }

    func start(store: PhotoLibraryStore, album: PHAssetCollection) {
        self.store = store
        self.album = album
        locationProvider.start()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                Task { @MainActor in self.accessDenied = true }
                return
            }
            self.sessionQueue.async {
                if !self.configured { self.configureSession() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        locationProvider.stop()
        torchOn = false
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        // Triple (ultrawide + wide + tele) waar beschikbaar — alleen dan doet
        // de telelens mee en verschijnt z'n zoomknop (bv. 3× of 4×). Anders
        // dual-wide, anders kale wide.
        let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        if let device,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            // Virtuele lens start op de ultrawide (0.5×); naar 1× springen.
            let oneX = device.virtualDeviceSwitchOverVideoZoomFactors.first
                .map { CGFloat(truncating: $0) } ?? 1
            if oneX != 1, (try? device.lockForConfiguration()) != nil {
                device.videoZoomFactor = oneX
                device.unlockForConfiguration()
            }
            // Presets uit de hardware: ultrawide, 1×, sensor-crop en tele.
            var presets: [ZoomPreset] = []
            let minZoom = device.minAvailableVideoZoomFactor
            if minZoom < oneX {
                presets.append(ZoomPreset(
                    display: (Double(minZoom / oneX) * 10).rounded() / 10,
                    factor: minZoom))
            }
            presets.append(ZoomPreset(display: 1, factor: oneX))
            let teles = device.virtualDeviceSwitchOverVideoZoomFactors.dropFirst()
                .map { CGFloat(truncating: $0) }
            let sensorCrops = device.activeFormat.secondaryNativeResolutionZoomFactors
            for factor in (teles + sensorCrops) where factor > oneX {
                presets.append(ZoomPreset(
                    display: (Double(factor / oneX) * 10).rounded() / 10,
                    factor: factor))
            }
            presets.sort { $0.display < $1.display }
            var seen = Set<Double>()
            let uniquePresets = presets.filter { seen.insert($0.display).inserted }

            Task { @MainActor in
                self.device = device
                self.oneXFactor = oneX
                self.zoomPresets = uniquePresets
                // De preview kan al gekoppeld zijn vóór het device er was.
                self.setupRotationCoordinator()
            }
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // Volle sensorresolutie (48 MP waar de lens het kan): bij teardown-
            // foto's wil je achteraf diep kunnen inzoomen op detail.
            if let dims = device?.activeFormat.supportedMaxPhotoDimensions
                .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                photoOutput.maxPhotoDimensions = dims
            }
        }
        session.commitConfiguration()
        configured = true
    }

    func capture() {
        let flash = flashMode
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        sessionQueue.async {
            // Capture-hoek meegeven: anders staan landscape-foto's gedraaid.
            if let angle,
               let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor in await self.save(data) }
    }

    private func save(_ data: Data) async {
        guard let store, let album else { return }
        try? await store.addPhoto(data: data, location: locationProvider.current, to: album)
        capturedCount += 1
        if let image = UIImage(data: data) {
            lastCapture = image
            lastThumbnail = image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        }
    }
}

/// Levert de laatst bekende locatie voor de geotag.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var current: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        current = locations.last ?? current
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - Preview-layer

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// (devicePoint 0–1, punt in view-coördinaten)
    let onAttach: (AVCaptureVideoPreviewLayer) -> Void
    let onTap: (CGPoint, CGPoint) -> Void
    let onLongPress: (CGPoint, CGPoint) -> Void
    let onShutter: () -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        // resizeAspect (niet Fill): toont het héle vastgelegde frame, dus je
        // ziet exact wat op de foto komt.
        view.videoPreviewLayer.videoGravity = .resizeAspect
        view.onTap = onTap
        view.onLongPress = onLongPress

        // Volumeknoppen als sluiter, zoals de Camera-app.
        view.addInteraction(AVCaptureEventInteraction { event in
            if event.phase == .began { onShutter() }
        })

        // Buiten de render-pass om: koppelen triggert observatie-state.
        let layer = view.videoPreviewLayer
        Task { @MainActor in onAttach(layer) }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var onTap: ((CGPoint, CGPoint) -> Void)?
        var onLongPress: ((CGPoint, CGPoint) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(
                target: self, action: #selector(handleTap(_:))))
            addGestureRecognizer(UILongPressGestureRecognizer(
                target: self, action: #selector(handleLongPress(_:))))
        }

        required init?(coder: NSCoder) { fatalError("niet gebruikt") }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: self)
            guard let devicePoint = devicePointInsideFrame(for: point) else { return }
            onTap?(devicePoint, point)
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            let point = gesture.location(in: self)
            guard let devicePoint = devicePointInsideFrame(for: point) else { return }
            onLongPress?(devicePoint, point)
        }

        /// nil buiten het videobeeld: de preview is aspect-fit, dus tikken op
        /// de zwarte balken horen geen focuspunt te zetten.
        private func devicePointInsideFrame(for point: CGPoint) -> CGPoint? {
            let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
            guard (0...1).contains(devicePoint.x), (0...1).contains(devicePoint.y) else {
                return nil
            }
            return devicePoint
        }
    }
}

/// Regel-van-derden-raster over het (aspect-fit) videobeeld.
private struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Foto-preset is 4:3; portret toont 3:4.
            let aspect: CGFloat = size.width < size.height ? 3.0 / 4.0 : 4.0 / 3.0
            let width = min(size.width, size.height * aspect)
            let height = width / aspect
            let origin = CGPoint(x: (size.width - width) / 2,
                                 y: (size.height - height) / 2)
            Path { path in
                for i in 1...2 {
                    let x = origin.x + width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: origin.y))
                    path.addLine(to: CGPoint(x: x, y: origin.y + height))
                    let y = origin.y + height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: origin.x, y: y))
                    path.addLine(to: CGPoint(x: origin.x + width, y: y))
                }
            }
            .stroke(.white.opacity(0.4), lineWidth: 0.5)
        }
    }
}

// MARK: - Camerascherm

struct CameraView: View {
    let store: PhotoLibraryStore
    let album: PHAssetCollection
    let title: String

    @State private var model = CameraModel()
    @State private var flash = false
    @State private var isZooming = false
    @State private var focusPoint: CGPoint?
    @State private var showingLastCapture = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(
                session: model.session,
                onAttach: { model.attach(previewLayer: $0) },
                onTap: { devicePoint, viewPoint in
                    model.focus(at: devicePoint)
                    showFocusSquare(at: viewPoint)
                },
                onLongPress: { devicePoint, viewPoint in
                    model.lockFocus(at: devicePoint)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showFocusSquare(at: viewPoint)
                },
                onShutter: { shoot() }
            )
            .overlay {
                if model.showGrid && !model.accessDenied {
                    GridOverlay().allowsHitTesting(false)
                }
            }
            // In dezelfde overlay als de preview: dan kloppen de coördinaten.
            .overlay {
                if let focusPoint {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(.yellow, lineWidth: 1.5)
                        .frame(width: 80, height: 80)
                        .position(focusPoint)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if model.focusLocked {
                    Text("AE/AF Lock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.yellow, in: Capsule())
                        .padding(.top, 64)
                }
            }
            .ignoresSafeArea()

            if model.accessDenied {
                ContentUnavailableView {
                    Label("No Camera Access", systemImage: "camera.fill")
                        .foregroundStyle(.white)
                } description: {
                    Text("Turn on camera access in Settings.")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }

            // Sluiter-flits
            Color.white
                .opacity(flash ? 0.9 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .task { model.start(store: store, album: album) }
        .onDisappear { model.stop() }
        .statusBarHidden()
        // Laatste foto groot, voor de scherpte-check; tik of veeg omlaag sluit.
        .fullScreenCover(isPresented: $showingLastCapture) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = model.lastCapture {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
            .onTapGesture { showingLastCapture = false }
            .simultaneousGesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    if value.translation.height > 80 { showingLastCapture = false }
                }
            )
        }
        // Pinch = zoomen (dual-wide lens: van 0.5× ultrawide tot 16× digitaal).
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    if !isZooming {
                        isZooming = true
                        model.beginZoom()
                    }
                    model.zoom(scale: scale)
                }
                .onEnded { _ in isZooming = false }
        )
        // Swipe omlaag sluit de camera. Geen cancel: elke sluiterdruk is al
        // direct in het album bewaard.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.height > 80,
                   value.translation.height > abs(value.translation.width) * 1.5 {
                    dismiss()
                }
            }
        )
    }

    private func shoot() {
        model.capture()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            withAnimation(.easeOut(duration: 0.3)) { flash = false }
        }
    }

    /// Geel kadertje op het tikpunt, verdwijnt vanzelf weer.
    private func showFocusSquare(at point: CGPoint) {
        withAnimation(.snappy(duration: 0.15)) { focusPoint = point }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.3)) { focusPoint = nil }
        }
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                }
                .glassEffect(.regular.interactive(), in: .circle)

                Spacer()

                // Acties samen in één pill, zoals Photos ze groepeert.
                HStack(spacing: 0) {
                    topBarButton("grid", active: model.showGrid) { model.toggleGrid() }
                    topBarButton("flashlight.on.fill", active: model.torchOn) { model.toggleTorch() }
                    Button { model.cycleFlash() } label: {
                        Image(systemName: flashIcon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(model.flashMode == .on ? .yellow : .white)
                            .frame(width: 44, height: 44)
                    }
                }
                .glassEffect(.regular, in: .capsule)
            }

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .frame(maxWidth: 170)
        }
        .padding()
    }

    /// Knop binnen de acties-pill; de pill zelf levert het glas.
    private func topBarButton(_ systemName: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(active ? .yellow : .white)
                .frame(width: 44, height: 44)
        }
    }

    /// auto → A-bliksem, geforceerd aan → gele bliksem, uit → doorgestreept.
    private var flashIcon: String {
        switch model.flashMode {
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        default: "bolt.badge.a.fill"
        }
    }

    private var bottomBar: some View {
        // Ruime afstand tussen zoomrondjes en sluiter: zo staan de rondjes
        // duidelijk bínnen de foto in plaats van op de rand.
        VStack(spacing: 30) {
            // Zoomknoppen zoals de Camera-app: preset per lens, de actieve is
            // geel en toont tijdens pinchen de werkelijke waarde.
            if !model.zoomPresets.isEmpty {
                // Losse donkere rondjes per knop, zoals de Camera-app —
                // géén omhullende capsule.
                HStack(spacing: 10) {
                    ForEach(model.zoomPresets) { preset in
                        zoomButton(preset)
                    }
                }
            }

            bottomControls
        }
    }

    private func zoomButton(_ preset: CameraModel.ZoomPreset) -> some View {
        let isActive = model.activeZoomPreset == preset
        return Button { model.select(preset) } label: {
            // Zoals de Camera-app: inactief = kaal wit cijfer, actief = grotere
            // donkere cirkel met geel cijfer + "×".
            Text(zoomText(isActive ? model.displayZoom : preset.display, active: isActive))
                // Mono-font en een maatje kleiner, zoals Apple; schaalt zo
                // nodig verder terug zodat "6,4×" in de cirkel blijft passen.
                .font(.system(size: isActive ? 13 : 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isActive ? Color.yellow : .white)
                .frame(width: isActive ? 38 : 28, height: isActive ? 38 : 28)
                .background(.black.opacity(isActive ? 0.5 : 0.35), in: Circle())
        }
        .animation(.snappy(duration: 0.15), value: isActive)
    }

    /// Gewoon "0,5" — voorloopnul blijft; alleen de actieve knop krijgt "×".
    private func zoomText(_ value: Double, active: Bool) -> String {
        let text = value.formatted(.number.precision(.fractionLength(0...1)))
        return active ? text + "×" : text
    }

    private var bottomControls: some View {
        HStack {
            Group {
                if let thumb = model.lastThumbnail {
                    // Tik = laatste foto groot bekijken (scherpte-check).
                    Button { showingLastCapture = true } label: {
                        Image(uiImage: thumb)
                            .resizable().scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.6)))
                    }
                } else {
                    Color.clear.frame(width: 52, height: 52)
                }
            }
            Spacer()
            Button { shoot() } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 5).frame(width: 78, height: 78)
                    Circle().fill(.white).frame(width: 64, height: 64)
                }
            }
            Spacer()
            Group {
                if model.capturedCount > 0 {
                    Text(verbatim: "\(model.capturedCount)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 52, height: 52)
                        .background(.white, in: Circle())
                } else {
                    Color.clear.frame(width: 52, height: 52)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 36)
    }
}
