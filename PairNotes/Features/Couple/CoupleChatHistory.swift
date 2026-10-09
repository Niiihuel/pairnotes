import Combine
import Foundation
import PairNotesCore

/// Typed, actor-isolated seam for deterministic history loading without an account.
@MainActor
struct ChatHistorySource {
    let currentScope: () -> String
    let isAuthorized: () -> Bool
    let messages: @MainActor (ConversationMessageCursor?) async throws -> ConversationMessagePage
    let photos: @MainActor (PhotoHistoryCursor?) async throws -> PhotoHistoryPage
    let letters: @MainActor (LetterHistoryCursor?) async throws -> LetterHistoryPage

    static func live(_ services: AppServices) -> Self {
        Self(currentScope: { services.privateImageKey("conversation") },
             isAuthorized: { services.membershipResolved && services.membership != nil },
             messages: { try await services.conversationMessages(cursor: $0) },
             photos: { try await services.photos(cursor: $0) },
             letters: { try await services.letterHistory(cursor: $0) })
    }
}

@MainActor
final class CoupleChatHistory: ObservableObject {
    @Published private(set) var messages: [CoupleMessage] = []
    @Published private(set) var photos: [CouplePhoto] = []
    @Published private(set) var letters: [TimeCapsuleLetter] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedScope: String?
    @Published private(set) var hasOlderMessages = false
    @Published private(set) var hasOlderPhotos = false
    @Published private(set) var hasOlderLetters = false
    private var messageCursor: ConversationMessageCursor?
    private var photoCursor: PhotoHistoryCursor?
    private var letterCursor: LetterHistoryCursor?
    private var firstMessageIDs: Set<String> = []
    private var firstPhotoIDs: Set<String> = []
    private var firstLetterIDs: Set<String> = []
    private var sequence: UInt64 = 0
    private var refreshRequested = false

    func reset() {
        sequence &+= 1; loading = false; refreshRequested = false; error = nil; loadedScope = nil
        messages = []; photos = []; letters = []
        messageCursor = nil; photoCursor = nil; letterCursor = nil
        firstMessageIDs = []; firstPhotoIDs = []; firstLetterIDs = []
        hasOlderMessages = false; hasOlderPhotos = false; hasOlderLetters = false
    }

    func refresh(services: AppServices, older: Bool = false) async {
        await refresh(source: .live(services), older: older)
    }

    func refresh(source: ChatHistorySource, older: Bool = false) async {
        guard source.isAuthorized() else { return }
        if loading { if !older { refreshRequested = true }; return }
        let scope = source.currentScope()
        if loadedScope != nil, loadedScope != scope { reset() }
        sequence &+= 1
        let request = sequence
        loading = true; refreshRequested = false; error = nil
        defer {
            if sequence == request {
                loading = false
                if refreshRequested, !Task.isCancelled {
                    refreshRequested = false
                    Task { await refresh(source: source) }
                }
            }
        }
        let fetchMessages = !older || hasOlderMessages
        let fetchPhotos = !older || hasOlderPhotos
        let fetchLetters = !older || hasOlderLetters
        let messageAfter = older ? messageCursor : nil
        let photoAfter = older ? photoCursor : nil
        let letterAfter = older ? letterCursor : nil
        async let messageResult = Self.capture {
            fetchMessages ? try await source.messages(messageAfter) : nil
        }
        async let photoResult = Self.capture {
            fetchPhotos ? try await source.photos(photoAfter) : nil
        }
        async let letterResult = Self.capture {
            fetchLetters ? try await source.letters(letterAfter) : nil
        }
        let (text, images, envelopes) = await (messageResult, photoResult, letterResult)
        guard !Task.isCancelled, sequence == request,
              source.isAuthorized(), source.currentScope() == scope else { return }
        var failed = false
        switch text {
        case .success(let page):
            if let page {
                let ids = Set(page.messages.map(\.id))
                if older || loadedScope == nil || firstMessageIDs.isDisjoint(with: ids) {
                    messageCursor = page.nextCursor
                }
                if !older { firstMessageIDs = ids }
                messages = Self.merge(messages, page.messages).sorted { $0.sentAt < $1.sentAt }
                hasOlderMessages = messageCursor != nil
            }
        case .failure: failed = true
        }
        switch images {
        case .success(let page):
            if let page {
                let ids = Set(page.photos.map(\.id))
                if older || loadedScope == nil || firstPhotoIDs.isDisjoint(with: ids) {
                    photoCursor = page.nextCursor
                }
                if !older { firstPhotoIDs = ids }
                photos = Self.merge(photos, page.photos).sorted { $0.sentAt < $1.sentAt }
                hasOlderPhotos = photoCursor != nil
            }
        case .failure: failed = true
        }
        switch envelopes {
        case .success(let page):
            if let page {
                let ids = Set(page.letters.map(\.id))
                if older || loadedScope == nil || firstLetterIDs.isDisjoint(with: ids) {
                    letterCursor = page.nextCursor
                }
                if !older { firstLetterIDs = ids }
                letters = Self.merge(letters, page.letters)
                hasOlderLetters = letterCursor != nil
            }
        case .failure: failed = true
        }
        loadedScope = scope
        if failed { error = "No se pudo actualizar todo el chat." }
    }

    func accept(_ item: CoupleConversationItem, scope: String) {
        guard loadedScope == nil || loadedScope == scope else { return }
        loadedScope = scope
        switch item {
        case .message(let value): messages = Self.merge(messages, [value])
        case .photo(let value): photos = Self.merge(photos, [value])
        case .letter(let value): letters = Self.merge(letters, [value])
        case .drawing: break
        }
    }

    private static func capture<T: Sendable>(_ operation: @MainActor () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    private static func merge<T: Identifiable>(_ old: [T], _ new: [T]) -> [T] where T.ID == String {
        var values = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for value in new { values[value.id] = value }
        return Array(values.values)
    }
}
