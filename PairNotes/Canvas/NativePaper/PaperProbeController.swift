import UIKit
import PaperKit
import PencilKit
import SwiftUI

@MainActor
final class PaperProbeController: UIViewController, PaperMarkupViewController.Delegate {
    let canvas = PaperMarkupViewController(markup: PaperMarkup(bounds: PaperProbeDocument.bounds),
                                           supportedFeatureSet: PaperProbeDocument.supportedFeatures)
    var onMarkupChanged: (() -> Void)?
    var paperBackground: PaperBackground = .white {
        didSet { paper.backgroundColor = paperBackground.uiColor }
    }
    private let paper = UIView()
    private let picker = PKToolPicker()
    private var lastFittedSize: CGSize = .zero
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        // PaperKit's public contentView is sized to the document bounds and
        // placed below all editable content (available with the iOS 26 SDK).
        // Setting just the outer controller's background leaves a dark sheet.
        paper.backgroundColor = paperBackground.uiColor
        paper.isOpaque = true
        paper.isUserInteractionEnabled = false
        paper.layer.borderWidth = 1
        paper.layer.borderColor = UIColor.gray.withAlphaComponent(0.45).cgColor
        canvas.contentView = paper
        canvas.overrideUserInterfaceStyle = .light
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
        canvas.delegate = self
        canvas.directTouchAutomaticallyDraws = false
        canvas.directTouchMode = .drawing
        canvas.zoomRange = 0.05...4
        picker.colorMaximumLinearExposure = 1
        picker.addObserver(canvas)
        pencilKitResponderState.activeToolPicker = picker
        pencilKitResponderState.toolPickerVisibility = .visible
        let textItem = UIBarButtonItem(image: UIImage(systemName: "textformat"), style: .plain,
                                      target: self, action: #selector(insertText))
        textItem.accessibilityLabel = "Agregar texto"
        picker.accessoryItem = textItem
    }

    nonisolated func paperMarkupViewControllerDidChangeMarkup(_ paperMarkupViewController: PaperMarkupViewController) {
        Task { @MainActor [weak self] in self?.onMarkupChanged?() }
    }

    // SDK 26.0 requires all four delegate methods. The document callback is
    // marshalled to our main-actor session; the others do not mutate app state.
    nonisolated func paperMarkupViewControllerDidChangeSelection(_ paperMarkupViewController: PaperMarkupViewController) {}
    nonisolated func paperMarkupViewControllerDidBeginDrawing(_ paperMarkupViewController: PaperMarkupViewController) {}
    nonisolated func paperMarkupViewControllerDidChangeContentVisibleFrame(_ paperMarkupViewController: PaperMarkupViewController) {}

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

    @objc func insertText() {
        guard canvas.isEditable else { return }
        // The SDK 26.0 compiler does not expose the controller's conformance to
        // MarkupEditViewController.Delegate. Insert using the stable model API.
        let prompt = UIAlertController(title: "Agregar texto", message: nil, preferredStyle: .alert)
        prompt.addTextField { $0.placeholder = "Tu nota" }
        prompt.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        prompt.addAction(UIAlertAction(title: "Agregar", style: .default) { [weak self, weak prompt] _ in
            guard let self, self.canvas.isEditable,
                  let text = prompt?.textFields?.first?.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  var markup = self.canvas.markup else { return }
            markup.insertNewTextbox(attributedText: NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 64), .foregroundColor: self.paperBackground.contrastingInkColor
            ]), frame: CGRect(x: 150, y: 1120, width: 1200, height: 150))
            self.canvas.markup = markup
            self.onMarkupChanged?()
        })
        present(prompt, animated: true)
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
