import Foundation
import Security

enum ServiceError: LocalizedError {
    case setupRequired(String), signedOut, invalidResponse, noPair, sessionChanged
    case unsupportedProvider, authorizationInProgress, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .setupRequired(let message): return message
        case .signedOut: return "Iniciá sesión para continuar."
        case .invalidResponse: return "La respuesta del servicio no es válida."
        case .noPair: return "Vinculá las dos cuentas antes de enviar."
        case .sessionChanged: return "La sesión cambió. Volvé a abrir esta pantalla."
        case .unsupportedProvider: return "Usá el proveedor con el que creaste esta cuenta."
        case .authorizationInProgress: return "Ya hay un inicio de sesión en curso."
        case .keychain: return "No se pudo guardar la sesión de forma segura en este iPhone."
        }
    }
}

struct ServiceConfiguration {
    let apiBaseURL: URL
    let googleClientID: String
    let googleServerClientID: String?
    let apnsEnvironment: String

    static func load(bundle: Bundle = .main) throws -> Self {
        try load(values: bundle.infoDictionary ?? [:])
    }

    static func load(values: [String: Any]) throws -> Self {
        func value(_ key: String) -> String {
            let text = (values[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.contains("$(") ? "" : text
        }
        let api = value("PAIRNOTES_API_BASE_URL")
        guard !api.isEmpty else {
            throw ServiceError.setupRequired("La nube todavía no está configurada. Podés guardar dibujos en este iPhone.")
        }
        guard let url = URL(string: api.hasSuffix("/") ? api : api + "/"), url.scheme == "https",
              let host = url.host, !host.isEmpty, !["localhost", "127.0.0.1", "::1"].contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ServiceError.setupRequired("Configurá una URL HTTPS válida para la API de Railway.")
        }
        let environment = value("PAIRNOTES_APNS_ENVIRONMENT")
        guard ["development", "production"].contains(environment) else {
            throw ServiceError.setupRequired("Falta configurar el entorno APNs de la app firmada.")
        }
        let serverID = value("PAIRNOTES_GOOGLE_SERVER_CLIENT_ID")
        return Self(apiBaseURL: url, googleClientID: value("PAIRNOTES_GOOGLE_CLIENT_ID"),
                    googleServerClientID: serverID.isEmpty ? nil : serverID, apnsEnvironment: environment)
    }
}
