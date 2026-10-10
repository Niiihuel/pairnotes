import PairNotesCore
import SwiftUI
import UIKit

/// Audio drafts have their own account/pair scope and never inherit letter attachments.
struct AudioMessageDraft: Codable, Equatable {
    var id = UUID().uuidString.lowercased()
    var opensAt: Date?
    var serverSaved = false
    var sealAttempted = false
}

struct AudioMessageComposer: View {
    @ObservedObject var services: AppServices
    @ObservedObject var interaction: ChatAudioInteraction
    var onSent: @MainActor (TimeCapsuleLetter) -> Void
    var onCancel: @MainActor () -> Void
    private let storage: MemoryCompositionStorage
    private let scope: String
    private let ownsInteraction: Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voice: VoiceNoteController
    @State private var draft: AudioMessageDraft
    @State private var audio: Data?
    @State private var audioDirty = false
    @State private var busy = false
    @State private var finished = false
    @State private var confirmSchedule = false
    @State private var error: String?
    @State private var sendTask: Task<Void, Never>?
    @State private var recordTask: Task<Void, Never>?
    @State private var recordRequest: UUID?
    @State private var visible = false
    @State private var handledCommand: UUID?
    #if DEBUG && targetEnvironment(simulator)
    private var fixtureSend: ((Data) -> Void)?

    func fixtureDelivery(_ action: @escaping (Data) -> Void) -> Self {
        var copy = self
        copy.fixtureSend = action
        return copy
    }
    #endif

    init(services: AppServices, onSent: @escaping @MainActor (TimeCapsuleLetter) -> Void,
         onCancel: @escaping @MainActor () -> Void = {}, startsRecording: Bool = false,
         interaction: ChatAudioInteraction? = nil, voice: VoiceNoteController? = nil) {
        self.services = services; self.onSent = onSent; self.onCancel = onCancel
        let control = interaction ?? ChatAudioInteraction()
        ownsInteraction = interaction == nil
        if interaction == nil { control.open(startRecording: startsRecording) }
        self.interaction = control
        _voice = StateObject(wrappedValue: voice ?? VoiceNoteController())
        let key = services.privateImageKey("chat-audio-composition")
        scope = key
        let storage = MemoryCompositionStorage(key: key)
        self.storage = storage
        _draft = State(initialValue: storage.loadValue() ?? AudioMessageDraft())
        _audio = State(initialValue: storage.audio())
    }

