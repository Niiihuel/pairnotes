import SwiftUI

/// Uses the visible scroll geometry, rather than LazyVStack's preloaded rows,
/// to keep reading position and decide when the latest-message control appears.
struct ChatConversationScrollView<Content: View>: View {
    @Binding var atBottom: Bool
    let newestItemID: String?
    let scrollRequest: UUID
    let hasMessages: Bool
    let dismissKeyboard: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.coupleAppTheme) private var theme
    @State private var userScrolling = false

    private enum Target: Hashable { case latest }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content()
                    Color.clear.frame(height: 1).id(Target.latest)
                }
            }
            .accessibilityIdentifier("chat.history")
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.immediately)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { _ in
                dismissKeyboard()
            })
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: ChatScrollMetrics.self) { geometry in
                ChatScrollMetrics(contentHeight: geometry.contentSize.height,
                                  viewportHeight: geometry.containerSize.height,
                                  visibleBottom: geometry.visibleRect.maxY,
                                  bottomInset: geometry.contentInsets.bottom)
            } action: { old, new in
                let update = ChatScrollUpdate(previous: old, current: new,
                                              wasAtBottom: atBottom, userScrolling: userScrolling)
                atBottom = update.atBottom
                // Keep following the end throughout keyboard and lazy-row
                // layout changes. A temporary gap must not display the button
                // or cancel the scroll that is already bringing the end back.
                if update.shouldScroll { scroll(proxy, animated: false) }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasMessages, !atBottom {
                    Button {
                        dismissKeyboard()
                        scroll(proxy, animated: true)
                    } label: {
                        Label("Ir al último mensaje", systemImage: "chevron.down")
                            .labelStyle(.iconOnly).font(.body.weight(.semibold))
                            .frame(minWidth: 48, minHeight: 48)
                            .background(theme.accent, in: Circle())
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.latest")
                    .padding(14)
                }
            }
            .onChange(of: newestItemID) { _, _ in
                if atBottom, !userScrolling { scroll(proxy, animated: true) }
            }
            .onChange(of: scrollRequest) { _, _ in scroll(proxy, animated: true) }
        }
        .chatReactionViewport()
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        atBottom = true
        withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.22) : nil) {
            proxy.scrollTo(Target.latest, anchor: .bottom)
        }
    }
}

struct ChatScrollMetrics: Equatable {
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let bottomInset: CGFloat
    let isValid: Bool
    let isNearBottom: Bool

    init(contentHeight: CGFloat, viewportHeight: CGFloat, visibleBottom: CGFloat, bottomInset: CGFloat) {
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        self.bottomInset = bottomInset
        isValid = contentHeight.isFinite && viewportHeight.isFinite && visibleBottom.isFinite && bottomInset.isFinite &&
            contentHeight >= 0 && viewportHeight > 0
        // SwiftUI's visibleRect includes content underneath safe-area insets.
        // Exclude the composer, tab bar and keyboard from its lower edge;
        // containerSize is the usable viewport when the history is short.
        let usableBottom = visibleBottom - bottomInset
        isNearBottom = isValid && (contentHeight <= viewportHeight || contentHeight - usableBottom <= 60)
    }
}

struct ChatScrollUpdate {
    let atBottom: Bool
    let shouldScroll: Bool

    init(previous: ChatScrollMetrics, current: ChatScrollMetrics, wasAtBottom: Bool, userScrolling: Bool) {
        guard current.isValid else {
            atBottom = wasAtBottom
            shouldScroll = false
            return
        }
        let followingLatest = wasAtBottom && !userScrolling
        atBottom = followingLatest || current.isNearBottom
        shouldScroll = followingLatest && (!previous.isValid ||
            previous.contentHeight != current.contentHeight ||
            previous.viewportHeight != current.viewportHeight ||
            previous.bottomInset != current.bottomInset)
    }
}
