import SwiftUI
import PairNotesCore

struct MessagesView: View {
    @ObservedObject var services: AppServices
    @Environment(\.coupleModalControl) private var modalControl
    @State private var messages: [CoupleMessage] = []
    @State private var nextCursor: [String: Any]?
    @State private var busy = false
    @State private var error: String?
    @State private var composing = false
    @State private var requestSequence = 0
    @State private var loadedScope: String?
    @State private var failedLoadWasAppend = false
    @State private var modalOwner = UUID()
    private var scope: String { "\(services.identity?.uid ?? "")|\(services.membership?.id ?? "")|\(services.membership?.pairEpoch ?? 0)" }
    private var theme: CoupleTheme { services.personalization.theme }
    private var visibleMessages: [CoupleMessage] { loadedScope == scope ? messages : [] }
    private var messageDays: [MessageDay] {
        Dictionary(grouping: visibleMessages) { Calendar.current.startOfDay(for: $0.sentAt) }
            .map { MessageDay(date: $0.key, messages: $0.value) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            if services.membership == nil {
                ContentUnavailableView("Mensajes", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Vinculá a tu pareja para escribirse."))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if visibleMessages.isEmpty, !busy, error == nil {
                ContentUnavailableView {
                    Label("Todavía no hay mensajes", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("Escribir un mensaje", systemImage: "square.and.pencil", action: openComposer)
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(messageDays) { day in
                Section {
                    ForEach(day.messages) { message in
                        messageRow(message)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } header: {
                    Text(dayTitle(day.date)).font(.caption).textCase(nil)
                }
            }
            if busy {
                HStack { Spacer(); ProgressView("Cargando…"); Spacer() }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if loadedScope == scope, nextCursor != nil {
                Button("Mensajes anteriores") { Task { await load(append: true) } }
                    .frame(maxWidth: .infinity)
                    .disabled(busy)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if let error {
                VStack(spacing: 12) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Reintentar") { Task { await load(append: failedLoadWasAppend) } }
                        .disabled(busy)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .navigationTitle("Mensajes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Escribir", systemImage: "square.and.pencil", action: openComposer)
                    .disabled(services.membership == nil)
                    .accessibilityIdentifier("messages.compose")
            }
        }
        .tint(theme.accent)
        .sheet(isPresented: $composing, onDismiss: {
            modalControl.onDismissed(modalOwner)
            Task { await load(append: false) }
        }) { MessageComposer(services: services) }
        .task(id: scope) {
            requestSequence += 1; busy = false; error = nil; messages = []; nextCursor = nil; loadedScope = nil
            await load(append: false)
        }
        .refreshable { await load(append: false) }
        .onChange(of: composing) { _, presented in
            if presented { modalControl.onPresented(modalOwner) }
        }
        .onChange(of: modalControl.dismissalVersion) { _, _ in composing = false }
        .onChange(of: scope) { _, _ in composing = false }
    }

    private func openComposer() {
        guard !composing, services.identity != nil, services.membershipResolved,
              services.membership != nil else { return }
        modalControl.onPresented(modalOwner)
        composing = true
    }

    private func messageRow(_ message: CoupleMessage) -> some View {
        let isOwn = message.authorID == services.identity?.uid
        let author = isOwn ? "Vos" : services.partnerNickname
        return HStack(alignment: .bottom, spacing: 0) {
            if isOwn { Spacer(minLength: 36) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 5) {
                Text(message.text)
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(isOwn ? theme.accent.opacity(0.18) : theme.card,
                                in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("\(author): \(message.text)")
                Text(message.sentAt, format: .dateTime.hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 540, alignment: isOwn ? .trailing : .leading)
            if !isOwn { Spacer(minLength: 36) }
        }
        .privacySensitive()
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Hoy" }
        if Calendar.current.isDateInYesterday(date) { return "Ayer" }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    private struct MessageDay: Identifiable {
        let date: Date
        let messages: [CoupleMessage]
        var id: Date { date }
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
            loadedScope = captured
            nextCursor = response["nextCursor"] as? [String: Any]
        } catch {
            if captured == scope, request == requestSequence {
                failedLoadWasAppend = append
                self.error = "No se pudieron cargar los mensajes."
            }
        }
    }
}