    private var currentScope: Bool { services.privateImageKey("chat-audio-composition") == scope }
    private var canSend: Bool {
        currentScope && !busy && !voice.recording && !voice.requestingPermission &&
            (draft.sealAttempted || (audio != nil && (draft.opensAt.map { $0 > Date() } ?? true)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if currentScope {
                if interaction.phase == .holding {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").foregroundStyle(.red).accessibilityHidden(true)
                        Text(VoiceTime.label(voice.elapsed)).monospacedDigit()
                        Spacer(minLength: 0)
                        Label("Deslizá para cancelar", systemImage: "chevron.left")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(minHeight: 44).accessibilityIdentifier("chat.audio.holding")
                } else if voice.recording {
                    recordingControls
                } else if let audio {
                    reviewControls(audio)
                } else {
                    HStack {
                        Button("Cancelar", systemImage: "trash") { discard() }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                        Text(voice.requestingPermission ? "Permiso del micrófono…" : "Mantené pulsado para grabar")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if !voice.requestingPermission {
                            Button("Grabar", systemImage: "mic.fill") { record() }
                                .frame(minHeight: 44).accessibilityIdentifier("chat.audio.record")
                        }
                    }
                }
                VoiceControllerNotice(controller: voice)
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("chat.audio.error") }
                if draft.sealAttempted {
                    Text("Envío sin confirmar. Tocá enviar para reintentar.").font(.caption).foregroundStyle(.secondary)
                }
                if ownsInteraction {
                    HStack { Spacer(); ChatAudioRecordButton(interaction: interaction,
                        tint: UIColor(services.personalization.theme.accent), onBegin: {})
                        .frame(width: 44, height: 44) }
                }
            }
        }
        .privacySensitive()
        .confirmationDialog("¿Programar este audio?", isPresented: $confirmSchedule, titleVisibility: .visible) {
            Button("Enviar para el \(draft.opensAt?.formatted(date: .abbreviated, time: .shortened) ?? "")") { send() }
            Button("Seguir editando", role: .cancel) {}
        }
        .onChange(of: draft) { _, _ in if !finished { _ = persist() }; updateInteraction() }
        .onChange(of: interaction.command?.id) { _, _ in handleCommand() }
        .onChange(of: voice.recording) { old, recording in
            if old && !recording && interaction.phase == .holding { interaction.review() }
            updateInteraction()
        }
        .onChange(of: voice.requestingPermission) { _, _ in updateInteraction() }
        .onChange(of: busy) { _, _ in updateInteraction() }
        .onChange(of: audio) { _, _ in updateInteraction() }
        .onAppear {
            visible = true
            voice.didRecord = { data in
                guard currentScope, !finished else { return }
                audio = data; audioDirty = true; _ = persist()
            }
            updateInteraction()
            // Reopening a persisted draft must never replace it with a new take.
            if audio != nil || draft.serverSaved || draft.sealAttempted {
                handledCommand = interaction.command?.id; interaction.review()
            } else { handleCommand() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && !voice.requestingPermission) {
                cancelRecordTask()
                voice.suspend(); interaction.review(); _ = persist(); updateInteraction()
            }
        }
        .onDisappear {
            visible = false; cancelRecordTask()
            voice.stopAll()
            if !finished { _ = persist() }
            voice.didRecord = nil
            sendTask?.cancel(); sendTask = nil
        }
        .onChange(of: services.privateImageKey("chat-audio-composition")) { _, value in
            if value != scope {
                cancelRecordTask()
                voice.didRecord = nil; voice.cancelRecording(); voice.stopAll()
                sendTask?.cancel(); sendTask = nil
                interaction.reset()
            }
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
                Text("\(VoiceTime.label(voice.elapsed)) / 1:00").font(.caption.monospacedDigit())
                liveWaveform
            }.frame(height: 32)
            HStack {
                trashButton
                Spacer(minLength: 0)
                Button { voice.pauseRecording(); interaction.review(); updateInteraction() } label: {
                    Image(systemName: "pause.fill").foregroundStyle(.red).frame(width: 44, height: 44)
                }.accessibilityLabel("Pausar grabación").accessibilityIdentifier("chat.audio.pause")
                Spacer(minLength: 0)
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).frame(width: 44, height: 44)
            }
        }.accessibilityIdentifier("chat.audio.locked")
    }

    private var liveWaveform: some View {
        HStack(spacing: 2) {
            ForEach(voice.levels.indices, id: \.self) { index in
                Capsule().fill(services.personalization.theme.accent)
                    .frame(maxWidth: .infinity).frame(height: max(3, 26 * voice.levels[index]))
            }
        }.frame(height: 28).accessibilityHidden(true)
    }

    private func reviewControls(_ data: Data) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                trashButton
                Button { if voice.playing { voice.pause() } else { voice.play(data) } } label: {
                    Image(systemName: voice.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.disabled(busy || voice.duration <= 0)
                    .accessibilityLabel(voice.playing ? "Pausar audio" : "Escuchar audio")
                    .accessibilityIdentifier("chat.audio.preview")
                VStack(spacing: 0) {
                    VoiceWaveformView(data: data, progress: voice.duration > 0 ? voice.elapsed / voice.duration : 0,
                                      height: 28)
                        .frame(height: 28).allowsHitTesting(false)
                        .overlay {
                            Slider(value: Binding(get: { voice.duration > 0 ? voice.elapsed / voice.duration : 0 },
                                set: { voice.seek(to: $0) }), in: 0...1)
                                .opacity(0.025).accessibilityLabel("Posición del audio")
                                .accessibilityValue("\(VoiceTime.label(voice.elapsed)) de \(VoiceTime.label(voice.duration))")
                                .disabled(busy || voice.duration <= 0)
                        }
                    Text(VoiceTime.label(voice.playing ? voice.elapsed : voice.duration))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                if voice.canResumeRecording, !draft.serverSaved, !draft.sealAttempted {
                    Button("Continuar", systemImage: "mic.fill") { resume() }
                        .font(.caption).frame(minHeight: 44).accessibilityIdentifier("chat.audio.resume")
                }
                Spacer(minLength: 0)
                MessageOpeningControl(opensAt: $draft.opensAt, compact: true)
                    .disabled(busy || draft.sealAttempted)
                Button { close() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("Conservar borrador y cerrar").disabled(busy)
            }
        }
        .accessibilityIdentifier("chat.audio.review")
        .task(id: data) {
            guard !Task.isCancelled, !voice.recording else { return }
            voice.prepare(data)
        }
    }

    private var trashButton: some View {
        Button(role: .destructive) { discard() } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
            .disabled(busy || draft.sealAttempted).accessibilityLabel("Eliminar audio")
            .accessibilityIdentifier("chat.audio.discard")
    }

    private func updateInteraction() {
        interaction.busy = busy
        interaction.requestingPermission = voice.requestingPermission
        interaction.canSend = canSend || (voice.recording && !busy && !voice.requestingPermission)
    }

    private func handleCommand() {
        guard visible, currentScope, let command = interaction.command, command.id != handledCommand else { return }
        handledCommand = command.id
        switch command.command {
        case .start: record()
        case .cancel: discard()
        case .finishAndSend:
            if voice.requestingPermission || (!voice.recording && audio == nil) {
                cancelRecordTask(); voice.cancelRecording()
                interaction.reset(); onCancel(); return
            }
            voice.finishRecording(); interaction.review(); updateInteraction()
            guard voice.error == nil else { return }
            if draft.opensAt == nil || draft.sealAttempted { send() } else { confirmSchedule = true }
        case .pause:
            cancelRecordTask()
            if voice.recording { voice.pauseRecording() }
            else { voice.finishRecording() }
            interaction.review(); updateInteraction()
        case .resume: resume()
        case .close: close()
        }
    }

    private func close() {
        guard !busy else { return }
        cancelRecordTask()
        voice.suspend()
        if persist() { interaction.reset(); onCancel() }
    }

    private func record() {
        guard currentScope, !busy, !draft.sealAttempted, recordTask == nil,
              !voice.recording, !voice.requestingPermission else { return }
        let request = UUID()
        recordRequest = request
        recordTask = Task { @MainActor in
            defer {
                if recordRequest == request {
                    recordTask = nil; recordRequest = nil
                    if !voice.recording, interaction.phase == .holding { interaction.review() }
                    updateInteraction()
                }
            }
            guard visible, currentScope, scenePhase == .active, !Task.isCancelled else { return }
            await voice.record()
        }
    }

    private func resume() {
        guard currentScope, !busy, !draft.sealAttempted, recordTask == nil, voice.canResumeRecording else { return }
        interaction.lock()
        let request = UUID()
        recordRequest = request
        recordTask = Task { @MainActor in
            defer {
                if recordRequest == request { recordTask = nil; recordRequest = nil; updateInteraction() }
            }
            guard visible, currentScope, scenePhase == .active, !Task.isCancelled else { return }
            await voice.resumeRecording()
        }
    }

    private func cancelRecordTask() {
        recordRequest = nil
        recordTask?.cancel(); recordTask = nil
    }

    @discardableResult private func persist() -> Bool {
        guard currentScope, !finished else { return false }
        do {
            if audioDirty { try storage.saveAudio(audio); audioDirty = false }
            try storage.saveValue(draft)
            return true
        } catch { self.error = "No se pudo guardar el audio en este iPhone."; return false }
    }

    private func ensureCurrentScope() throws {
        try Task.checkCancellation()
        guard currentScope, !finished else { throw CancellationError() }
    }

    private func completed(_ letter: TimeCapsuleLetter) {
        guard currentScope, !finished else { return }
        finished = true; voice.didRecord = nil; voice.stopAll(); storage.clear(); interaction.reset()
        onSent(letter)
    }

    private func send() {
        guard canSend else { return }
        voice.pause()
        guard persist() else { return }
        #if DEBUG && targetEnvironment(simulator)
        if let fixtureSend, let audio {
            finished = true; voice.didRecord = nil; storage.clear(); interaction.reset()
            fixtureSend(audio); onCancel()
            return
        }
        #endif
        busy = true; error = nil
        sendTask = Task { @MainActor in
            defer { busy = false; sendTask = nil }
            do {
                try ensureCurrentScope()
                if draft.sealAttempted {
                    let existing = try await services.openLetter(id: draft.id)
                    try ensureCurrentScope()
                    if existing.status == "sealed" { completed(existing); return }
                    draft.sealAttempted = false
                    guard persist() else { return }
                }
                guard let audio else { throw ServiceError.invalidResponse }
                _ = try await services.saveLetterDraft(id: draft.id, title: "Mi voz para vos", body: "",
                    opensAt: draft.opensAt ?? Date(), noteID: nil)
                try ensureCurrentScope()
                draft.serverSaved = true
                guard persist() else { return }
                try await services.uploadLetterAsset(id: draft.id, role: "audio", data: audio)
                try ensureCurrentScope()
                draft.sealAttempted = true
                guard persist() else { return }
                let letter = try await services.sealLetter(id: draft.id, immediate: draft.opensAt == nil)
                try ensureCurrentScope()
                completed(letter)
            } catch {
                guard currentScope, !Task.isCancelled else { return }
                if draft.sealAttempted, let known = try? await services.openLetter(id: draft.id) {
                    guard currentScope, !Task.isCancelled else { return }
                    if known.status == "sealed" { completed(known); return }
                    if known.status == "draft" { draft.sealAttempted = false; _ = persist() }
                }
                self.error = "No se pudo confirmar el envío. Tu audio se conserva para reintentar."
            }
        }
    }

    private func discard() {
        guard currentScope, !busy, !draft.sealAttempted else { return }
        cancelRecordTask()
        voice.didRecord = nil; voice.cancelRecording(); voice.stopAll(); error = nil
        if !draft.serverSaved { clearDraft(); return }
        busy = true
        sendTask = Task { @MainActor in
            defer { busy = false; sendTask = nil }
            do {
                try ensureCurrentScope()
                try await services.deleteLetterDraft(id: draft.id)
                try ensureCurrentScope()
                clearDraft()
            } catch {
                guard currentScope, !Task.isCancelled else { return }
                self.error = "No se pudo eliminar el borrador. Volvé a intentar."
            }
        }
    }

    private func clearDraft() {
        finished = true; storage.clear(); audio = nil; audioDirty = false
        interaction.reset(); onCancel()
    }
}

