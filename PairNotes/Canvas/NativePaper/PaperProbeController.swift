import UIKit
import PaperKit
import PencilKit
import SwiftUI

@MainActor
final class PaperProbeController: UIViewController, PaperMarkupViewController.Delegate, PKToolPickerObserver {
    let canvas = PaperMarkupViewController(markup: PaperMarkup(bounds: PaperProbeDocument.bounds),
                                           supportedFeatureSet: PaperProbeDocument.supportedFeatures)
    private let lowerCanvas = PaperMarkupViewController(markup: PaperMarkup(bounds: PaperProbeDocument.bounds),
        supportedFeatureSet: PaperProbeDocument.supportedFeatures)
    private let upperCanvas = PaperMarkupViewController(markup: PaperMarkup(bounds: PaperProbeDocument.bounds),
        supportedFeatureSet: PaperProbeDocument.supportedFeatures)
    private let lowerPreviewHost = PaperLayerPreviewHost()
    private let upperPreviewHost = PaperLayerPreviewHost()
    private var layers = [PaperLayer(name: "Capa 1", markup: PaperMarkup(bounds: PaperProbeDocument.bounds))]
    private(set) var activeLayerID: UUID?
    var onLayersChanged: (([PaperLayer], UUID) -> Void)?

    func capturedLayers() -> [PaperLayer] {
        var snapshot = layers
        let index = snapshot.firstIndex { $0.id == activeLayerID } ?? 0
        if let markup = canvas.markup { snapshot[index].markup = markup }
        return snapshot
    }

    func composedMarkup() -> PaperMarkup {
        var result = PaperMarkup(bounds: PaperProbeDocument.bounds)
        for layer in capturedLayers() { result.append(contentsOf: layer.markup) }
        return result
    }

    func restoreLayers(_ restored: [PaperLayer]) {
        guard !restored.isEmpty else { return }
        layers = restored
        activeLayerID = restored.last?.id
        displayLayers()
    }

    func selectLayer(_ id: UUID) {
        guard layers.contains(where: { $0.id == id }), activeLayerID != id else { return }
        layers = capturedLayers()
        // Native undo actions address the active controller, not a layer ID.
        // Do not let a stroke undo from another layer mutate this one.
        canvas.undoManager?.removeAllActions()
        activeLayerID = id
        displayLayers()
        refreshHistory()
    }

    func addLayer(name: String = "Nueva capa") {
        changeLayers(action: "Agregar capa") {
            let layer = PaperLayer(name: name, markup: PaperMarkup(bounds: PaperProbeDocument.bounds))
            let index = layers.firstIndex { $0.id == activeLayerID } ?? (layers.count - 1)
            layers.insert(layer, at: index + 1)
            activeLayerID = layer.id
        }
    }

    func moveLayer(_ id: UUID, by offset: Int) {
        guard let index = layers.firstIndex(where: { $0.id == id }), layers.indices.contains(index + offset) else { return }
        changeLayers(action: "Ordenar capas") { layers.swapAt(index, index + offset) }
    }

    func renameLayer(_ id: UUID, name: String) {
        let name = String(name.prefix(60))
        guard let index = layers.firstIndex(where: { $0.id == id }), layers[index].name != name else { return }
        changeLayers(action: "Renombrar capa") { layers[index].name = name }
    }

    func removeLayer(_ id: UUID) {
        guard layers.count > 1, layers.contains(where: { $0.id == id }) else { return }
        changeLayers(action: "Eliminar capa") {
            layers.removeAll { $0.id == id }
            if activeLayerID == id { activeLayerID = layers.last?.id }
        }
    }

    private func changeLayers(action: String, _ change: () -> Void) {
        layers = capturedLayers()
        let previous = layers
        let selected = activeLayerID
        change()
        displayLayers()
        registerLayerUndo(previous, selected: selected, action: action)
        onMarkupChanged?()
        refreshHistory()
    }

    private func registerLayerUndo(_ previous: [PaperLayer], selected: UUID?, action: String) {
        canvas.undoManager?.registerUndo(withTarget: self) { target in
            let current = target.capturedLayers()
            let active = target.activeLayerID
            target.layers = previous
            target.activeLayerID = selected
            target.displayLayers()
            target.registerLayerUndo(current, selected: active, action: action)
            target.onMarkupChanged?()
            target.refreshHistory()
        }
        canvas.undoManager?.setActionName(action)
    }

