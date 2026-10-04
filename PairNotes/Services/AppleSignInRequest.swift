import AuthenticationServices
import CryptoKit
import Security
import UIKit

@MainActor
final class AppleSignInRequest: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Result {
        let identityToken: String
        let rawNonce: String
        let fullName: PersonNameComponents?
        let authorizationCode: String?
        let appleUserID: String
    }

    private let anchor: UIWindow
    private var continuation: CheckedContinuation<Result, Error>?
    private var controller: ASAuthorizationController?
    private var nonce: String?

    init(anchor: UIWindow) { self.anchor = anchor }

    func run(nonce rawNonce: String) async throws -> Result {
        guard continuation == nil else { throw ServiceError.authorizationInProgress }
        // Server-issued, single-use random challenge. Hash exactly once; the
        // server verifies the claim against its own stored challenge digest.
        guard rawNonce.count >= 32 else { throw ServiceError.invalidResponse }
        nonce = rawNonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let bytes = credential.identityToken, let token = String(data: bytes, encoding: .utf8),
              let nonce else {
            finish(.failure(ServiceError.invalidResponse))
            return
        }
        finish(.success(Result(identityToken: token, rawNonce: nonce, fullName: credential.fullName,
                               authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                               appleUserID: credential.user)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        nonce = nil
        pending?.resume(with: result)
    }
}
