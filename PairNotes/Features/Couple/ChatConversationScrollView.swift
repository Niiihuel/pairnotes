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
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: ChatScrollMetrics.self) { geometry in
                ChatScrollMetrics(contentHeight: geometry.contentSize.height,
                                  viewportHeight: geometry.visibleRect.height,
                                  visibleBottom: geometry.visibleRect.maxY,
                                  bottomInset: geometry.contentInsets.bottom)
            } action: { old, new in
                guard new.isValid else { return }
                let keepLatestVisible = atBottom && !userScrolling && old.isValid &&
                    (old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight ||
                     old.bottomInset != new.bottomInset)
                atBottom = new.isNearBottom
                // Opening the keyboard or loading an image should keep the last
                // message visible only when the reader was already at the end.
                if keepLatestVisible { scroll(proxy, animated: false) }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasMessages, !atBottom {
                    Button("Ir al último mensaje", systemImage: "chevron.down") {
                        dismissKeyboard()
                        scroll(proxy, animated: true)
                    }
                    .labelStyle(.iconOnly).font(.body.weight(.semibold))
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("chat.latest")
                    .padding(14)
                }
            }
            .onChange(of: newestItemID) { _, _ in
                if atBottom, !userScrolling { scroll(proxy, animated: true) }
            }
            .onChange(of: scrollRequest) { _, _ in scroll(proxy, animated: true) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
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
        // visibleRect already accounts for content insets and keyboard-safe
        // layout. Adding the bottom inset again leaves a false gap at the end.
        isNearBottom = isValid && contentHeight - visibleBottom <= 60
    }
}
