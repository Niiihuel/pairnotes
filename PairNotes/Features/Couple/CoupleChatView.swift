import PairNotesCore
import SwiftUI

struct CoupleChatView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var model: AppModel
    @Binding var request: AffectionDestination?
    @Binding var incomingPhoto: CouplePhoto?
    let refreshVersion: UInt64
    let connect: () -> Void
    let createPhoto: () -> Void
    let takePhoto: () -> Void
    let createDrawing: () -> Void
    let openNote: (RemoteNote) -> Void
    let openPhoto: (String) -> Void
    let showDrafts: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.coupleModalControl) private var modalControl
    @StateObject private var history = CoupleChatHistory()
    @StateObject private var reactions = ChatReactionStore()
    @State private var composingLetter = false
    @State private var recordingAudio = false
    @State private var startAudioRecording = false
    @State private var selectedLetter: TimeCapsuleLetter?
    @State private var modalOwner = UUID()
    @State private var audioOwner = UUID()
    @State private var atBottom = true
    @State private var scrollRequest = UUID()
    @State private var keyboardDismissalRequest: UInt64 = 0
    @State private var routeError: String?

    private var scope: String { services.privateImageKey("conversation") }
    private var linked: Bool { services.membershipResolved && services.membership != nil }
    private var reactionsAreCurrent: Bool { reactions.loadedScope == scope }
    private var items: [CoupleConversationItem] {
        guard linked, history.loadedScope == scope, let pair = services.membership else { return [] }
        var photos = history.photos
        if let latest = services.coupleSpace?.latestPhoto {
            if let index = photos.firstIndex(where: { $0.id == latest.id }) {
                if (latest.reaction?.updatedAt ?? .distantPast) > (photos[index].reaction?.updatedAt ?? .distantPast) {
                    photos[index] = latest
                }
            } else { photos.append(latest) }
        }
        let drawings = model.notes.filter { $0.pairID == pair.id && $0.pairEpoch == pair.pairEpoch }
        return CoupleConversation.items(messages: history.messages, photos: photos,
                                        drawings: drawings, letters: history.letters)
    }
    private var days: [ChatDay] {
        Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
            .map { ChatDay(date: $0.key, items: $0.value) }.sorted { $0.date < $1.date }
    }
    private var hasOlder: Bool {
        history.hasOlderMessages || history.hasOlderPhotos || history.hasOlderLetters || model.nextCursor != nil
    }

    var body: some View {
        ChatConversationScrollView(atBottom: $atBottom, newestItemID: items.last?.id,
                                   scrollRequest: scrollRequest, hasMessages: !items.isEmpty,
                                   dismissKeyboard: dismissKeyboard) {
                LazyVStack(spacing: 12) {
                    if !linked {
                        ContentUnavailableView {
                            Label("Su conversación", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Vinculá sus cuentas para compartir.")
                        } actions: {
                            if services.identity != nil, !services.membershipResolved { ProgressView() }
                            else { Button("Vincular", action: connect).buttonStyle(.borderedProminent) }
                        }.padding(.top, 36)
                    } else {
                        if hasOlder {
                            Button("Mensajes anteriores") {
                                Task { await history.refresh(services: services, older: true); await model.loadMore() }
                            }.font(.subheadline).frame(minHeight: 44)
                                .disabled(history.loading || model.isLoading || model.isLoadingMore)
                        }
                        if items.isEmpty, !history.loading, history.error == nil {
                            ContentUnavailableView("El comienzo de algo lindo", systemImage: "bubble.left.and.bubble.right")
                                .padding(.top, 36)
                        }
                        ForEach(days) { day in
                            Text(dayTitle(day.date)).font(.caption.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(services.personalization.theme.card, in: Capsule())
                                .accessibilityAddTraits(.isHeader)
                            ForEach(day.items) { item in
                                conversationRow(item).id(item.id)
                            }
                        }
                        if history.loading { ProgressView().accessibilityLabel("Cargando conversación") }
                        if let error = routeError ?? history.error {
                            VStack(spacing: 4) {
                                Text(error).font(.footnote).foregroundStyle(.secondary)
                                Button("Reintentar") { Task { await refresh(); await handle(request) } }
                                    .frame(minHeight: 44).disabled(history.loading)
                            }
                        }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .id(scope)
        .coupleScreenBackground()
        .navigationTitle(linked ? services.partnerNickname : "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Dibujos", systemImage: "pencil.tip.crop.circle", action: showDrafts)
                    .accessibilityIdentifier("chat.drawings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if linked {
                VStack(spacing: 0) {
                    Divider()
                    if recordingAudio {
                        AudioMessageComposer(services: services,
                                             onSent: { sent(.letter($0)); recordingAudio = false },
                                             onCancel: { recordingAudio = false }, startsRecording: startAudioRecording)
                            .id(scope).padding(.horizontal, 12).padding(.vertical, 8)
                    } else {
                        ChatMessageComposer(services: services, createPhoto: createPhoto, takePhoto: takePhoto,
                            createDrawing: createDrawing, showDrafts: showDrafts,
                            createLetter: presentLetterComposer, recordAudio: beginAudioRecording,
                            keyboardDismissalRequest: keyboardDismissalRequest, onSent: sent)
                            .id(scope)
                    }
                }.background(services.personalization.theme.canvas)
            }
        }
        .chatReactionOverlay()
        .sheet(isPresented: $composingLetter, onDismiss: sheetDismissed) {
            LetterComposer(services: services, notes: model.notes, catalog: model.catalog)
        }
        .sheet(item: $selectedLetter, onDismiss: sheetDismissed) { letter in
            LetterDetailView(services: services, original: letter)
        }
        .task(id: scope) {
            history.reset(); reactions.reset(); routeError = nil; recordingAudio = false
            await refresh(); await handle(request)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if scenePhase == .active {
                    await history.refresh(services: services)
                    await refreshReactions()
                }
            }
        }
        .task(id: items.map(\.reactionTarget)) { await refreshReactions() }
        .refreshable { await refresh() }
        .onChange(of: request) { _, value in Task { await handle(value) } }
        .onChange(of: refreshVersion) { _, _ in
            if scenePhase == .active {
                Task { await history.refresh(services: services); await refreshReactions() }
            }
        }
        .onChange(of: incomingPhoto) { _, photo in
            guard linked, let photo, let pair = services.membership,
                  (try? photo.validate(memberIDs: pair.memberIDs)) != nil else { return }
            sent(.photo(photo))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await history.refresh(services: services); await refreshReactions() }
            }
        }
        .onChange(of: modalControl.dismissalVersion) { _, _ in
            composingLetter = false; selectedLetter = nil; recordingAudio = false
        }
        .onChange(of: recordingAudio) { _, active in
            if active { modalControl.onPresented(audioOwner) }
            else { modalControl.onDismissed(audioOwner) }
        }
        .onDisappear {
            if recordingAudio { recordingAudio = false; modalControl.onDismissed(audioOwner) }
        }
        .onChange(of: scope) { _, _ in
            dismissKeyboard(); atBottom = true
            composingLetter = false; selectedLetter = nil; recordingAudio = false
            history.reset(); reactions.reset()
        }
    }

    @ViewBuilder private func conversationRow(_ item: CoupleConversationItem) -> some View {
        let own = item.authorID == services.identity?.uid
        HStack(alignment: .bottom, spacing: 0) {
            if own { Spacer(minLength: 36) }
            VStack(alignment: own ? .trailing : .leading, spacing: 4) {
                ChatReactionInteraction(id: item.id, own: own, canReact: canReact(to: item),
                    selectedKind: reactionsAreCurrent ? reactions.myReaction(for: item.reactionTarget)?.kind : nil,
                    isReacting: reactionsAreCurrent && reactions.isReacting(item.reactionTarget),
                    confirmationRevision: reactionsAreCurrent ? reactions.confirmationRevision(item.reactionTarget) : 0,
                    errorMessage: reactionsAreCurrent ? reactions.error(for: item.reactionTarget) : nil,
                    copyText: copyText(for: item),
                    onReact: { kind in react(kind, to: item) },
                    onPresent: dismissKeyboard, onOpen: detailAction(for: item)) {
                    VStack(alignment: own ? .trailing : .leading, spacing: 4) {
                        conversationContent(item, own: own)
                        reactionSummary(for: item)
                    }
                }
                Text(item.date, format: .dateTime.hour().minute())
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6)
            }.frame(maxWidth: 420, alignment: own ? .trailing : .leading)
            if !own { Spacer(minLength: 36) }
        }.privacySensitive()
    }

    private func messageBubble(_ text: String, own: Bool) -> some View {
        Text(text).foregroundStyle(services.personalization.theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(own ? services.personalization.theme.accent.opacity(0.18) : services.personalization.theme.card,
                        in: RoundedRectangle(cornerRadius: 20))
            .accessibilityLabel("\(own ? "Vos" : services.partnerNickname): \(text)")
    }

    @ViewBuilder private func conversationContent(_ item: CoupleConversationItem, own: Bool) -> some View {
        switch item {
        case .message(let message): messageBubble(message.text, own: own)
        case .photo(let photo): ChatPhotoCard(services: services, photo: photo)
        case .drawing(let note): ChatDrawingCard(services: services, note: note)
        case .letter(let letter):
            if isInlineMessage(letter), let text = letter.body { messageBubble(text, own: own) }
            else { ChatLetterCard(services: services, letter: letter) }
            if own, !letter.canOpen {
                Label("Se abre \(letter.opensAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func reactionSummary(for item: CoupleConversationItem) -> some View {
        let values = reactionsAreCurrent ? reactions.reactions(for: item.reactionTarget) : []
        if !values.isEmpty {
            ReactionBubble(tail: .topLeading, surface: .solid(services.personalization.theme.card)) {
                HStack(spacing: 8) {
                    ForEach(ChatReactionKind.allCases, id: \.self) { kind in
                        let matches = values.filter { $0.kind == kind }
                        if !matches.isEmpty {
                            HStack(spacing: 3) {
                                Text(kind.symbol).font(.body)
                                if matches.count > 1 { Text("\(matches.count)").font(.caption) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(matches.map {
                                "\($0.authorID == services.identity?.uid ? "Vos" : services.partnerNickname): \(kind.accessibilityLabel)"
                            }.joined(separator: ", "))
                        }
                    }
                }.padding(.horizontal, 4)
            }
        }
    }

    private func isInlineMessage(_ letter: TimeCapsuleLetter) -> Bool {
        letter.title == "Mensaje" && letter.body != nil &&
        (letter.authorId == services.identity?.uid || letter.canOpen) &&
        letter.audio == nil && letter.photo == nil && letter.drawing == nil && letter.noteId == nil
    }

    private func isInlineAudio(_ letter: TimeCapsuleLetter) -> Bool {
        (letter.authorId == services.identity?.uid || letter.canOpen) && letter.audio != nil &&
        letter.photo == nil && letter.drawing == nil && letter.noteId == nil &&
        (letter.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func canReact(to item: CoupleConversationItem) -> Bool {
        guard linked else { return false }
        if case .letter(let letter) = item {
            return letter.status == "sealed" && (letter.authorId == services.identity?.uid || letter.canOpen)
        }
        return true
    }

    private func copyText(for item: CoupleConversationItem) -> String? {
        switch item {
        case .message(let message): return message.text
        case .letter(let letter): return isInlineMessage(letter) ? letter.body : nil
        default: return nil
        }
    }

    private func detailAction(for item: CoupleConversationItem) -> (() -> Void)? {
        switch item {
        case .message: return nil
        case .photo(let photo): return { dismissKeyboard(); openPhoto(photo.id) }
        case .drawing(let note): return { dismissKeyboard(); openNote(note) }
        case .letter(let letter):
            guard letter.authorId == services.identity?.uid || letter.canOpen,
                  !isInlineMessage(letter), !isInlineAudio(letter) else { return nil }
            return { present(letter) }
        }
    }

    private func react(_ kind: ChatReactionKind?, to item: CoupleConversationItem) {
        guard canReact(to: item) else { return }
        dismissKeyboard()
        let captured = scope
        Task { await reactions.setReaction(kind, for: item.reactionTarget, services: services, expectedScope: captured) }
    }

    private func refreshReactions() async {
        guard linked else { return }
        await reactions.refresh(services: services, targets: items.map(\.reactionTarget))
    }

    private func dismissKeyboard() { keyboardDismissalRequest &+= 1 }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Hoy" }
        if Calendar.current.isDateInYesterday(date) { return "Ayer" }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
    private func refresh() async {
        guard linked else { return }
        await history.refresh(services: services)
        await model.refreshTimeline()
        await refreshReactions()
    }
    private func sent(_ item: CoupleConversationItem) {
        history.accept(item, scope: scope)
        scrollRequest = UUID()
        Task { await history.refresh(services: services); await refreshReactions() }
    }
    private func presentLetterComposer() {
        dismissKeyboard()
        modalControl.onPresented(modalOwner); composingLetter = true
    }
    private func beginAudioRecording() {
        dismissKeyboard()
        modalControl.onPresented(audioOwner)
        startAudioRecording = true; recordingAudio = true
    }
    private func present(_ letter: TimeCapsuleLetter) {
        dismissKeyboard()
        modalControl.onPresented(modalOwner); selectedLetter = letter
    }
    private func sheetDismissed() {
        modalControl.onDismissed(modalOwner)
        Task { await refresh() }
    }
    private func handle(_ destination: AffectionDestination?) async {
        guard linked, let destination else { return }
        if case .letters(let id) = destination, let id {
            let captured = scope
            do {
                let letter = try await services.openLetter(id: id)
                guard !Task.isCancelled, scope == captured, request == destination else { return }
                guard letter.status == "sealed" else {
                    routeError = "Esta carta no está disponible."; return
                }
                history.accept(.letter(letter), scope: scope)
                routeError = nil; present(letter)
            } catch {
                if scope == captured, request == destination {
                    routeError = "No se pudo cargar la carta."; return
                }
            }
        } else if destination == .voices {
            modalControl.onPresented(audioOwner)
            startAudioRecording = false
            recordingAudio = true
        }
        if request == destination { request = nil }
    }
    private struct ChatDay: Identifiable {
        let date: Date
        let items: [CoupleConversationItem]
        var id: Date { date }
    }
}
