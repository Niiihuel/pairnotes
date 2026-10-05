import SwiftUI
import UIKit

struct PhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZoomablePhoto(image: image).background(.black).ignoresSafeArea(edges: .bottom)
                .navigationTitle("Un recuerdo de ustedes").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}

private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView(image: image) }
    func updateUIView(_ uiView: PhotoScrollView, context: Context) {}
}

private final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView
    private var fittedSize = CGSize.zero
    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        imageView.frame = CGRect(origin: .zero, size: image.size)
        addSubview(imageView); delegate = self
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        backgroundColor = .black; bouncesZoom = true
        imageView.isAccessibilityElement = true; imageView.accessibilityLabel = "Foto compartida. Pellizcá para ampliar."
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedSize, bounds.width > 0, bounds.height > 0,
           imageView.bounds.width > 0, imageView.bounds.height > 0 {
            fittedSize = bounds.size
            let fit = min(bounds.width / imageView.bounds.width, bounds.height / imageView.bounds.height)
            minimumZoomScale = fit; maximumZoomScale = max(fit * 4, 1)
            zoomScale = fit
        }
        centerPhoto()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPhoto() }
    private func centerPhoto() {
        imageView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2, y: max(contentSize.height, bounds.height) / 2)
    }
    @objc private func doubleTap(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.1 { setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled) }
        else {
            let point = tap.location(in: imageView), scale = min(maximumZoomScale, minimumZoomScale * 2.5)
            zoom(to: CGRect(x: point.x - bounds.width / scale / 2, y: point.y - bounds.height / scale / 2,
                width: bounds.width / scale, height: bounds.height / scale), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}
