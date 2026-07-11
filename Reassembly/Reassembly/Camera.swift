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
    private(set) var accessDenied = false

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
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        // Dual-wide (virtueel: ultrawide + wide) geeft het hele zoombereik
        // vanaf 0.5×; los wide-toestel als fallback.
        let device = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
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
            }
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        configured = true
    }

    func capture() {
        let flash = flashMode
        sessionQueue.async {
            let settings = AVCapturePhotoSettings()
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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        // resizeAspect (niet Fill): toont het héle vastgelegde frame, dus je
        // ziet exact wat op de foto komt.
        view.videoPreviewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: model.session).ignoresSafeArea()

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

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            Spacer()
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
            Spacer()
            Button { model.cycleFlash() } label: {
                Image(systemName: flashIcon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(model.flashMode == .on ? .yellow : .white)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding()
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
        VStack(spacing: 18) {
            // Zoomknoppen zoals de Camera-app: preset per lens, de actieve is
            // geel en toont tijdens pinchen de werkelijke waarde.
            if !model.zoomPresets.isEmpty {
                HStack(spacing: 2) {
                    ForEach(model.zoomPresets) { preset in
                        zoomButton(preset)
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: .capsule)
            }

            bottomControls
        }
    }

    private func zoomButton(_ preset: CameraModel.ZoomPreset) -> some View {
        let isActive = model.activeZoomPreset == preset
        return Button { model.select(preset) } label: {
            Text(isActive
                 ? model.displayZoom.formatted(.number.precision(.fractionLength(0...1))) + "×"
                 : preset.display.formatted(.number.precision(.fractionLength(0...1))))
                .font(.caption.weight(.bold))
                .foregroundStyle(isActive ? .yellow : .white)
                .frame(width: isActive ? 40 : 30, height: isActive ? 40 : 30)
                .background(.black.opacity(isActive ? 0.45 : 0.25), in: Circle())
        }
        .animation(.snappy(duration: 0.15), value: isActive)
    }

    private var bottomControls: some View {
        HStack {
            Group {
                if let thumb = model.lastThumbnail {
                    Image(uiImage: thumb)
                        .resizable().scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.6)))
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
