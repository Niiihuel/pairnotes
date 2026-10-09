import PairNotesCore
import SwiftUI

enum AffectionDestination: Hashable {
    case drawings
    case letters(String?)
    case voices
    case messages
    case photos
}

/// Collection composers dismiss before a notification or widget opens another
/// modal. Default callbacks keep isolated previews independent of RootView.
struct CoupleModalControl: Sendable {
    var dismissalVersion: UInt64 = 0
    var onPresented: @MainActor @Sendable (UUID) -> Void = { _ in }
    var onDismissed: @MainActor @Sendable (UUID) -> Void = { _ in }
}

private struct CoupleModalControlKey: EnvironmentKey {
    static let defaultValue = CoupleModalControl()
}

extension EnvironmentValues {
    var coupleModalControl: CoupleModalControl {
        get { self[CoupleModalControlKey.self] }
        set { self[CoupleModalControlKey.self] = newValue }
    }
}

struct AffectionHubView: View {
    @ObservedObject var services: AppServices
    let connect: () -> Void

    var body: some View {
        List {
            if services.membership != nil {
                Section {
                    destination("Cartas", symbol: "envelope", route: .letters(nil))
                    destination("Audios", symbol: "waveform", route: .voices)
                    destination("Mensajes", symbol: "bubble.left.and.text.bubble.right", route: .messages)
                    destination("Fotos", symbol: "photo", route: .photos)
                }
            } else if services.identity != nil, !services.membershipResolved {
                ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Buscando tu pareja")
            } else {
                ContentUnavailableView {
                    Label("Para los dos", systemImage: "person.2")
                } description: {
                    Text("Vinculá sus cuentas para compartir.")
                } actions: {
                    Button("Vincular", action: connect).buttonStyle(.borderedProminent)
                }.listRowBackground(Color.clear)
            }
        }
        .coupleScreenBackground()
        .navigationTitle("Para vos")
    }

    private func destination(_ title: String, symbol: String, route: AffectionDestination) -> some View {
        NavigationLink(value: route) {
            Label {
                Text(title).font(.headline).foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol).font(.title3)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(services.personalization.theme.accent)
                    .background(services.personalization.theme.paper, in: RoundedRectangle(cornerRadius: 12))
            }.padding(.vertical, 6)
        }.accessibilityIdentifier("affection." + title.lowercased())
    }
}

struct CouplePhotosView: View {
    @ObservedObject var services: AppServices
    let createPhoto: () -> Void
    let openPhoto: (String) -> Void
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let photo = services.coupleSpace?.latestPhoto {
                    Text("Última recibida").font(.subheadline).foregroundStyle(.secondary)
                    Button { openPhoto(photo.id) } label: {
                        CouplePhotoCard(services: services, photo: photo)
                    }.buttonStyle(.plain)
                } else {
                    ContentUnavailableView("Sin fotos recibidas", systemImage: "photo")
                    Button("Enviar foto", systemImage: "camera", action: createPhoto)
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .coupleScreenBackground()
        .navigationTitle("Fotos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Enviar foto", systemImage: "camera", action: createPhoto)
            }
        }
        .refreshable {
            let scope = services.privateImageKey("photos")
            do { try await services.refreshCoupleSpace(); if scope == services.privateImageKey("photos") { error = nil } }
            catch { if scope == services.privateImageKey("photos") { self.error = "No se pudieron actualizar las fotos." } }
        }
        .onChange(of: services.privateImageKey("photos")) { _, _ in error = nil }
    }
}

struct ThinkingOfYouCard: View {
    @ObservedObject var services: AppServices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sending = false
    @State private var feedback = 0
    @State private var error: String?
    @State private var pending: Pending?
    private struct Pending: Codable { let id: UUID; let kind: AffectionKind; let replyTo: String? }
    private var storage: MemoryCompositionStorage { MemoryCompositionStorage(key: services.privateImageKey("pending-gesture")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Te pienso").font(.title3.bold())
                Spacer()
                Text(services.coupleSpace?.latestGesture?.kind.symbol ?? "♡")
                    .font(.largeTitle).id(feedback).transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
            if let gesture = services.coupleSpace?.latestGesture {
                HStack(spacing: 10) {
                    ProfileAvatarView(services: services, uid: gesture.authorId,
                        name: gesture.authorId == services.identity?.uid ? "Vos" : services.partnerNickname,
                        reference: services.coupleSpace?.profiles.first(where: { $0.uid == gesture.authorId })?.avatar, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(gesture.authorId == services.identity?.uid ? "Le mandaste \(gesture.kind.title.lowercased())" : "\(services.partnerNickname) te mandó \(gesture.kind.title.lowercased())")
                            .font(.subheadline)
                        Text(gesture.sentAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(AffectionKind.allCases, id: \.self) { kind in
                    Button { send(kind) } label: {
                        Text(kind.symbol).font(.title).frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered).disabled(sending)
                        .accessibilityLabel("Enviar " + kind.title.lowercased())
                }
            }
            if sending { ProgressView().accessibilityLabel("Enviando") }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                if let pending { Button("Reintentar") { send(pending.kind, retry: true) }.disabled(sending) }
            }
        }
        .padding(20).background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 24))
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: feedback)
        .task(id: storage.key) {
            pending = storage.loadValue()
            error = pending == nil ? nil : "Envío sin confirmar."
        }
    }
    private func send(_ kind: AffectionKind, retry: Bool = false) {
        guard !sending else { return }
        let saved = storage, scope = storage.key
        let latest = services.coupleSpace?.latestGesture
        let operation = retry ? pending : Pending(id: UUID(), kind: kind,
            replyTo: latest?.recipientId == services.identity?.uid ? latest?.id : nil)
        guard let operation else { return }
        do { try saved.saveValue(operation) } catch { self.error = "No se pudo preparar el envío. Reintentá."; return }
        pending = operation; sending = true; error = nil
        Task { @MainActor in
            defer { sending = false }
            do {
                try await services.sendGesture(id: operation.id, kind: operation.kind, replyTo: operation.replyTo)
                saved.clear()
                guard storage.key == scope else { return }
                pending = nil
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { feedback += 1 }
            } catch { if storage.key == scope { self.error = "No se pudo confirmar el envío." } }
        }
    }
}