    private func displayLayers() {
        let index = layers.firstIndex { $0.id == activeLayerID } ?? 0
        activeLayerID = layers[index].id
        restoreMarkup(layers[index].markup)
        var below = PaperMarkup(bounds: PaperProbeDocument.bounds)
        var above = PaperMarkup(bounds: PaperProbeDocument.bounds)
        for (position, layer) in layers.enumerated() {
            if position < index { below.append(contentsOf: layer.markup) }
            if position > index { above.append(contentsOf: layer.markup) }
        }
        lowerCanvas.markup = below
        upperCanvas.markup = above
        synchronizeLayerViewport()
        onLayersChanged?(layers, layers[index].id)
    }

    private func synchronizeLayerViewport() {
        let frame = canvas.contentVisibleFrame
        guard frame.width > 0, frame.height > 0 else { return }
        // The method only ensures a rect is visible and is a no-op when a
        // zoomed-out preview already contains it. The property sets the exact
        // viewport so all three layers keep the same scale and position.
        lowerCanvas.contentVisibleFrame = frame
        upperCanvas.contentVisibleFrame = frame
    }

    var onMarkupChanged: (() -> Void)?
    var onHistoryChanged: ((Bool, Bool) -> Void)?
    var paperBackground: PaperBackground = .white {
        didSet { paper.backgroundColor = paperBackground.uiColor }
    }
    var showsAlignmentGuides = false { didSet { alignmentGuides.isHidden = !showsAlignmentGuides } }
    private let alignmentGuides = PaperAlignmentGuides(frame: .zero)
    private let paper = UIView()
    private let picker = PKToolPicker()
    var snapsToGuides = false
    var selectionMode = false {
        didSet {
            guard selectionMode != oldValue else { return }
            canvas.directTouchMode = selectionMode ? .selection : .drawing
            // Selecting an object and then choosing Draw must really return to
            // ink, even if the system palette last remembered a lasso tool.
            if !selectionMode, !(canvas.drawingTool is PKInkingTool), !(canvas.drawingTool is PKEraserTool) {
                picker.selectedTool = lastInk
                canvas.drawingTool = lastInk
            }
        }
    }
    private var lastInk = PKInkingTool(.pen, color: .black, width: 12)
    private(set) var isPaletteRequestedVisible = true
    private var editingEnabled = true
    private var editGeneration = 0
    private var snapTask: Task<Void, Never>?

    init() {
        super.init(nibName: nil, bundle: nil)
        // A session can import, cancel or restore a draft before UIKit loads its
        // view. PaperKit defaults to selection, so establish our input policy
        // when the controller is created rather than only in viewDidLoad.
        synchronizeTouchMode()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func synchronizeTouchMode() {
        canvas.directTouchAutomaticallyDraws = false
        let mode: PaperMarkupViewController.TouchMode = selectionMode ? .selection : .drawing
        if canvas.directTouchMode != mode { canvas.directTouchMode = mode }
        canvas.indirectPointerTouchMode = .selection
    }

    func useInkColor(_ color: UIColor) {
        let ink = (picker.selectedToolItem as? PKToolPickerInkingItem)?.inkingTool
        // The compatibility setter updates the existing palette item and notifies PaperKit.
        lastInk = PKInkingTool(ink?.inkType ?? .pen, color: color, width: ink?.width ?? 12)
        picker.selectedTool = lastInk
        canvas.drawingTool = lastInk
    }

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        if let ink = (toolPicker.selectedToolItem as? PKToolPickerInkingItem)?.inkingTool { lastInk = ink }
    }

