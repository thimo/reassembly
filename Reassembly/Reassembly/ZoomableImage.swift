//
//  ZoomableImage.swift
//  Reassembly
//
//  Zoombare foto (pinch + dubbeltik + pan) op UIScrollView-basis. Gedeeld door
//  de albumviewer en de scherpte-check van de camera.
//

import SwiftUI
import UIKit

struct ZoomableImage: UIViewRepresentable {
    /// nil zolang de foto laadt; de view zelf blijft dan gewoon staan.
    let image: UIImage?
    /// Enkele tik (wacht op een eventuele dubbeltik). nil: geen tik-gesture,
    /// zodat een SwiftUI-tap eromheen gewoon z'n gang kan gaan.
    var onSingleTap: (() -> Void)? = nil
    /// Meldt of er ingezoomd is; de omliggende view kan dan bv. z'n
    /// swipe-omlaag-sluit uitzetten zolang je door de foto pant.
    var onZoomChange: ((Bool) -> Void)? = nil

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

        if onSingleTap != nil {
            let singleTap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleSingleTap(_:)))
            singleTap.require(toFail: doubleTap)
            scrollView.addGestureRecognizer(singleTap)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChange = onZoomChange
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        var onSingleTap: (() -> Void)?
        var onZoomChange: ((Bool) -> Void)?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        // Pan alleen toestaan zolang je ingezoomd bent; op zoomscale 1 hoort de
        // horizontale swipe bij de pager, niet bij deze scrollview.
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale
            scrollView.panGestureRecognizer.isEnabled = zoomed
            onZoomChange?(zoomed)
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onSingleTap?()
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