@MainActor
final class ChatAudioInteraction: ObservableObject {
    enum Phase: Equatable { case idle, holding, locked, review }
    enum Command: Equatable { case start, cancel, finishAndSend, pause, resume, close }
    struct Request: Equatable {
        let id = UUID()
        let command: Command
    }

    @Published private(set) var phase: Phase = .idle
    @Published var command: Request?
    @Published var busy = false
    @Published var requestingPermission = false
    @Published var canSend = false

    private var holdInFlight = false
    private var cancelledHold = false

    var isPresented: Bool { phase != .idle }

    func beginHold() {
        guard phase == .idle, !holdInFlight, !busy, !requestingPermission else { return }
        holdInFlight = true
        cancelledHold = false
        phase = .holding
        emit(.start)
    }

    func moveHold(translation: CGSize) {
        guard holdInFlight, !cancelledHold, phase == .holding else { return }
        if translation.width <= -80, abs(translation.width) >= abs(translation.height) {
            cancelledHold = true
            // Keep the panel mounted until it has stopped the engine and discarded
            // its local draft, then its cancellation handler calls reset().
            phase = .review
            emit(.cancel)
        } else if translation.height <= -70, abs(translation.height) > abs(translation.width) {
            phase = .locked
        }
    }

    func endHold(cancelled: Bool) {
        guard holdInFlight else { return }
        defer { holdInFlight = false }
        guard !cancelledHold, phase == .holding else { return }
        phase = .review
        emit(cancelled ? .pause : .finishAndSend)
    }

