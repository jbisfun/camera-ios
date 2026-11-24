import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// PreviewView: the session's preview layer plus the hardware shutter hook
/// (volume buttons / Camera Control through AVCaptureEventInteraction).
struct CameraPreview: UIViewRepresentable {
    let controller: CameraController
    let volumeButtonsAsShutter: Bool
    let onShutter: () -> Void

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var eventInteraction: UIInteraction?
    }

    final class Coordinator {
        var onShutter: () -> Void = {}
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        controller.previewLayer = view.previewLayer
        context.coordinator.onShutter = onShutter
        if #available(iOS 17.2, *) {
            let coordinator = context.coordinator
            let interaction = AVCaptureEventInteraction { event in
                // onKeyDown with mIsHardwareShutterHandled: one shot per press.
                if event.phase == .began { coordinator.onShutter() }
            }
            interaction.isEnabled = volumeButtonsAsShutter
            view.addInteraction(interaction)
            view.eventInteraction = interaction
        }
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        context.coordinator.onShutter = onShutter
        if controller.previewLayer !== view.previewLayer { controller.previewLayer = view.previewLayer }
        if #available(iOS 17.2, *), let interaction = view.eventInteraction as? AVCaptureEventInteraction {
            interaction.isEnabled = volumeButtonsAsShutter
        }
    }
}