    /// Align native content, preserving editable text/images rather than rasterizing the layer.
    func alignActiveLayer(_ alignment: PaperAlignment, onlyNearCenter: Bool = false) async {
        guard canvas.isEditable, var markup = canvas.markup else { return }
        let selected = activeLayerID, generation = editGeneration
        guard let data = try? await PaperProbeDocument.render(markup, side: 384, background: nil),
              let image = UIImage(data: data)?.cgImage,
              let content = PaperPixelSampler.contentBounds(image),
              selected == activeLayerID, generation == editGeneration, !Task.isCancelled else { return }
        let bounds = PaperProbeDocument.bounds
        let rect = CGRect(x: content.minX * bounds.width, y: content.minY * bounds.height,
                          width: content.width * bounds.width, height: content.height * bounds.height)
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch alignment {
        case .left: dx = 64 - rect.minX
        case .center: dx = bounds.midX - rect.midX
        case .right: dx = bounds.maxX - 64 - rect.maxX
        case .top: dy = 64 - rect.minY
        case .middle: dy = bounds.midY - rect.midY
        case .bottom: dy = bounds.maxY - 64 - rect.maxY
        case .both: dx = bounds.midX - rect.midX; dy = bounds.midY - rect.midY
        }
        if onlyNearCenter {
            guard snapsToGuides, selectionMode else { return }
            if abs(dx) > 24 { dx = 0 }
            if abs(dy) > 24 { dy = 0 }
        }
        guard abs(dx) > 2 || abs(dy) > 2 else { return }
        markup.transformContent(CGAffineTransform(translationX: dx, y: dy))
        replaceMarkup(markup, actionName: "Alinear capa")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func scheduleSnap() {
        editGeneration += 1
        snapTask?.cancel()
        guard snapsToGuides, selectionMode else { return }
        snapTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, self.snapsToGuides, self.selectionMode, !self.canvas.view.hasActivePaperGesture else { return }
            await self.alignActiveLayer(.both, onlyNearCenter: true)
        }
    }
    private var lastFittedSize: CGSize = .zero

    /// Restoring persisted content is not an edit. Detach the delegate while
    /// assigning it so a deferred main-actor change callback cannot autosave a
    /// legacy draft merely because the user opened it.
    func restoreMarkup(_ markup: PaperMarkup) {
        let previousDelegate = canvas.delegate
        canvas.delegate = nil
        canvas.markup = markup
        canvas.delegate = previousDelegate
        synchronizeTouchMode()
    }

    func refreshHistory() {
        onHistoryChanged?(canvas.undoManager?.canUndo == true, canvas.undoManager?.canRedo == true)
    }

    func undo() {
        canvas.undoManager?.undo()
        refreshHistory()
    }

    func redo() {
        canvas.undoManager?.redo()
        refreshHistory()
    }

    /// App-owned insertions share PaperKit's undo manager with native strokes.
    /// Suppress any implicit setter registration to avoid duplicate operations.
    func replaceMarkup(_ markup: PaperMarkup, actionName: String) {
        guard let previous = canvas.markup else { return }
        editGeneration += 1
        let manager = canvas.undoManager
        let grouping = manager != nil && manager?.isUndoing != true && manager?.isRedoing != true
        if grouping { manager?.beginUndoGrouping() }
        manager?.disableUndoRegistration()
        restoreMarkup(markup)
        manager?.enableUndoRegistration()
        manager?.registerUndo(withTarget: self) { target in
            target.replaceMarkup(previous, actionName: actionName)
        }
        manager?.setActionName(actionName)
        if grouping { manager?.endUndoGrouping() }
        onMarkupChanged?()
        refreshHistory()
    }

    func fitPaper() {
        canvas.contentVisibleFrame = canvas.markup?.bounds ?? PaperProbeDocument.bounds
    }