    func tap() {
        guard !holdInFlight, !busy else { return }
        switch phase {
        case .idle:
            guard !requestingPermission else { return }
            cancelledHold = false
            phase = .locked
            emit(.start)
        case .locked, .review:
            guard canSend, !requestingPermission else { return }
            emit(.finishAndSend)
        case .holding:
            break
        }
    }

    func open(startRecording: Bool) {
        holdInFlight = false
        cancelledHold = false
        phase = startRecording ? .locked : .review
        command = startRecording ? Request(command: .start) : nil
    }

    func review() { phase = .review }

    func lock() { phase = .locked }

    func reset() {
        phase = .idle
        command = nil
        busy = false
        requestingPermission = false
        canSend = false
        // If reset follows a cancellation, UIKit may still deliver movement/release.
        // Keep that gesture latched until its recognizer finishes.
        cancelledHold = holdInFlight
    }

    private func emit(_ value: Command) { command = Request(command: value) }
}

/// The same native control stays mounted as the recorder changes height or state.
/// UIKit owns the touch sequence, so dismissing the keyboard cannot cancel a SwiftUI drag.
@MainActor
struct ChatAudioRecordButton: UIViewRepresentable {
    @ObservedObject var interaction: ChatAudioInteraction
    var tint: UIColor
    var onBegin: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.layer.cornerRadius = 22
        button.clipsToBounds = true
        let progress = UIActivityIndicatorView(style: .medium)
        progress.tag = 4101
        progress.isUserInteractionEnabled = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.18
        hold.allowableMovement = .greatestFiniteMagnitude
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        update(button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        update(button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 44, height: 44)
    }

