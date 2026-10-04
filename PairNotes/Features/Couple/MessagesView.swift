import SwiftUI
import PairNotesCore

struct MessagesView: View {
    @ObservedObject var services: AppServices
    @State private var messages: [CoupleMessage] = []
    @State private var nextCursor: [String: Any]?
    @State private var busy = false
    @State private var error: String?
    @State private var composing = false
    @State private var requestSequence = 0
    private var scope: String { "\(services.identity?.uid ?? "")|\(services.membership?.id ?? "")|\(services.membership?.pairEpoch ?? 0)" }
    var body: some View {
        List {
            if messages.isEmpty, !busy {
                ContentUnavailableView("Palabras para guardar", systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Sus mensajes van a aparecer acá. El último recibido se puede ver en el widget."))
            }
            ForEach(messages, id: \.id) { message in
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.authorID == services.identity?.uid ? "Vos" : services.membership?.partner.displayName ?? "Tu pareja")
                        .font(.caption.weight(.semibold)).foregroundStyle(.pink)
                    Text(message.text).privacySensitive().textSelection(.enabled)
                    Text(message.sentAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            if busy { ProgressView("Cargando mensajes…") }
            if nextCursor != nil { Button("Mensajes anteriores") { Task { await load(append: true) } }.disabled(busy) }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Mensajes")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Escribir", systemImage: "square.and.pencil") { composing = true } } }
        .sheet(isPresented: $composing, onDismiss: { Task { await load(append: false) } }) { MessageComposer(services: services) }
        .task(id: scope) { requestSequence += 1; busy = false; error = nil; messages = []; nextCursor = nil; await load(append: false) }
        .refreshable { await load(append: false) }
        .onChange(of: scope) { _, _ in composing = false }
    }
    private func load(append: Bool) async {
        if append && busy { return }
        guard let pair = services.membership, let uid = services.identity?.uid else { return }
        let captured = scope
        requestSequence += 1
        let request = requestSequence
        busy = true; error = nil
        defer { if captured == scope, request == requestSequence { busy = false } }
        do {
            var payload: [String: Any] = ["pairId": pair.id, "pairEpoch": pair.pairEpoch, "limit": 30]
            if append, let nextCursor { payload["cursor"] = nextCursor }
            let response = try await services.call("messages", payload)
            try services.checkSpaceContext(uid: uid, pair: pair)
            guard captured == scope, request == requestSequence, let values = response["messages"] as? [[String: Any]] else { return }
            let fetched: [CoupleMessage] = try values.map { try services.decodeSpace($0) }
            let combined = append ? messages + fetched : fetched
            var seen = Set<String>()
            messages = combined.filter { seen.insert($0.id).inserted }
            nextCursor = response["nextCursor"] as? [String: Any]
        } catch { if captured == scope, request == requestSequence { self.error = "No se pudieron cargar los mensajes. Deslizá para reintentar." } }
    }
}
