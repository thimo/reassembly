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
            Task { @MainActor in self.device = device }
            // Virtuele lens start op de ultrawide (0.5×); naar 1× springen.
            if let oneX = device.virtualDeviceSwitchOverVideoZoomFactors.first,
               (try? device.lockForConfiguration()) != nil {
                device.videoZoomFactor = CGFloat(truncating: oneX)
                device.unlockForConfiguration()
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