    func zoom(by factor: CGFloat) {
        let visible = canvas.contentVisibleFrame
        guard factor > 0, visible.width.isFinite, visible.height.isFinite,
              visible.width > 0, visible.height > 0 else { return }
        let bounds = canvas.markup?.bounds ?? PaperProbeDocument.bounds
        let width = min(bounds.width * 4, max(bounds.width / 4, visible.width / factor))
        let height = width * visible.height / visible.width
        canvas.contentVisibleFrame = CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                                            width: width, height: height)
    }

    func setPaletteVisible(_ visible: Bool) {
        guard isPaletteRequestedVisible != visible else { return }
        isPaletteRequestedVisible = visible
        activateCanvasInput()
    }

    /// SwiftUI can temporarily disable the representable while loading a photo
    /// or saving. Keep that transition on the actual input controller, and
    /// recover its first responder when the operation or presentation ends.
    func setEditingEnabled(_ enabled: Bool) {
        let changed = editingEnabled != enabled
        editingEnabled = enabled
        loadViewIfNeeded()
        if canvas.isEditable != enabled { canvas.isEditable = enabled }
        if view.isUserInteractionEnabled != enabled { view.isUserInteractionEnabled = enabled }
        if canvas.view.isUserInteractionEnabled != enabled { canvas.view.isUserInteractionEnabled = enabled }
        if changed { activateCanvasInput() }
    }

    private func activateCanvasInput() {
        synchronizeTouchMode()
        guard isViewLoaded else { return }
        // PaperKit can update its own view when editability changes. The
        // editable controller alone must participate in UIKit hit testing.
        if canvas.view.isUserInteractionEnabled != editingEnabled { canvas.view.isUserInteractionEnabled = editingEnabled }
        let visible = editingEnabled && isPaletteRequestedVisible && !selectionMode
        // The responder, tool picker and observed drawing controller must be
        // the same object. Touching the child canvas otherwise leaves a palette
        // registered only on its container without an active input responder.
        canvas.pencilKitResponderState.activeToolPicker = picker
        canvas.pencilKitResponderState.toolPickerVisibility = visible ? .visible : .hidden
        guard editingEnabled, canvas.view.window != nil, presentedViewController == nil else { return }
        if !canvas.isFirstResponder { canvas.becomeFirstResponder() }
    }

    func resumeCanvasInput() { activateCanvasInput() }

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
        lowerCanvas.contentView = paper
        // PaperKit supplies its own sheet unless a content view is explicit.
        // Only the bottom controller owns paper; the other two show ink only.
        for overlay in [canvas, upperCanvas] {
            let transparent = UIView()
            transparent.backgroundColor = .clear
            transparent.isOpaque = false
            transparent.isUserInteractionEnabled = false
            overlay.contentView = transparent
        }
        alignmentGuides.isHidden = !showsAlignmentGuides
        upperCanvas.contentView = alignmentGuides
        for (backdrop, host) in [(lowerCanvas, lowerPreviewHost), (upperCanvas, upperPreviewHost)] {
            backdrop.overrideUserInterfaceStyle = .light
            backdrop.isEditable = false
            backdrop.zoomRange = 0.05...4
            addChild(backdrop)
            // Keep the pass-through boundary outside PaperKit's managed view.
            // Framework lifecycle/layout updates must never re-enable touches
            // on a read-only preview above the actual drawing controller.
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            backdrop.view.backgroundColor = .clear
            backdrop.view.isOpaque = false
            backdrop.view.isUserInteractionEnabled = false
            backdrop.view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(backdrop.view)
            NSLayoutConstraint.activate([
                backdrop.view.topAnchor.constraint(equalTo: host.topAnchor),
                backdrop.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                backdrop.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                backdrop.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])
            backdrop.didMove(toParent: self)
        }
        canvas.view.backgroundColor = .clear
        canvas.view.isOpaque = false
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
        view.bringSubviewToFront(upperPreviewHost)
        canvas.delegate = self
        synchronizeTouchMode()
        canvas.zoomRange = 0.05...4
        // Match the sheet and export renderer, regardless of the app appearance.
        picker.overrideUserInterfaceStyle = .light
        picker.colorUserInterfaceStyle = .light
        picker.colorMaximumLinearExposure = 1
        lastInk = PKInkingTool(.pen, color: paperBackground.contrastingInkColor, width: 12)
        picker.selectedTool = lastInk
        canvas.drawingTool = lastInk
        picker.addObserver(canvas)
        picker.addObserver(self)
        canvas.isEditable = editingEnabled
        activateCanvasInput()
        let textItem = UIBarButtonItem(image: UIImage(systemName: "textformat"), style: .plain,
                                      target: self, action: #selector(insertText))
        textItem.accessibilityLabel = "Agregar texto"
        picker.accessoryItem = textItem
        layers = capturedLayers()
        displayLayers()
    }

    nonisolated func paperMarkupViewControllerDidChangeMarkup(_ paperMarkupViewController: PaperMarkupViewController) {
        Task { @MainActor [weak self] in
            self?.scheduleSnap()
            self?.onMarkupChanged?()
            self?.refreshHistory()
        }
    }

    // SDK 26.0 requires all four delegate methods. The document callback is
    // marshalled to our main-actor session; the others do not mutate app state.
    nonisolated func paperMarkupViewControllerDidChangeSelection(_ paperMarkupViewController: PaperMarkupViewController) {}
    nonisolated func paperMarkupViewControllerDidBeginDrawing(_ paperMarkupViewController: PaperMarkupViewController) {}
    nonisolated func paperMarkupViewControllerDidChangeContentVisibleFrame(_ paperMarkupViewController: PaperMarkupViewController) {
        Task { @MainActor [weak self] in self?.synchronizeLayerViewport() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateCanvasInput()
        refreshHistory()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if canvas.view.isUserInteractionEnabled != editingEnabled { canvas.view.isUserInteractionEnabled = editingEnabled }
        let size = canvas.view.bounds.size
        guard size.width > 0, size.height > 0, size != lastFittedSize else { return }
        lastFittedSize = size
        fitPaper()
        synchronizeLayerViewport()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        canvas.pencilKitResponderState.toolPickerVisibility = .hidden
        canvas.resignFirstResponder()
    }

    func insertSticker(_ symbol: String) {
        guard canvas.isEditable else { return }
        addLayer(name: "Sticker " + symbol)
        guard var markup = canvas.markup else { return }
        markup.insertNewTextbox(attributedText: NSAttributedString(string: symbol, attributes: [
            .font: UIFont.systemFont(ofSize: 160), .foregroundColor: paperBackground.contrastingInkColor
        ]), frame: CGRect(x: 650, y: 650, width: 300, height: 250))
        replaceMarkup(markup, actionName: "Agregar sticker")
        canvas.directTouchMode = .selection
    }

    func insertPostcardFrame(style: PaperTemplate = .postcard) {
        guard canvas.isEditable else { return }
        let bounds = PaperProbeDocument.bounds
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            if style != .postcard {
                style.draw(in: context.cgContext, bounds: bounds, ink: paperBackground.contrastingInkColor)
                return
            }
            let ink = paperBackground.contrastingInkColor.withAlphaComponent(0.45)
            context.cgContext.setStrokeColor(ink.cgColor)
            context.cgContext.setLineWidth(4)
            context.cgContext.setLineDash(phase: 0, lengths: [16, 12])
            context.cgContext.stroke(bounds.insetBy(dx: 60, dy: 60))
            context.cgContext.setLineDash(phase: 0, lengths: [])
            for y in stride(from: bounds.height * 0.73, through: bounds.height * 0.9, by: 80) {
                context.cgContext.move(to: CGPoint(x: bounds.width * 0.55, y: y))
                context.cgContext.addLine(to: CGPoint(x: bounds.width * 0.88, y: y))
            }
            context.cgContext.strokePath()
        }
        guard let cgImage = image.cgImage else { return }
        addLayer(name: style.rawValue)
        guard var markup = canvas.markup else { return }
        markup.insertNewImage(cgImage, frame: bounds)
        replaceMarkup(markup, actionName: "Agregar marco de postal")
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
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.addLayer(name: String(text.prefix(40)))
            guard var markup = self.canvas.markup else { return }
            markup.insertNewTextbox(attributedText: NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 64), .foregroundColor: self.paperBackground.contrastingInkColor
            ]), frame: CGRect(x: 150, y: 1120, width: 1200, height: 150))
            self.replaceMarkup(markup, actionName: "Agregar texto")
        })
        present(prompt, animated: true)
    }
}

/// A preview controller may manage the interaction flags of its own view.
/// This app-owned ancestor makes the entire layer visual-only regardless of
/// those internal updates, including hit tests inside images or native text.
private final class PaperLayerPreviewHost: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

struct PaperProbeCanvas: UIViewControllerRepresentable {
    let controller: PaperProbeController
    let enabled: Bool
    func makeUIViewController(context: Context) -> PaperProbeController { controller }
    func updateUIViewController(_ controller: PaperProbeController, context: Context) {
        // Status/preview updates during autosave also update this representable.
        // Reapplying PaperKit editing mode can interrupt an active native gesture.
        controller.setEditingEnabled(enabled)
    }
}

/// Guides live in the viewport, never in the document or its exported image.
private final class PaperAlignmentGuides: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor.systemPink.withAlphaComponent(0.65).cgColor)
        context.setLineWidth(3); context.setLineDash(phase: 0, lengths: [14, 12])
        context.move(to: CGPoint(x: bounds.midX, y: 0)); context.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        context.move(to: CGPoint(x: 0, y: bounds.midY)); context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        context.strokePath()
    }
}

private extension UIView {
    var hasActivePaperGesture: Bool {
        gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true ||
            subviews.contains(where: { $0.hasActivePaperGesture })
    }
}
