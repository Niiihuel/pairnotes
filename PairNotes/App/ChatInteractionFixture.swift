#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import PairNotesCore

/// An explicitly launched simulator-only fixture for real keyboard and finger
/// tests of the production scroll container and composer. Never built in Release.
@MainActor
struct ChatInteractionFixture: View {
    @StateObject private var services = AppServices()
    @State private var prepared = false
    @State private var atBottom = true
    @State private var keyboardDismissalRequest: UInt64 = 0
    @State private var scrollRequest = UUID()
    @State private var messageCount = 30
    @State private var actionCount = 0
    @State private var geometryDescription = "Awaiting scroll geometry"
    @State private var reactionKinds: [Int: ChatReactionKind] = [:]
    @State private var reactionRevisions: [Int: UInt64] = [:]
    @State private var reactionErrors: [Int: String] = [:]
    @State private var pendingReaction: FixtureReactionRequest?
    @State private var reactionRequestCount = 0
    @State private var reactionConfirmationCount = 0

    private var testsReactions: Bool {
        ProcessInfo.processInfo.arguments.contains("-pairnotes-chat-reaction-enabled")
    }

    private var testsNativeChildren: Bool {
        ProcessInfo.processInfo.arguments.contains("-pairnotes-chat-reaction-children")
    }

