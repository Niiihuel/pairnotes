import PairNotesCore
import SwiftUI

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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Te estoy pensando").font(.title3.bold())
                    Text("Un toque, un poquito más cerca.").font(.caption).foregroundStyle(.secondary)
                }
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
                if gesture.recipientId == services.identity?.uid {
                    Text("Respondé con otro detalle ↓").font(.caption).foregroundStyle(services.personalization.theme.accent)
                }
            }
            HStack(spacing: 12) {
                ForEach(AffectionKind.allCases, id: \.self) { kind in
                    Button { send(kind) } label: {
                        VStack(spacing: 6) { Text(kind.symbol).font(.title); Text(kind.title).font(.caption) }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.bordered).disabled(sending)
                }
            }
            if sending { ProgressView("Enviando ese cariño…").font(.caption) }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                if let pending { Button("Reintentar el mismo envío") { send(pending.kind, retry: true) }.disabled(sending) }
            }
        }
        .padding(20).background(services.personalization.theme.card, in: RoundedRectangle(cornerRadius: 24))
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: feedback)
        .task(id: storage.key) {
            pending = storage.loadValue()
            error = pending == nil ? nil : "Tenés un detalle cuyo envío no se confirmó."
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
            } catch { if storage.key == scope { self.error = "No se confirmó el envío. Podés reintentar sin duplicarlo." } }
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
                    VStack(alignment: .leading, spacing: 5) {
                        if !reaction.symbol.isEmpty { Text(reaction.symbol).font(.title2) }
                        if !reaction.reply.isEmpty { Text(reaction.reply).privacySensitive() }
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