struct NoteReactionsView: View {
    @ObservedObject var services: AppServices
    let note: RemoteNote
    @Environment(\.scenePhase) private var scenePhase
    @State private var reactions: [DrawingReaction] = []
    @State private var reply = ""
    @State private var kind = ""
    @State private var busy = false
    @State private var error: String?
    @State private var feedback = 0
    @State private var initialized = false
    private struct Draft: Codable { let kind: String; let reply: String }
    private var storage: MemoryCompositionStorage { MemoryCompositionStorage(key: services.privateImageKey("reaction:" + note.id)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lo que nos hizo sentir").font(.headline)
            ForEach(reactions) { reaction in
                HStack(alignment: .top, spacing: 10) {
                    ProfileAvatarView(services: services, uid: reaction.authorId,
                        name: reaction.authorId == services.identity?.uid ? "Vos" : services.partnerNickname,
                        reference: services.coupleSpace?.profiles.first(where: { $0.uid == reaction.authorId })?.avatar, size: 32)
                    ReactionBubble(tail: .topLeading, surface: .solid(services.personalization.theme.card)) {
                        VStack(alignment: .leading, spacing: 5) {
                            if !reaction.symbol.isEmpty { Text(reaction.symbol).font(.title2) }
                            if !reaction.reply.isEmpty { Text(reaction.reply).privacySensitive() }
                        }.padding(6)
                    }
                }
            }
            if note.recipientID == services.identity?.uid {
                Picker("Reacción", selection: $kind) {
                    Text("Sin reacción").tag("")
                    Text("❤️").tag("heart"); Text("🫂").tag("hug"); Text("✨").tag("sparkles")
                }.pickerStyle(.segmented).disabled(!initialized)
                TextField("Una respuesta pequeña…", text: $reply, axis: .vertical).lineLimit(2...4).disabled(!initialized)
                HStack {
                    Text("\(reply.utf16.count)/280").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Guardar respuesta") { save() }.disabled(busy || !initialized || reply.utf16.count > 280)
                }
            } else if reactions.isEmpty { Text("Acá aparecerá su reacción a tu dibujo.").font(.subheadline).foregroundStyle(.secondary) }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            if busy { ProgressView() }
        }.padding(18).background(services.personalization.theme.paper, in: RoundedRectangle(cornerRadius: 22))
        .sensoryFeedback(.success, trigger: feedback)
        .onChange(of: reply) { _, _ in persist() }
        .onChange(of: kind) { _, _ in persist() }
        .task(id: storage.key) {
            reactions = []; initialized = false
            repeat {
                if scenePhase == .active {
                    do {
                        let values = try await services.reactions(noteID: note.id)
                        guard !Task.isCancelled else { return }
                        reactions = values
                        if !initialized {
                            let draft: Draft? = storage.loadValue()
                            let own = values.first { $0.authorId == services.identity?.uid }
                            reply = draft?.reply ?? own?.reply ?? ""; kind = draft?.kind ?? own?.kind ?? ""
                            initialized = true
                        }
                    } catch { if !Task.isCancelled { self.error = "No se pudieron actualizar las reacciones." } }
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func persist() {
        guard initialized, note.recipientID == services.identity?.uid else { return }
        do { try storage.saveValue(Draft(kind: kind, reply: reply)) }
        catch { self.error = "No se pudo guardar el borrador de tu respuesta." }
    }
    private func save() {
        guard !busy else { return }
        let stored = storage, scope = storage.key, sentReply = reply, sentKind = kind
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let values = try await services.setReaction(noteID: note.id, kind: sentKind, reply: sentReply)
                guard storage.key == scope else { return }
                reactions = values; feedback += 1
                if reply == sentReply && kind == sentKind { stored.clear() }
            } catch { if storage.key == scope { self.error = "No se pudo guardar la respuesta. Tu texto sigue acá." } }
        }
    }
}