    var body: some View {
        NavigationStack {
            if prepared {
                ChatConversationScrollView(atBottom: $atBottom, newestItemID: "fixture.\(messageCount - 1)",
                                           scrollRequest: scrollRequest, hasMessages: true,
                                           dismissKeyboard: dismissKeyboard) {
                    LazyVStack(spacing: 16) {
                        ForEach(0..<messageCount, id: \.self) { index in
                            HStack {
                                Spacer(minLength: 60)
                                fixtureMessage(index)
                            }.id("fixture.\(index)")
                        }
                    }.padding(14)
                }
                .onScrollGeometryChange(for: String.self) { geometry in
                    "content=\(geometry.contentSize); container=\(geometry.containerSize); " +
                    "offset=\(geometry.contentOffset); insets=\(geometry.contentInsets); visible=\(geometry.visibleRect)"
                } action: { _, value in geometryDescription = value }
                .overlay(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        Text("atBottom=\(atBottom); \(geometryDescription)")
                            .accessibilityIdentifier("fixture.geometry")
                        if testsReactions {
                            Text(reactionDescription).accessibilityIdentifier("fixture.reaction.state")
                        }
                    }
                    .font(.system(size: 1)).foregroundStyle(.clear)
                    .frame(width: 1, height: 1).allowsHitTesting(false)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ChatMessageComposer(services: services, createPhoto: {}, takePhoto: {},
                                        createDrawing: {}, showDrafts: {}, createLetter: {}, recordAudio: {},
                                        keyboardDismissalRequest: keyboardDismissalRequest, onSent: { _ in })
                        .background(services.personalization.theme.canvas)
                }
                .chatReactionOverlay()
                .toolbar {
                    if testsReactions {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            Button("Confirmar", action: confirmReaction)
                                .disabled(pendingReaction == nil)
                                .accessibilityIdentifier("fixture.reaction.confirm")
                            Button("Fallar", action: failReaction)
                                .disabled(pendingReaction == nil)
                                .accessibilityIdentifier("fixture.reaction.fail")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Recibir") { messageCount += 1 }
                            .accessibilityIdentifier("fixture.incoming")
                    }
                }
                .navigationTitle("Prueba de chat")
            } else {
                Text("La prueba requiere una sesión limpia.")
                    .accessibilityIdentifier("fixture.unavailable")
            }
        }
        .tint(services.personalization.theme.accent)
        .environment(\.coupleAppTheme, services.personalization.theme)
        .background(services.personalization.theme.canvas)
        .task {
            guard !prepared, services.identity == nil else { return }
            // UI tests run in an isolated, unsigned simulator, without sessions.
            // Reset only its guest message fixture; no account or API is invoked.
            let storage = MemoryCompositionStorage(key: services.privateImageKey("message-draft"))
            do {
                try storage.saveValue(FixtureDraft(text: "", id: UUID()))
                prepared = true
            } catch { return }
        }
    }

    private func dismissKeyboard() { keyboardDismissalRequest &+= 1 }

    @ViewBuilder private func fixtureMessage(_ index: Int) -> some View {
        if testsReactions {
            VStack(alignment: .leading, spacing: 10) {
                ChatReactionInteraction(id: "fixture.\(index)", own: true, canReact: true,
                    selectedKind: reactionKinds[index], isReacting: pendingReaction?.index == index,
                    confirmationRevision: reactionRevisions[index] ?? 0,
                    errorMessage: reactionErrors[index],
                    copyText: "Contenido sintético para recorrer el historial y comprobar su posición.",
                    onReact: { kind in requestReaction(kind, at: index) },
                    onPresent: dismissKeyboard,
                    onOpen: !testsNativeChildren && index == messageCount - 1 ? { actionCount += 1 } : nil) {
                    VStack(alignment: .leading, spacing: 10) {
                        messageText(index)
                        if testsNativeChildren, index == messageCount - 1 {
                            Button("Reproducir", systemImage: "play.fill") { actionCount += 1 }
                                .frame(minHeight: 44).buttonStyle(.bordered)
                                .accessibilityIdentifier("fixture.reaction.native-action")
                        }
                    }
                    .padding(14)
                    .background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 20))
                }
                if index == messageCount - 1 {
                    Button("Abrir mensaje") { actionCount += 1 }
                        .frame(minHeight: 44).accessibilityIdentifier("fixture.message.action")
                    Text("Acciones: \(actionCount)").accessibilityIdentifier("fixture.action.count")
                }
            }.frame(maxWidth: 260, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                messageText(index)
                if index == messageCount - 1 {
                    Button("Abrir mensaje") { actionCount += 1 }
                        .frame(minHeight: 44).accessibilityIdentifier("fixture.message.action")
                    Text("Acciones: \(actionCount)").accessibilityIdentifier("fixture.action.count")
                }
            }
            .padding(14).frame(maxWidth: 260, alignment: .leading)
            .background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func messageText(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mensaje de prueba \(index)").accessibilityIdentifier("fixture.message.\(index)")
            Text("Contenido sintético para recorrer el historial y comprobar su posición.")
        }
    }

    private var reactionDescription: String {
        let current = messageCount - 1
        return "requests=\(reactionRequestCount); confirmations=\(reactionConfirmationCount); " +
            "pending=\(pendingReaction.map { $0.kind?.rawValue ?? "none" } ?? "idle"); " +
            "confirmed=\(reactionKinds[current]?.rawValue ?? "none"); actions=\(actionCount)"
    }

    private func requestReaction(_ kind: ChatReactionKind?, at index: Int) {
        guard pendingReaction == nil else { return }
        reactionErrors[index] = nil
        pendingReaction = FixtureReactionRequest(index: index, kind: kind)
        reactionRequestCount += 1
        dismissKeyboard()
    }

    private func confirmReaction() {
        guard let pendingReaction else { return }
        reactionKinds[pendingReaction.index] = pendingReaction.kind
        reactionRevisions[pendingReaction.index, default: 0] &+= 1
        reactionConfirmationCount += 1
        self.pendingReaction = nil
    }

    private func failReaction() {
        guard let pendingReaction else { return }
        reactionErrors[pendingReaction.index] = "No se pudo enviar. Intentá otra vez."
        self.pendingReaction = nil
    }

    private struct FixtureReactionRequest {
        let index: Int
        let kind: ChatReactionKind?
    }

    private struct FixtureDraft: Encodable {
        let text: String
        let id: UUID
    }
}
#endif
