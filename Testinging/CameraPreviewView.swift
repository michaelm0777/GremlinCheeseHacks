//
//  CameraPreviewView.swift
//  Testinging
//

import SwiftUI
import AVFoundation

/// Host view that holds the preview layer and keeps its frame in sync.
private final class CameraPreviewHostView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            guard let layer = previewLayer else { return }
            layer.videoGravity = .resizeAspectFill
            self.layer.addSublayer(layer)
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let layer = previewLayer, !bounds.isEmpty {
            layer.frame = bounds
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> UIView {
        let host = CameraPreviewHostView()
        host.backgroundColor = .black
        host.previewLayer = previewLayer
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let host = uiView as? CameraPreviewHostView else { return }
        if host.previewLayer !== previewLayer {
            host.previewLayer = previewLayer
        }
        if host.previewLayer?.frame != host.bounds, !host.bounds.isEmpty {
            host.previewLayer?.frame = host.bounds
        }
    }
}
