import Foundation
import Combine
import UIKit
import CryptoKit
import AuthenticationServices
import GoogleSignIn
import PairNotesCore

@MainActor
final class AppServices: NSObject, ObservableObject {
    static let shared = AppServices()

    @Published private(set) var identity: SessionIdentity?
    @Published private(set) var membership: PairMembership?
    @Published private(set) var membershipResolved = false
    @Published private(set) var setupMessage: String?
    @Published private(set) var lastError: String?
    @Published var notificationsEnabled = false
    @Published var profileAvatar: CoupleAvatar?
    @Published var coupleSpace: CoupleSpaceState?
    @Published var spaceError: String?
    var spaceSequence: UInt64 = 0

    var onOpenNote: ((String) -> Void)?
    var onOpenCouple: (() -> Void)?
    var onOpenMessages: (() -> Void)?
    var onSessionInvalidated: (() -> Void)?
    var onReceivedNote: (() -> Void)?
    var widgetBaseURL: URL? { client?.configuration.apiBaseURL }
    var isConfigured: Bool { client != nil }
    var authProvider: String? { client?.session?.provider }

    let client: RailwayClient?
    var pendingAPNsToken: Data?
    private var appleRequest: AppleSignInRequest?
    private var authorizationInProgress = false
    private var signingOut = false
    private var revocationObserver: NSObjectProtocol?
    private var refreshSequence: UInt64 = 0

