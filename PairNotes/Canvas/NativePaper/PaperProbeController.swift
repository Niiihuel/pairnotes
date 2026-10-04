import UIKit
import PaperKit
import PencilKit
import SwiftUI

@MainActor
final class PaperProbeController: UIViewController {
    let canvas = PaperMarkupViewController(markup: PaperProbeDocument.fixture(),
                                           supportedFeatureSet: PaperProbeDocument.supportedFeatures)
    private let picker = PKToolPicker()
    private var lastFittedSize: CGSize = .zero
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        addChild(canvas)
        canvas.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas.view)
        NSLayoutConstraint.activate([
            canvas.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        canvas.didMove(toParent: self)
        canvas.directTouchAutomaticallyDraws = false
        canvas.directTouchMode = .drawing
        canvas.zoomRange = 0.05...4
        picker.colorMaximumLinearExposure = 1
        picker.addObserver(canvas)
        pencilKitResponderState.activeToolPicker = picker
        pencilKitResponderState.toolPickerVisibility = .visible
        picker.accessoryItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(insertElements(_:)))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = canvas.view.bounds.size
        guard size.width > 0, size.height > 0, size != lastFittedSize else { return }
        lastFittedSize = size
        canvas.setContentVisibleFrame(PaperProbeDocument.bounds, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resignFirstResponder()
    }

    @objc private func insertElements(_ button: UIBarButtonItem) {
        guard canvas.isEditable else { return }
        let insertion = MarkupEditViewController(supportedFeatureSet: PaperProbeDocument.supportedFeatures)
        insertion.delegate = canvas
        insertion.modalPresentationStyle = .popover
        insertion.popoverPresentationController?.barButtonItem = button
        present(insertion, animated: true)
    }
}

struct PaperProbeCanvas: UIViewControllerRepresentable {
    let controller: PaperProbeController
    let enabled: Bool
    func makeUIViewController(context: Context) -> PaperProbeController { controller }
    func updateUIViewController(_ controller: PaperProbeController, context: Context) {
        controller.canvas.isEditable = enabled
        controller.view.isUserInteractionEnabled = enabled
    }
}
