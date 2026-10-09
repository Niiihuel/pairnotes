import SwiftUI
import UIKit

@MainActor
final class MessageOpeningPresentation: ObservableObject {
    private(set) var ownerID: UUID?
    private var mounted = false
    private var onDismissed: (@MainActor @Sendable (UUID) -> Void)?

    func begin(_ control: CoupleModalControl) -> UUID? {
        guard ownerID == nil else { return nil }
        let id = UUID()
        ownerID = id; mounted = false; onDismissed = control.onDismissed
        control.onPresented(id)
        return id
    }
    func didMount(_ id: UUID) { if ownerID == id { mounted = true } }
    func requestedDismissal() {
        // SwiftUI can cancel a same-tick presentation before creating its content.
        if !mounted, let id = ownerID { didClose(id) }
    }
    func didClose(_ id: UUID) {
        guard ownerID == id else { return }
        let callback = onDismissed
        ownerID = nil; mounted = false; onDismissed = nil
        callback?(id)
    }
}

@MainActor
final class MessageOpeningLifecycleController: UIViewController {
    let ownerID: UUID
    let presentation: MessageOpeningPresentation
    init(ownerID: UUID, presentation: MessageOpeningPresentation) {
        self.ownerID = ownerID; self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        presentation.didClose(ownerID)
    }
}

@MainActor
private struct MessageOpeningLifecycleObserver: UIViewControllerRepresentable {
    let ownerID: UUID
    let presentation: MessageOpeningPresentation
    func makeUIViewController(context: Context) -> MessageOpeningLifecycleController {
        presentation.didMount(ownerID)
        return MessageOpeningLifecycleController(ownerID: ownerID, presentation: presentation)
    }
    func updateUIViewController(_ controller: MessageOpeningLifecycleController, context: Context) {}
    static func dismantleUIViewController(_ controller: MessageOpeningLifecycleController, coordinator: ()) {
        // A mounted child that never appeared can be dismantled without a disappearance callback.
        if controller.viewIfLoaded?.window == nil { controller.presentation.didClose(controller.ownerID) }
    }
}

/// A nil date means send now. Opening the picker never schedules by itself.
struct MessageOpeningControl: View {
    @Binding var opensAt: Date?
    var compact = false
    var onPresent: @MainActor () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.coupleModalControl) private var modalControl
    @StateObject private var presentation = MessageOpeningPresentation()
    @State private var presented = false
    @State private var candidate = Date().addingTimeInterval(3_600)

    var body: some View {
        Button {
            guard presentation.begin(modalControl) != nil else { return }
            onPresent()
            candidate = max(opensAt ?? Date().addingTimeInterval(3_600), Date().addingTimeInterval(60))
            presented = true
        } label: {
            if compact {
                Image(systemName: opensAt == nil ? "clock" : "clock.fill")
                    .font(.title3).frame(width: 44, height: 44)
            } else {
                Label(opensAt.map { "Se abre \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Se abre…",
                      systemImage: "clock")
                    .font(.subheadline).multilineTextAlignment(.leading).frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("message.opening")
        .accessibilityLabel("Se abre…")
        .accessibilityValue(opensAt.map { $0.formatted(date: .long, time: .shortened) } ?? "Inmediata")
        .accessibilityAddTraits(opensAt == nil ? [] : .isSelected)
        .popover(isPresented: $presented) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button("Enviar ahora", systemImage: "paperplane") {
                        opensAt = nil; presented = false
                    }.frame(minHeight: 44)
                    Divider()
                    DatePicker("Se abre", selection: $candidate,
                               in: Date()...Date().addingTimeInterval(5 * 365 * 86_400))
                        .datePickerStyle(.graphical)
                        .accessibilityIdentifier("letter.opensAt")
                        .accessibilityLabel("Fecha y hora de apertura")
                    Text(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Programar") { opensAt = candidate; presented = false }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .disabled(candidate <= Date())
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.padding(20)
            }
            .frame(idealWidth: 320, maxWidth: 320, idealHeight: dynamicTypeSize.isAccessibilitySize ? 520 : 460,
                   maxHeight: dynamicTypeSize.isAccessibilitySize ? 520 : 460)
            .presentationCompactAdaptation(.popover)
            .background {
                if let ownerID = presentation.ownerID {
                    MessageOpeningLifecycleObserver(ownerID: ownerID, presentation: presentation)
                }
            }
        }
        .onChange(of: presented) { _, value in if !value { presentation.requestedDismissal() } }
        .onChange(of: modalControl.dismissalVersion) { _, _ in
            presented = false; presentation.requestedDismissal()
        }
        .onDisappear { presented = false; presentation.requestedDismissal() }
    }
}