    override init() {
        do {
            let configuration = try ServiceConfiguration.load()
            client = try RailwayClient(configuration: configuration, store: PrivateSessionStore(accessGroup: configuration.privateKeychainAccessGroup))
            identity = client?.session?.identity
        } catch {
            client = nil
            setupMessage = error.localizedDescription
        }
        super.init()
        client?.onInvalidated = { [weak self] in self?.clearSession() }
        configureNotifications()
        revocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.authProvider == "apple" else { return }
                try? await self.signOut()
            }
        }
    }

    /// An outage never becomes a confirmed unlink event.
    func restore() async {
        guard let client, let saved = client.session else { return }
        do {
            if saved.provider == "apple", let appleUserID = saved.providerUserID {
                let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleUserID)
                try checkUID(saved.identity.uid)
                if state == .revoked || state == .notFound { try await signOut(); return }
            }
            let response = try await client.authenticatedJSON(path: "auth/session", method: "GET")
            try checkUID(saved.identity.uid)
            guard let profile = response["identity"] as? [String: Any],
                  profile["uid"] as? String == saved.identity.uid,
                  let name = profile["displayName"] as? String else { throw ServiceError.invalidResponse }
            identity = SessionIdentity(uid: saved.identity.uid, displayName: name)
            try await refreshMembership()
            await restoreNotificationPreference()
        } catch { recordError(error) }
    }

    func signInGoogle(presenting: UIViewController) async throws {
        try await googleAuthorization(presenting: presenting, reauthenticate: false)
    }

    func reauthenticateGoogle(presenting: UIViewController) async throws {
        guard authProvider == "google" else { throw ServiceError.unsupportedProvider }
        try await googleAuthorization(presenting: presenting, reauthenticate: true)
    }

    private func googleAuthorization(presenting: UIViewController, reauthenticate: Bool) async throws {
        let client = try requireClient()
        guard !authorizationInProgress else { throw ServiceError.authorizationInProgress }
        let clientID = client.configuration.googleClientID
        guard !clientID.isEmpty else { throw ServiceError.setupRequired("Falta configurar el cliente OAuth de Google para iOS.") }
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard schemes.contains(clientID.split(separator: ".").reversed().joined(separator: ".")) else {
            throw ServiceError.setupRequired("Falta el esquema de retorno del cliente OAuth de Google.")
        }
        let expectedUID = reauthenticate ? try requireUID() : nil
        authorizationInProgress = true
        defer { authorizationInProgress = false }
        let challenge = try await client.challenge(provider: "google")
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: client.configuration.googleServerClientID)
        do {
            let nonce = SHA256.hash(data: Data(challenge.nonce.utf8)).map { String(format: "%02x", $0) }.joined()
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting, hint: nil, additionalScopes: nil, nonce: nonce)
            guard let token = result.user.idToken?.tokenString else { throw ServiceError.invalidResponse }
            let session = try await client.exchange(provider: "google", idToken: token, challengeID: challenge.id,
                                                    providerUserID: nil, expectedUID: expectedUID, deviceID: deviceID)
            applySession(session)
            try await establishProfile(proposedName: result.user.profile?.name)
        } catch {
            // kGIDSignInErrorCodeCanceled = -5 in the pinned SDK's public header.
            // NS_ERROR_ENUM's imported type name differs from older SDK examples.
            if (error as NSError).domain == kGIDSignInErrorDomain, (error as NSError).code == -5 {
                throw CancellationError()
            }
            throw error
        }
    }

    func signInApple(presentationAnchor: UIWindow) async throws {
        try await appleAuthorization(anchor: presentationAnchor, reauthenticate: false)
    }

    func reauthenticateApple(presentationAnchor: UIWindow) async throws {
        guard authProvider == "apple" else { throw ServiceError.unsupportedProvider }
        try await appleAuthorization(anchor: presentationAnchor, reauthenticate: true)
    }

    private func appleAuthorization(anchor: UIWindow, reauthenticate: Bool) async throws {
        let client = try requireClient()
        guard !authorizationInProgress else { throw ServiceError.authorizationInProgress }
        let expectedUID = reauthenticate ? try requireUID() : nil
        authorizationInProgress = true
        defer { authorizationInProgress = false; appleRequest = nil }
        let challenge = try await client.challenge(provider: "apple")
        let request = AppleSignInRequest(anchor: anchor)
        appleRequest = request
        let result = try await request.run(nonce: challenge.nonce)
        let session = try await client.exchange(provider: "apple", idToken: result.identityToken, challengeID: challenge.id,
                                               providerUserID: result.appleUserID, expectedUID: expectedUID, deviceID: deviceID)
        applySession(session)
        try await establishProfile(proposedName: result.fullName.map { PersonNameComponentsFormatter().string(from: $0) })
    }

    @discardableResult
    func handle(url: URL) -> Bool { GIDSignIn.sharedInstance.handle(url) }

    func updateDisplayName(_ name: String) async throws {
        let uid = try requireUID()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(clean.utf16.count) else { throw ServiceError.invalidResponse }
        _ = try await call("upsertProfile", ["displayName": clean])
        try checkUID(uid)
        try await refreshMembership()
    }

    func refreshMembership() async throws {
        guard !signingOut else { throw ServiceError.sessionChanged }
        let uid = try requireUID()
        refreshSequence &+= 1
        let sequence = refreshSequence
        let response = try await call("getPairState")
        try checkUID(uid)
        guard sequence == refreshSequence, !signingOut else { return }
        guard let profile = response["profile"] as? [String: Any], profile["uid"] as? String == uid,
              let name = profile["displayName"] as? String else { throw ServiceError.invalidResponse }
        let newPair = try Self.membership(from: response, for: uid)
        if membership?.id != newPair?.id || membership?.pairEpoch != newPair?.pairEpoch {
            coupleSpace = nil
            spaceSequence &+= 1
            spaceError = nil
            onSessionInvalidated?()
        }
        if let avatar = profile["avatar"] as? [String: Any] { profileAvatar = try decodeSpace(avatar) }
        else { profileAvatar = nil }
        identity = SessionIdentity(uid: uid, displayName: name)
        membership = newPair
        membershipResolved = true
        lastError = nil
    }

    func createInvite() async throws -> PairInvite {
        let response = try await call("createInvite")
        guard let token = response["token"] as? String, let expires = response["expiresAt"] as? NSNumber else { throw ServiceError.invalidResponse }
        return PairInvite(token: token, expiresAt: Date(timeIntervalSince1970: expires.doubleValue / 1_000))
    }

    func acceptInvite(token: String) async throws {
        _ = try await call("acceptInvite", ["token": token.trimmingCharacters(in: .whitespacesAndNewlines)])
        try await refreshMembership()
    }

    func revokeInvite() async throws { _ = try await call("revokeInvite") }

    func closePair() async throws {
        guard let pair = membership else { throw ServiceError.noPair }
        _ = try await call("closePair", ["pairId": pair.id, "pairEpoch": pair.pairEpoch])
        membership = nil
        membershipResolved = true
        onSessionInvalidated?()
        try await refreshMembership()
    }

    func signOut() async throws {
        guard !signingOut else { return }
        signingOut = true
        defer { signingOut = false }
        refreshSequence &+= 1
        membershipResolved = false
        membership = nil
        notificationsEnabled = false
        coupleSpace = nil
        spaceSequence &+= 1
        spaceError = nil
        profileAvatar = nil
        onSessionInvalidated?()
        if let client, let uid = client.session?.identity.uid {
            // Local logout completes even offline. The remote device revocation
            // cannot be reported as confirmed when this request fails.
            do { _ = try await client.authenticatedJSON(path: "auth/signout", body: ["deviceId": deviceID]) }
            catch { recordError(error) }
            guard client.session == nil || client.session?.identity.uid == uid else { throw ServiceError.sessionChanged }
            client.clear()
        }
        GIDSignIn.sharedInstance.signOut()
        clearSession()
    }

    func requireClient() throws -> RailwayClient {
        guard let client else { throw ServiceError.setupRequired(setupMessage ?? "Configurá la API para continuar.") }
        return client
    }

    func requireUID() throws -> String {
        guard let uid = try requireClient().session?.identity.uid else { throw ServiceError.signedOut }
        return uid
    }

    func checkUID(_ expected: String) throws {
        try Task.checkCancellation()
        guard try requireUID() == expected else { throw ServiceError.sessionChanged }
    }

    func recordError(_ error: Error) { lastError = error.localizedDescription }

    func call(_ name: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        let uid = try requireUID()
        let response = try await requireClient().authenticatedJSON(path: name, body: ["data": payload])
        try checkUID(uid)
        guard let result = response["result"] as? [String: Any] else { throw ServiceError.invalidResponse }
        return result
    }

    private func establishProfile(proposedName: String?) async throws {
        let state = try await call("getPairState")
        let existing = (state["profile"] as? [String: Any])?["displayName"] as? String
        if existing?.isEmpty != false {
            let name = proposedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await call("upsertProfile", ["displayName": String((name?.isEmpty == false ? name! : "Mi perfil").prefix(60))])
        }
        try await refreshMembership()
        await restoreNotificationPreference()
    }

    private func applySession(_ session: AuthSession) {
        if identity?.uid != session.identity.uid { clearSession() }
        identity = session.identity
        lastError = nil
    }

    private func clearSession() {
        refreshSequence &+= 1
        identity = nil
        membership = nil
        profileAvatar = nil
        coupleSpace = nil
        spaceSequence &+= 1
        spaceError = nil
        membershipResolved = false
        notificationsEnabled = false
        onSessionInvalidated?()
    }

    /// Only explicit JSON null confirms there is no relationship. A malformed
    /// response must not cancel an account's durable pending publications.
    nonisolated static func membership(from response: [String: Any], for uid: String) throws -> PairMembership? {
        if response["pair"] is NSNull { return nil }
        guard let data = response["pair"] as? [String: Any] else { throw ServiceError.invalidResponse }
        guard let id = data["id"] as? String, let members = data["members"] as? [String],
              let epoch = data["pairEpoch"] as? NSNumber, data["status"] as? String == "active",
              let partner = data["partner"] as? [String: Any], let partnerID = partner["uid"] as? String,
              let name = partner["displayName"] as? String else { throw ServiceError.invalidResponse }
        let pair = PairMembership(id: id, memberIDs: members, pairEpoch: epoch.uint64Value,
                                  partner: SessionIdentity(uid: partnerID, displayName: name))
        try pair.validate(for: uid)
        return pair
    }
}
