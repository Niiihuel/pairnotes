import PairNotesCore
import SwiftUI
import UIKit

/// Gestures only request a reaction. The caller supplies the confirmed server
/// selection and increments confirmationRevision after its own successful POST.
@MainActor
struct ChatReactionInteraction<Content: View>: View {
    let id: String
    let own: Bool
    let canReact: Bool
    let selectedKind: ChatReactionKind?
    let isReacting: Bool
    let confirmationRevision: UInt64
    let errorMessage: String?
    let copyText: String?
    let onReact: (ChatReactionKind?) -> Void
    let onOpen: (() -> Void)?
    let onPresent: (() -> Void)?
    private let content: Content

    @Environment(\.coupleAppTheme) private var theme
    @Environment(\.coupleModalControl) private var modalControl
    @StateObject private var presentation = MessageOpeningPresentation()
    @State private var presented = false
    @State private var awaitingConfirmation = false
    @State private var showAfterConfirmation = false
    @State private var feedback: UInt64 = 0

    init(id: String, own: Bool, canReact: Bool, selectedKind: ChatReactionKind?,
         isReacting: Bool, confirmationRevision: UInt64, errorMessage: String? = nil,
         copyText: String? = nil, onReact: @escaping (ChatReactionKind?) -> Void,
         onPresent: (() -> Void)? = nil, onOpen: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.id = id; self.own = own; self.canReact = canReact
        self.selectedKind = selectedKind; self.isReacting = isReacting
        self.confirmationRevision = confirmationRevision; self.errorMessage = errorMessage
        self.copyText = copyText; self.onReact = onReact; self.onOpen = onOpen; self.onPresent = onPresent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: own ? .trailing : .leading, spacing: 4) {
            interactionContent
                .contentShape(Rectangle())
                .gesture(interactionGesture)
                .accessibilityActions {
                    if canReact {
                        Button("Reaccionar") { presentPicker() }
                        Button("Me encanta") { request(.heart, revealAfterConfirmation: true) }
                    }
                    if let copyText {
                        Button("Copiar") { UIPasteboard.general.string = copyText }
                    }
                }
                .popover(isPresented: $presented, attachmentAnchor: .rect(.bounds)) {
                    picker
                        .presentationCompactAdaptation(.popover)
                        .presentationBackground(.clear)
                        .background {
                            if let ownerID = presentation.ownerID {
                                ChatReactionLifecycleObserver(ownerID: ownerID, presentation: presentation)
                            }
                        }
                }
            if let errorMessage, !errorMessage.isEmpty, !presented {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).accessibilityIdentifier("chat.reaction.error")
            }
        }
        .sensoryFeedback(.success, trigger: feedback)
        .onChange(of: confirmationRevision) { _, _ in
            guard awaitingConfirmation else { return }
            awaitingConfirmation = false
            feedback &+= 1
            if showAfterConfirmation { presentPicker() }
            showAfterConfirmation = false
        }
        .onChange(of: errorMessage) { _, message in
            if message != nil { awaitingConfirmation = false; showAfterConfirmation = false }
        }
        .onChange(of: canReact) { _, allowed in if !allowed { resetInteraction() } }
        .onChange(of: id) { _, _ in resetInteraction() }
        .onChange(of: presented) { _, value in if !value { presentation.requestedDismissal() } }
        .onChange(of: modalControl.dismissalVersion) { _, _ in resetInteraction() }
        .onDisappear { resetInteraction() }
    }

    @ViewBuilder private var interactionContent: some View {
        if let onOpen {
            // The wrapper arbitrates double vs single tap before opening. Its
            // card content must not contain a competing Button action.
            content.allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.reaction.target.\(id)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, onOpen)
        } else {
            // Audio controls remain independent native targets.
            content
        }
    }

    private var interactionGesture: AnyGesture<Void> {
        let hold = LongPressGesture(minimumDuration: 0.4, maximumDistance: 10)
        let double = TapGesture(count: 2)
        if onOpen != nil {
            return AnyGesture(hold.exclusively(before: double.exclusively(before: TapGesture()))
                .onEnded { result in
                    switch result {
                    case .first: presentPicker()
                    case .second(.first): request(.heart, revealAfterConfirmation: true)
                    case .second(.second): onOpen?()
                    }
                }.map { _ in () })
        }
        return AnyGesture(hold.exclusively(before: double)
            .onEnded { result in
                switch result {
                case .first: presentPicker()
                case .second: request(.heart, revealAfterConfirmation: true)
                }
            }.map { _ in () })
    }

    private var picker: some View {
        VStack(spacing: 8) {
            ReactionBubble {
                HStack(spacing: 2) {
                    ForEach(ChatReactionKind.allCases, id: \.rawValue) { kind in
                        Button { request(selectedKind == kind ? nil : kind) } label: {
                            ReactionEmojiLabel(symbol: kind.symbol, selected: selectedKind == kind,
                                               tint: theme.accent)
                        }
                        .accessibilityIdentifier("chat.reaction.\(kind.rawValue)")
                        .accessibilityLabel(kind.accessibilityLabel)
                        .accessibilityValue(selectedKind == kind ? "Seleccionada" : "")
                        .accessibilityAddTraits(selectedKind == kind ? .isSelected : [])
                        .disabled(isReacting || !canReact)
                    }
                }.buttonStyle(ReactionBubbleButtonStyle())
            }
            if isReacting {
                ProgressView().accessibilityLabel("Enviando reacción")
            }
            if let copyText {
                Button("Copiar", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = copyText; presented = false
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.plain).accessibilityIdentifier("chat.reaction.copy")
            }
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).accessibilityIdentifier("chat.reaction.picker-error")
            }
        }
        .padding(.vertical, 6).fixedSize(horizontal: true, vertical: false)
        .tint(theme.accent)
    }

    private func presentPicker() {
        guard canReact else { return }
        if presented { return }
        guard presentation.begin(modalControl) != nil else { return }
        onPresent?()
        presented = true
    }

    private func request(_ kind: ChatReactionKind?, revealAfterConfirmation: Bool = false) {
        guard canReact, !isReacting else { return }
        awaitingConfirmation = true
        showAfterConfirmation = revealAfterConfirmation
        onReact(kind)
    }

    private func resetInteraction() {
        presented = false; awaitingConfirmation = false; showAfterConfirmation = false
        presentation.requestedDismissal()
    }
}

@MainActor
private struct ChatReactionLifecycleObserver: UIViewControllerRepresentable {
    let ownerID: UUID
    let presentation: MessageOpeningPresentation
    func makeUIViewController(context: Context) -> MessageOpeningLifecycleController {
        presentation.didMount(ownerID)
        return MessageOpeningLifecycleController(ownerID: ownerID, presentation: presentation)
    }
    func updateUIViewController(_ controller: MessageOpeningLifecycleController, context: Context) {}
    static func dismantleUIViewController(_ controller: MessageOpeningLifecycleController, coordinator: ()) {
        if controller.viewIfLoaded?.window == nil { controller.presentation.didClose(controller.ownerID) }
    }
}
