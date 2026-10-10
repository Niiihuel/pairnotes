import PairNotesCore
import SwiftUI
import UIKit

struct ChatMessageComposer<AudioContent: View>: View {
    @ObservedObject var services: AppServices
    let createPhoto: () -> Void
    let takePhoto: () -> Void
    let createDrawing: () -> Void
    let showDrafts: () -> Void
    let createLetter: () -> Void
    let recordAudio: () -> Void
    @ObservedObject var audioInteraction: ChatAudioInteraction
    @ViewBuilder let audioContent: () -> AudioContent
    let keyboardDismissalRequest: UInt64
    let onSent: (CoupleConversationItem) -> Void
    private let storage: MemoryCompositionStorage
    @State private var draft: Draft
    @State private var sending = false
    @State private var error: String?
    @State private var feedback = 0
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool

    private struct Draft: Codable {
        var text: String
        var id: UUID
        var submittedText: String?
        var opensAt: Date?
        var sealAttempted: Bool?
    }

    init(services: AppServices, createPhoto: @escaping () -> Void, takePhoto: @escaping () -> Void,
         createDrawing: @escaping () -> Void, showDrafts: @escaping () -> Void,
         createLetter: @escaping () -> Void, recordAudio: @escaping () -> Void,
         audioInteraction: ChatAudioInteraction, keyboardDismissalRequest: UInt64 = 0,
         onSent: @escaping (CoupleConversationItem) -> Void,
         @ViewBuilder audioContent: @escaping () -> AudioContent) {
        self.services = services; self.createPhoto = createPhoto; self.takePhoto = takePhoto
        self.createDrawing = createDrawing; self.showDrafts = showDrafts
        self.createLetter = createLetter; self.recordAudio = recordAudio; self.onSent = onSent
        self.keyboardDismissalRequest = keyboardDismissalRequest
        self.audioInteraction = audioInteraction; self.audioContent = audioContent
        let storage = MemoryCompositionStorage(key: services.privateImageKey("message-draft"))
        self.storage = storage
        var recovered: Draft = storage.loadValue() ?? Draft(text: "", id: UUID())
        if let submitted = recovered.submittedText,
           submitted != recovered.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            recovered.id = UUID(); recovered.submittedText = nil; recovered.sealAttempted = false
        }
        _draft = State(initialValue: recovered)
    }

    private var clean: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        !sending && !clean.isEmpty && draft.text.utf16.count <= 500 &&
        (draft.submittedText != nil || draft.opensAt.map { $0 > Date() } ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let error, !audioInteraction.isPresented {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.send-error")
            }
            if let date = draft.opensAt, !audioInteraction.isPresented {
                HStack {
                    Label("Se abre \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                if audioInteraction.isPresented {
                    audioContent().frame(maxWidth: .infinity)
                } else {
                Menu {
                    Button("Foto de la fototeca", systemImage: "photo", action: createPhoto)
                    Button("Sacar foto", systemImage: "camera", action: takePhoto)
                    Button("Audio", systemImage: "mic") { focused = false; recordAudio(); audioInteraction.open(startRecording: true) }
                    Button("Dibujo", systemImage: "pencil.tip.crop.circle", action: createDrawing)
                    Button("Carta", systemImage: "envelope", action: createLetter)
                    Button("Mis borradores", systemImage: "square.stack", action: showDrafts)
                } label: {
                    Image(systemName: "plus").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel("Adjuntar").accessibilityIdentifier("chat.attach")
                    .disabled(sending)
                TextField("Mensaje", text: $draft.text, axis: .vertical)
                    .lineLimit(1...5).focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 22))
                    .disabled(sending || draft.submittedText != nil)
                    .accessibilityIdentifier("chat.message")
                if clean.isEmpty {
                    Button("Cámara", systemImage: "camera", action: takePhoto)
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                        .accessibilityIdentifier("chat.camera")
                } else {
                    MessageOpeningControl(opensAt: $draft.opensAt, compact: true, onPresent: { focused = false })
                        .disabled(sending || draft.submittedText != nil)
                }
                }
                // Keep this UIKit control mounted for the entire press/drag,
                // even while the rest of the composer changes into the recorder.
                if clean.isEmpty || audioInteraction.isPresented {
                    ChatAudioRecordButton(interaction: audioInteraction,
                        tint: UIColor(services.personalization.theme.accent),
                        onBegin: { focused = false; recordAudio() })
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .bottom) {
                            if audioInteraction.phase == .holding {
                                VStack(spacing: 10) {
                                    Image(systemName: "lock.fill")
                                    Image(systemName: "chevron.up")
                                }.font(.subheadline).frame(width: 40, height: 76)
                                    .background(services.personalization.theme.card, in: Capsule())
                                    .offset(y: -58).allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                } else {
                    Button(action: send) {
                        Group {
                            if sending { ProgressView() }
                            else { Image(systemName: "arrow.up").font(.title3.weight(.semibold)) }
                        }.frame(width: 44, height: 44)
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .background(services.personalization.theme.accent, in: Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(draft.submittedText == nil ? "Enviar mensaje" : "Reintentar envío")
                    .accessibilityIdentifier("chat.send")
                }
            }
            if draft.text.utf16.count > 450, !audioInteraction.isPresented {
                Text("\(draft.text.utf16.count)/500").font(.caption2)
                    .foregroundStyle(draft.text.utf16.count > 500 ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(services.personalization.theme.canvas)
        .sensoryFeedback(.success, trigger: feedback)
        .onChange(of: keyboardDismissalRequest) { _, _ in focused = false }
        .onChange(of: draft.text) { _, _ in persist() }
        .onChange(of: draft.opensAt) { _, _ in persist() }
        .onDisappear { focused = false; persist() }
    }

    @discardableResult private func persist() -> Bool {
        guard storage.key == services.privateImageKey("message-draft") else { return false }
        do { try storage.saveValue(draft); return true }
        catch { self.error = "No se pudo guardar el mensaje en este iPhone."; return false }
    }

    private func send() {
        guard canSend, services.membershipResolved, services.membership != nil,
              storage.key == services.privateImageKey("message-draft") else { return }
        if draft.submittedText == nil { draft.submittedText = clean }
        guard persist(), let text = draft.submittedText else { return }
        let id = draft.id, date = draft.opensAt, scope = storage.key
        sending = true; error = nil
        Task { @MainActor in
            defer { sending = false }
            guard scope == services.privateImageKey("message-draft") else { return }
            do {
                let confirmed: CoupleConversationItem
                if let date {
                    if draft.sealAttempted != true {
                        _ = try await services.saveLetterDraft(id: id.uuidString.lowercased(), title: "Mensaje",
                            body: text, opensAt: date, noteID: nil)
                        guard storage.key == services.privateImageKey("message-draft") else { return }
                        draft.sealAttempted = true
                        guard persist() else { return }
                    }
                    confirmed = .letter(try await services.sealLetter(id: id.uuidString.lowercased()))
                } else {
                    confirmed = .message(try await services.sendMessage(id: id, text: text))
                }
                guard scope == services.privateImageKey("message-draft") else { return }
                storage.clear(); draft = Draft(text: "", id: UUID()); feedback += 1
                onSent(confirmed)
            } catch {
                guard scope == services.privateImageKey("message-draft") else { return }
                if let api = error as? APIError, api.code == "opening_date_passed" {
                    draft.submittedText = nil; draft.sealAttempted = false
                    self.error = "La fecha pasó. Elegí otra o enviá ahora."
                    persist()
                } else { self.error = "Envío sin confirmar. Tocá enviar para reintentar." }
            }
        }
    }
}
