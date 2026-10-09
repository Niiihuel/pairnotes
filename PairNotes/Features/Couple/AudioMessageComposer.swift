import PairNotesCore
import SwiftUI

/// Deliberately separate from letter drafts: an audio message cannot inherit hidden text or photos.
struct AudioMessageDraft: Codable, Equatable {
    var id = UUID().uuidString.lowercased()
    var opensAt: Date?
    var serverSaved = false
    var sealAttempted = false
}

struct AudioMessageComposer: View {
    @ObservedObject var services: AppServices
    var onSent: @MainActor (TimeCapsuleLetter) -> Void
    var onCancel: @MainActor () -> Void
    let startsRecording: Bool
    private let storage: MemoryCompositionStorage
    private let scope: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var voice = VoiceNoteController()
    @State private var draft: AudioMessageDraft
    @State private var audio: Data?
    @State private var audioDirty = false
    @State private var busy = false
    @State private var finished = false
    @State private var confirmSchedule = false
    @State private var confirmDiscard = false
    @State private var error: String?
    @State private var sendTask: Task<Void, Never>?
    @State private var recordTask: Task<Void, Never>?
    @State private var visible = false
    @State private var started = false

    init(services: AppServices, onSent: @escaping @MainActor (TimeCapsuleLetter) -> Void,
         onCancel: @escaping @MainActor () -> Void = {}, startsRecording: Bool = false) {
        self.services = services; self.onSent = onSent; self.onCancel = onCancel
        self.startsRecording = startsRecording
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
        if currentScope {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tu audio").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        voice.suspend()
                        if persist() { onCancel() }
                    } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Cerrar grabador y conservar borrador")
                        .disabled(busy)
                }
                audioControls
                    .disabled(busy || draft.sealAttempted)
                VoiceControllerNotice(controller: voice)
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if draft.sealAttempted {
                    Text("El envío está pendiente de confirmación.").font(.footnote).foregroundStyle(.secondary)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { openingControl; sendButton }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { openingControl.fixedSize(horizontal: true, vertical: false); Spacer(minLength: 0); sendButton }
                        VStack(alignment: .leading, spacing: 8) { openingControl; sendButton }
                    }
                }
                if let date = draft.opensAt, date <= Date(), !draft.sealAttempted {
                    Text("Elegí una fecha futura o enviá ahora.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .privacySensitive()
            .confirmationDialog("¿Programar este audio?", isPresented: $confirmSchedule, titleVisibility: .visible) {
                Button("Enviar para el \(draft.opensAt?.formatted(date: .abbreviated, time: .shortened) ?? "")") { send() }
                Button("Seguir editando", role: .cancel) {}
            } message: {
                Text("Se abre el \(draft.opensAt?.formatted(date: .long, time: .shortened) ?? ""). Una vez enviado, no se puede cambiar.")
            }
            .confirmationDialog("¿Eliminar este audio?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Eliminar audio", role: .destructive) { discard() }
                Button("Conservar audio", role: .cancel) {}
            }
            .onChange(of: draft) { _, _ in if !finished { _ = persist() } }
            .onAppear {
                visible = true
                voice.didRecord = { data in
                    guard currentScope, !finished else { return }
                    audio = data; audioDirty = true; _ = persist()
                }
                if !started {
                    started = true
                    if startsRecording, audio == nil, !draft.serverSaved, !draft.sealAttempted { record() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background || (phase == .inactive && !voice.requestingPermission) {
                    voice.suspend(); _ = persist()
                }
            }
            .onDisappear {
                visible = false; recordTask?.cancel(); recordTask = nil
                voice.stopAll()
                if !finished { _ = persist() }
                voice.didRecord = nil
                sendTask?.cancel(); sendTask = nil
            }
            .onChange(of: services.privateImageKey("chat-audio-composition")) { _, value in
                if value != scope {
                    recordTask?.cancel(); recordTask = nil
                    voice.didRecord = nil; voice.stopAll()
                    sendTask?.cancel(); sendTask = nil
                }
            }
        }
    }

    private var openingControl: some View {
        MessageOpeningControl(opensAt: $draft.opensAt)
            .disabled(busy || draft.sealAttempted || voice.recording || voice.requestingPermission)
    }

    private var sendButton: some View {
        Button {
            if draft.sealAttempted || draft.opensAt == nil { send() }
            else { confirmSchedule = true }
        } label: {
            Group {
                if busy { ProgressView() }
                else { Label(draft.sealAttempted ? "Confirmar envío" : "Enviar audio", systemImage: "paperplane.fill") }
            }.frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.borderedProminent).disabled(!canSend)
            .accessibilityIdentifier("chat.audio.send")
    }

    @ViewBuilder private var audioControls: some View {
        if voice.recording {
            VoiceRecordingMeter(controller: voice)
        } else {
            if let audio {
                VoicePlaybackControls(player: voice, data: audio, title: "", displaysNotice: false)
            }
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) :
                AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button(audio == nil ? "Grabar" : "Grabar otra vez", systemImage: "mic.fill") { record() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .disabled(voice.requestingPermission).accessibilityIdentifier("chat.audio.record")
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if audio != nil || draft.serverSaved {
                    Button("Eliminar", systemImage: "trash", role: .destructive) { confirmDiscard = true }
                        .frame(minHeight: 44).disabled(voice.requestingPermission)
                }
            }
            if voice.requestingPermission { ProgressView("Esperando permiso del micrófono…") }
            else if audio == nil { Text("Hasta 1 minuto").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func record() {
        guard currentScope, !busy, !draft.sealAttempted, recordTask == nil,
              !voice.recording, !voice.requestingPermission else { return }
        recordTask = Task { @MainActor in
            defer { recordTask = nil }
            guard visible, currentScope, scenePhase == .active, !Task.isCancelled else { return }
            await voice.record()
        }
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
        finished = true; voice.didRecord = nil; voice.stopAll(); storage.clear()
        onSent(letter)
    }

    private func send() {
        guard canSend else { return }
        voice.stopAll()
        guard persist() else { return }
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
        voice.stopAll(); error = nil
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
        storage.clear(); audio = nil; audioDirty = false; draft = AudioMessageDraft()
        _ = persist()
    }
}
