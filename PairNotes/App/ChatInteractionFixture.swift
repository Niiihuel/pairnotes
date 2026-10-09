#if DEBUG && targetEnvironment(simulator)
import SwiftUI

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
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Mensaje de prueba \(index)")
                                        .accessibilityIdentifier("fixture.message.\(index)")
                                    Text("Contenido sintético para recorrer el historial y comprobar su posición.")
                                    if index == messageCount - 1 {
                                        Button("Abrir mensaje") { actionCount += 1 }
                                            .frame(minHeight: 44).accessibilityIdentifier("fixture.message.action")
                                        Text("Acciones: \(actionCount)").accessibilityIdentifier("fixture.action.count")
                                    }
                                }
                                .padding(14).frame(maxWidth: 260, alignment: .leading)
                                .background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 20))
                            }.id("fixture.\(index)")
                        }
                    }.padding(14)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ChatMessageComposer(services: services, createPhoto: {}, takePhoto: {},
                                        createDrawing: {}, showDrafts: {}, createLetter: {}, recordAudio: {},
                                        keyboardDismissalRequest: keyboardDismissalRequest, onSent: { _ in })
                        .background(services.personalization.theme.canvas)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Recibir") { messageCount += 1 }
                            .accessibilityIdentifier("fixture.incoming")
                    }
                }
            } else {
                Text("La prueba requiere una sesión limpia.")
                    .accessibilityIdentifier("fixture.unavailable")
            }
        }
        .navigationTitle("Prueba de chat")
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

    private struct FixtureDraft: Encodable {
        let text: String
        let id: UUID
    }
}
#endif
