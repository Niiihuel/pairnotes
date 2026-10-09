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
                .anchorPreference(key: ChatReactionMenuPreferenceKey.self, value: .bounds) { anchor in
                    if presented, let ownerID = presentation.ownerID {
                        ChatReactionMenuPreferences(menus: [ChatReactionMenuAnchor(ownerID: ownerID, bounds: anchor, own: own,
                            content: AnyView(picker), presentation: presentation,
                            dismiss: { presented = false })])
                    } else {
                        ChatReactionMenuPreferences()
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
        VStack(alignment: own ? .trailing : .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ChatReactionKind.allCases, id: \.rawValue) { kind in
                    Button { request(selectedKind == kind ? nil : kind) } label: {
                        Text(kind.symbol).font(.system(size: 25))
                            .frame(width: 44, height: 44)
                            .background(selectedKind == kind ? theme.accent.opacity(0.18) : .clear, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("chat.reaction.\(kind.rawValue)")
                    .accessibilityLabel(kind.accessibilityLabel)
                    .accessibilityValue(selectedKind == kind ? "Seleccionada" : "")
                    .accessibilityAddTraits(selectedKind == kind ? .isSelected : [])
                    .disabled(isReacting || !canReact)
                }
            }
            .buttonStyle(ReactionBubbleButtonStyle())
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(theme.card, in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.75).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.reaction.bar")
            if isReacting {
                ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Enviando reacción")
            }
            if let copyText {
                Button {
                    UIPasteboard.general.string = copyText; presented = false
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                        .font(.body).padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(width: 180, alignment: .leading).frame(minHeight: 48)
                        .contentShape(Rectangle())
                }
                .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12), lineWidth: 0.75).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                .buttonStyle(.plain).accessibilityIdentifier("chat.reaction.copy")
            }
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("chat.reaction.picker-error")
            }
        }
        .foregroundStyle(theme.ink)
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

private struct ChatReactionMenuAnchor {
    let ownerID: UUID
    let bounds: Anchor<CGRect>
    let own: Bool
    let content: AnyView
    let presentation: MessageOpeningPresentation
    let dismiss: () -> Void
}

private struct ChatReactionViewportAnchor {
    let bounds: Anchor<CGRect>
    let insets: EdgeInsets
}

private struct ChatReactionMenuPreferences {
    var menus: [ChatReactionMenuAnchor] = []
    var viewport: ChatReactionViewportAnchor?
}

private struct ChatReactionMenuPreferenceKey: PreferenceKey {
    static var defaultValue: ChatReactionMenuPreferences { ChatReactionMenuPreferences() }
    static func reduce(value: inout ChatReactionMenuPreferences, nextValue: () -> ChatReactionMenuPreferences) {
        let next = nextValue()
        value.menus.append(contentsOf: next.menus)
        if let viewport = next.viewport { value.viewport = viewport }
    }
}

extension View {
    /// Measure inside the caller's safeAreaInset, where the composer is already
    /// part of the excluded area. The outer overlay still intercepts its taps.
    func chatReactionViewport() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.anchorPreference(key: ChatReactionMenuPreferenceKey.self, value: .bounds) {
                    ChatReactionMenuPreferences(viewport: ChatReactionViewportAnchor(bounds: $0, insets: proxy.safeAreaInsets))
                }
            }
        }
    }

    /// Render above the conversation and composer, outside the scrolling rows.
    /// A native popover adds its own glass outline and arrow around both panels.
    func chatReactionOverlay() -> some View {
        overlayPreferenceValue(ChatReactionMenuPreferenceKey.self) { preferences in
            GeometryReader { proxy in
                if let menu = preferences.menus.last {
                    let history = preferences.viewport.map { proxy[$0.bounds] } ?? CGRect(origin: .zero, size: proxy.size)
                    let insets = preferences.viewport?.insets ?? proxy.safeAreaInsets
                    let viewport = CGRect(x: history.minX + insets.leading, y: history.minY + insets.top,
                        width: max(0, history.width - insets.leading - insets.trailing),
                        height: max(0, history.height - insets.top - insets.bottom))
                    ChatReactionMenuOverlay(menu: menu, anchor: proxy[menu.bounds], viewport: viewport)
                        .id(menu.ownerID)
                }
            }
        }
    }
}

private struct ChatReactionMenuOverlay: View {
    let menu: ChatReactionMenuAnchor
    let anchor: CGRect
    let viewport: CGRect
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var menuSize = CGSize(width: ChatReactionMenuPlacement.width, height: 110)

    var body: some View {
        let height = min(menuSize.height, max(1, viewport.height - 24))
        let fits = menuSize.height <= height
        let placement = ChatReactionMenuPlacement(anchor: anchor, viewport: viewport,
            menuSize: CGSize(width: ChatReactionMenuPlacement.width, height: height),
            alignRight: menu.own != (layoutDirection == .rightToLeft))
        ZStack(alignment: .topLeading) {
            Button(action: menu.dismiss) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain).ignoresSafeArea().accessibilityHidden(true)

            ScrollView(.vertical) {
                menu.content
                    .frame(width: ChatReactionMenuPlacement.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { menuSize = $0 }
            }
                .frame(width: ChatReactionMenuPlacement.width, height: height)
                .scrollDisabled(fits).scrollIndicators(.hidden).scrollClipDisabled(fits)
                .position(placement.center)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape, menu.dismiss)
                .accessibilityAction(named: Text("Cerrar reacciones"), menu.dismiss)
        }
        .onAppear { menu.presentation.didMount(menu.ownerID) }
        .onDisappear { menu.presentation.didClose(menu.ownerID) }
    }
}

/// Keeps both separate panels inside the visible history, including after the
/// keyboard closes or an error/large text changes the menu's measured height.
struct ChatReactionMenuPlacement {
    static let width: CGFloat = 286 // Six 44pt targets, five 2pt gaps, 12pt padding.
    let center: CGPoint

    init(anchor: CGRect, viewport: CGRect, menuSize: CGSize, alignRight: Bool) {
        let bounds = viewport.insetBy(dx: 12, dy: 12)
        let desiredX = alignRight ? anchor.maxX - menuSize.width : anchor.minX
        let above = anchor.minY - menuSize.height - 8
        let below = anchor.maxY + 8
        let desiredY: CGFloat
        if above >= bounds.minY {
            desiredY = above
        } else if below + menuSize.height <= bounds.maxY {
            desiredY = below
        } else {
            let spaceAbove = anchor.minY - bounds.minY
            let spaceBelow = bounds.maxY - anchor.maxY
            desiredY = spaceAbove >= spaceBelow ? above : below
        }
        let x = max(bounds.minX, min(desiredX, bounds.maxX - menuSize.width))
        let y = max(bounds.minY, min(desiredY, bounds.maxY - menuSize.height))
        center = CGPoint(x: x + menuSize.width / 2, y: y + menuSize.height / 2)
    }
}
