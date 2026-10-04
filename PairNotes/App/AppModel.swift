import Combine
import PairNotesCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profile: UserProfile?
    @Published private(set) var notes: [DemoNote] = []

    private let identity: any IdentityProvider
    private let repository: any NotesRepository

    init(
        identity: any IdentityProvider = MockIdentityProvider(),
        repository: any NotesRepository = MockNotesRepository()
    ) {
        self.identity = identity
        self.repository = repository
    }

    func load() async {
        profile = await identity.currentUser()
        notes = await repository.notes()
    }
}