    private func update(_ button: UIButton) {
        let sending = interaction.phase == .locked || interaction.phase == .review
        button.setImage(interaction.busy ? nil : UIImage(systemName: sending ? "paperplane.fill" : "mic.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)), for: .normal)
        button.backgroundColor = tint
        button.tintColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
        if let progress = button.viewWithTag(4101) as? UIActivityIndicatorView {
            progress.color = button.tintColor
            if interaction.busy { progress.startAnimating() } else { progress.stopAnimating() }
        }
        button.accessibilityIdentifier = sending ? "chat.audio.send" : "chat.record"
        button.accessibilityLabel = sending ? "Enviar audio" : "Grabar audio"
        button.accessibilityHint = sending ? "Finaliza la grabación y envía el audio" :
            "Mantené presionado para grabar. Deslizá a la izquierda para cancelar o hacia arriba para seguir sin mantener presionado. También podés tocar para comenzar."
        button.accessibilityValue = interaction.busy ? "Enviando" :
            (interaction.requestingPermission ? "Esperando permiso del micrófono" : nil)
        // Disabling the UIView while permission is requested or sending starts would
        // cancel its recognizer and lose the final release of the active gesture.
        button.isEnabled = true
        let unavailable = interaction.busy || (sending && (!interaction.canSend || interaction.requestingPermission))
        button.accessibilityTraits = unavailable ? [.button, .notEnabled] : [.button]
        button.alpha = unavailable ? 0.45 : 1
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ChatAudioRecordButton
        private var origin = CGPoint.zero
        private var consumedTouch = false
        private var touchSequence = 0

        init(_ parent: ChatAudioRecordButton) { self.parent = parent }

        @objc func touchDown() {
            touchSequence += 1
            consumedTouch = false
        }

        @objc func tap() {
            guard !consumedTouch else { return }
            parent.onBegin()
            parent.interaction.tap()
        }

        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                consumedTouch = true
                // nil resolves to window coordinates, independent of layout changes
                // caused by keyboard dismissal or the expanded recording controls.
                origin = recognizer.location(in: nil)
                parent.onBegin()
                parent.interaction.beginHold()
            case .changed:
                let location = recognizer.location(in: nil)
                parent.interaction.moveHold(translation: CGSize(
                    width: location.x - origin.x, height: location.y - origin.y))
            case .ended:
                finishHold(cancelled: false)
            case .cancelled, .failed:
                finishHold(cancelled: true)
            default:
                break
            }
        }

        private func finishHold(cancelled: Bool) {
            parent.interaction.endHold(cancelled: cancelled)
            let finishedSequence = touchSequence
            DispatchQueue.main.async { [weak self] in
                guard let self, self.touchSequence == finishedSequence else { return }
                // Consume touch-up from this event, then allow a later VoiceOver
                // activation, which need not be preceded by touchDown.
                self.consumedTouch = false
            }
        }
    }
}
