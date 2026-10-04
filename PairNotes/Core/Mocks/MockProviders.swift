import Foundation

public enum DemoFixtures {
    public static let currentUser = UserProfile(
        id: "demo-luna", displayName: "Luna (demo)", avatarSymbol: "moon.fill"
    )
    public static let partner = UserProfile(
        id: "demo-sol", displayName: "Sol (demo)", avatarSymbol: "sun.max.fill"
    )
    public static let notes = [
        DemoNote(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            title: "Una pausa juntos", message: "¿Un té y un dibujo esta tarde?",
            author: partner, createdAt: Date(timeIntervalSince1970: 1_780_272_000)
        ),
        DemoNote(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            title: "Pequeños recuerdos", message: "Este es un recuerdo ficticio para probar la app.",
            author: currentUser, createdAt: Date(timeIntervalSince1970: 1_780_185_600)
        )
    ]
}

public struct MockIdentityProvider: IdentityProvider {
    private let user: UserProfile?
    public init(user: UserProfile? = DemoFixtures.currentUser) { self.user = user }
    public func currentUser() async -> UserProfile? { user }
}

public struct MockNotesRepository: NotesRepository {
    private let fixtures: [DemoNote]
    public init(fixtures: [DemoNote] = DemoFixtures.notes) { self.fixtures = fixtures }
    public func notes() async -> [DemoNote] { fixtures }
}

/// No Core Location dependency and no authorization request as a side effect.
public struct MockLocationProvider: LocationProvider {
    private let value: LocationSharingState
    public init(initialState: LocationSharingState = .notRequested) { value = initialState }
    public func state() async -> LocationSharingState { value }
}
