#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import PairNotesCore
import AVFoundation

/// An explicitly launched simulator-only fixture for real keyboard and finger
/// tests of the production scroll container and composer. Never built in Release.
@MainActor
struct ChatInteractionFixture: View {
    @StateObject private var services = AppServices()
    @StateObject private var audioInteraction = ChatAudioInteraction()
    @StateObject private var audioProbe = FixtureAudioProbe()
    @State private var composerHeight: CGFloat = 0
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

    private var testsAudio: Bool {
        ProcessInfo.processInfo.arguments.contains("-pairnotes-chat-audio-enabled")
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
                        if testsAudio {
                            Text("\(audioProbe.description); phase=\(audioInteraction.phase); height=\(Int(composerHeight))")
                                .accessibilityIdentifier("fixture.audio.state")
                        }
                    }
                    .font(.system(size: 1)).foregroundStyle(.clear)
                    .frame(width: 1, height: 1).allowsHitTesting(false)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ChatMessageComposer(services: services, createPhoto: {}, takePhoto: {},
                                        createDrawing: {}, showDrafts: {}, createLetter: {}, recordAudio: {},
                                        audioInteraction: audioInteraction,
                                        keyboardDismissalRequest: keyboardDismissalRequest, onSent: { _ in }) {
                        if testsAudio {
                            AudioMessageComposer(services: services, onSent: { _ in },
                                interaction: audioInteraction, voice: audioProbe.voice)
                                .fixtureDelivery { audioProbe.deliver($0) }
                        }
                    }
                        .background(services.personalization.theme.canvas)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
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
        .preferredColorScheme(testsAudio ?
            (ProcessInfo.processInfo.arguments.contains("-pairnotes-chat-audio-dark") ? .dark : .light) : nil)
        .onReceive(audioProbe.voice.$recordedData) { data in
            if testsAudio, let data { audioProbe.review(data) }
        }
        .onReceive(audioProbe.voice.$playing) { playing in
            if testsAudio { audioProbe.observePlayback(playing) }
        }
        .task {
            guard !prepared, services.identity == nil else { return }
            // UI tests run in an isolated, unsigned simulator, without sessions.
            // Reset only its guest message fixture; no account or API is invoked.
            let storage = MemoryCompositionStorage(key: services.privateImageKey("message-draft"))
            do {
                try storage.saveValue(FixtureDraft(text: "", id: UUID()))
                if testsAudio {
                    MemoryCompositionStorage(key: services.privateImageKey("chat-audio-composition")).clear()
                }
                if ProcessInfo.processInfo.arguments.contains("-pairnotes-chat-short-history") { messageCount = 2 }
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

/// Exercises the production recording lifecycle with finalized PCM, without a
/// microphone prompt, audio-session mutation, account, or delivery endpoint.
@MainActor
private final class FixtureAudioProbe: ObservableObject {
    @Published private var starts = 0
    @Published private var sent = 0
    @Published private var reviewedFrames = 0
    @Published private var sentFrames = 0
    @Published private var firstSample: Int16 = 0
    @Published private var lastSample: Int16 = 0
    @Published private var error = "none"
    @Published private var playbackStarts = 0
    @Published private var playbackStops = 0
    @Published private var playbackEarlyPauses = 0
    @Published private var playbackActive = false

    lazy var voice = VoiceNoteController(requestPermission: { true }, makeRecorder: { [weak self] url, settings in
        guard let self else { throw CocoaError(.userCancelled) }
        self.starts += 1
        return try FixtureAudioRecorder(url: url, settings: settings, sample: self.starts.isMultiple(of: 2) ? -8000 : 8000)
    }, managesAudioSession: false)

    var description: String {
        "sent=\(sent); starts=\(starts); reviewedFrames=\(reviewedFrames); sentFrames=\(sentFrames); " +
            "first=\(firstSample); last=\(lastSample); error=\(error); " +
            "playbackStarts=\(playbackStarts); playbackStops=\(playbackStops); " +
            "playbackEarlyPauses=\(playbackEarlyPauses); playing=\(playbackActive)"
    }

    /// Keep real AVAudioPlayer transitions observable after a short clip finishes.
    /// XCTest can wait for application idleness longer than this two-second audio.
    func observePlayback(_ playing: Bool) {
        guard playing != playbackActive else { return }
        playbackActive = playing
        if playing {
            playbackStarts += 1
        } else {
            playbackStops += 1
            if voice.elapsed > 0, voice.elapsed < voice.duration - 0.1 {
                playbackEarlyPauses += 1
            }
        }
    }

    func review(_ data: Data) {
        do { reviewedFrames = try inspect(data).frames }
        catch { self.error = "unreadable-review" }
    }

    func deliver(_ data: Data) {
        do {
            let captured = try inspect(data)
            sentFrames = captured.frames; firstSample = captured.first; lastSample = captured.last
            sent += 1
        } catch { self.error = "unreadable-delivery" }
    }

    private func inspect(_ data: Data) throws -> (frames: Int, first: Int16, last: Int16) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        defer { file.close() }
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer, frameCount: 1)
        guard buffer.frameLength == 1, let channel = buffer.int16ChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let first = channel[0][0]
        file.framePosition = file.length - 1
        try file.read(into: buffer, frameCount: 1)
        guard buffer.frameLength == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return (Int(file.length), first, channel[0][0])
    }
}

@MainActor
private final class FixtureAudioRecorder: VoiceRecordingDevice {
    let url: URL
    weak var delegate: (any AVAudioRecorderDelegate)?
    var isMeteringEnabled = false
    private var startedAt: Date?
    var currentTime: TimeInterval { min(2, startedAt.map { Date().timeIntervalSince($0) } ?? 0) }

    init(url: URL, settings: [String: Any], sample: Int16) throws {
        self.url = url
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        defer { file.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_000),
              let channel = buffer.int16ChannelData else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = 32_000
        for index in 0..<32_000 { channel[0][index] = sample }
        try file.write(from: buffer)
    }

    func record(forDuration duration: TimeInterval) -> Bool { startedAt = Date(); return true }
    func stop() { startedAt = nil }
    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { -12 }
}
#endif
