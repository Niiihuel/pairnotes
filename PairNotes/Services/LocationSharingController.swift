import Combine
import CoreLocation
import Foundation
import PairNotesCore

struct LocationSample {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let date: Date
}

/// One measurement while the app is in use. Nothing starts at launch unless
/// this installation previously opted in for this exact account and pair.
@MainActor
final class LocationSharingController: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationSharingController()
    @Published private(set) var working = false
    @Published private(set) var message: String?
    private var manager: CLLocationManager?
    private var pending: CheckedContinuation<LocationSample, Error>?
    private var pendingID: UUID?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var lastUpload: (scope: String, date: Date)?
    private var consentMutation: (id: UUID, task: Task<Void, Error>)?

    private func preferenceKey(uid: String, pair: PairMembership) -> String {
        "PairNotes.location.\(uid).\(pair.id).\(pair.pairEpoch)"
    }

    func isEnabledHere(services: AppServices) -> Bool {
        guard let uid = services.identity?.uid, let pair = services.membership else { return false }
        return UserDefaults.standard.bool(forKey: preferenceKey(uid: uid, pair: pair)) &&
            services.coupleSpace?.location.sourceDeviceId == services.deviceID &&
            services.coupleSpace?.location.sharingEnabled == true
    }

    func activate(services: AppServices) async {
        guard !working, let uid = services.identity?.uid, let pair = services.membership else { return }
        let captured = beginOperation()
        message = nil
        defer { if captured == generation { working = false } }
        do {
            let sample = try await measure(allowPrompt: true)
            try check(captured, services: services, uid: uid, pair: pair)
            // If an earlier authorization is already travelling to the server,
            // finish it before starting a replacement mutation.
            if let prior = consentMutation { _ = await prior.task.result }
            try check(captured, services: services, uid: uid, pair: pair)
            let consentID = UUID()
            let task = Task { @MainActor in
                try services.checkSpaceContext(uid: uid, pair: pair)
                try await services.setLocationConsent(true)
            }
            consentMutation = (consentID, task)
            defer { if consentMutation?.id == consentID { consentMutation = nil } }
            try await task.value
            try check(captured, services: services, uid: uid, pair: pair)
            UserDefaults.standard.set(true, forKey: preferenceKey(uid: uid, pair: pair))
            try await upload(sample, services: services, pair: pair, uid: uid, operation: captured)
        } catch is CancellationError { return }
        catch {
            guard current(captured, services: services, uid: uid, pair: pair) else { return }
            message = error.localizedDescription
        }
    }

    func pause(services: AppServices) async {
        guard let uid = services.identity?.uid, let pair = services.membership else { invalidate(); return }
        // This must work while a measurement or activation is still pending.
        UserDefaults.standard.set(false, forKey: preferenceKey(uid: uid, pair: pair))
        let activation = consentMutation
        invalidate()
        let captured = beginOperation()
        defer { if captured == generation { working = false } }
        do {
            // Final remote consent mutation is always the explicit pause; an
            // earlier enable response cannot race it in the normal online path.
            if let activation { _ = await activation.task.result }
            try check(captured, services: services, uid: uid, pair: pair)
            let consentID = UUID()
            let task = Task { @MainActor in
                try services.checkSpaceContext(uid: uid, pair: pair)
                try await services.setLocationConsent(false)
            }
            consentMutation = (consentID, task)
            defer { if consentMutation?.id == consentID { consentMutation = nil } }
            try await task.value
            try check(captured, services: services, uid: uid, pair: pair)
            message = "Distancia pausada. Se borró tu última ubicación."
        } catch is CancellationError { return }
        catch {
            guard current(captured, services: services, uid: uid, pair: pair) else { return }
            message = "Se detuvieron las mediciones en este iPhone. No se pudo confirmar la pausa en el servidor; reintentá con conexión."
        }
    }

    func refreshIfNeeded(services: AppServices, force: Bool = false) async {
        guard !working, isEnabledHere(services: services), let uid = services.identity?.uid,
              let pair = services.membership else { return }
        let scope = preferenceKey(uid: uid, pair: pair)
        if !force, let lastUpload, lastUpload.scope == scope, lastUpload.date.timeIntervalSinceNow > -300 { return }
        let captured = beginOperation()
        defer { if captured == generation { working = false } }
        do {
            let sample = try await measure(allowPrompt: false)
            try check(captured, services: services, uid: uid, pair: pair)
            guard isEnabledHere(services: services) else { throw CancellationError() }
            try await upload(sample, services: services, pair: pair, uid: uid, operation: captured)
        } catch is CancellationError { return }
        catch {
            guard current(captured, services: services, uid: uid, pair: pair) else { return }
            message = "No se pudo actualizar la distancia. Podés reintentar desde Nosotros."
        }
    }

    /// Closing/backgrounding cancels the pending measurement; no background
    /// location mode, Always permission request or stored journey is used.
    func invalidate() {
        generation = UUID()
        lastUpload = nil
        working = false
        if let pendingID { finish(.failure(CancellationError()), measurement: pendingID) }
        message = nil
    }

    private func beginOperation() -> UUID {
        generation = UUID()
        working = true
        return generation
    }

    private func current(_ operation: UUID, services: AppServices, uid: String, pair: PairMembership) -> Bool {
        operation == generation && services.identity?.uid == uid &&
            services.membership?.id == pair.id && services.membership?.pairEpoch == pair.pairEpoch
    }

    private func check(_ operation: UUID, services: AppServices, uid: String, pair: PairMembership) throws {
        try Task.checkCancellation()
        guard current(operation, services: services, uid: uid, pair: pair) else { throw CancellationError() }
        try services.checkSpaceContext(uid: uid, pair: pair)
    }

    private func upload(_ sample: LocationSample, services: AppServices, pair: PairMembership,
                        uid: String, operation: UUID) async throws {
        try check(operation, services: services, uid: uid, pair: pair)
        guard isEnabledHere(services: services), let consent = services.coupleSpace?.location else {
            throw ServiceError.sessionChanged
        }
        let scope = preferenceKey(uid: uid, pair: pair)
        let key = scope + ".sequence.\(consent.consentVersion)"
        let previous = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value ?? 0
        let (incremented, overflow) = previous.addingReportingOverflow(1)
        guard !overflow else { throw ServiceError.invalidResponse }
        let next = max(incremented, Int64(Date().timeIntervalSince1970 * 1_000))
        UserDefaults.standard.set(NSNumber(value: next), forKey: key)
        try await services.sendLocation(sample, for: pair, uid: uid, consentVersion: consent.consentVersion, sequence: next)
        try check(operation, services: services, uid: uid, pair: pair)
        guard isEnabledHere(services: services) else { throw CancellationError() }
        lastUpload = (scope, Date())
        message = nil
    }

    private func measure(allowPrompt: Bool) async throws -> LocationSample {
        try Task.checkCancellation()
        guard pending == nil else { throw ServiceError.authorizationInProgress }
        let measurement = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                // A manager belongs to exactly one measurement. Late delegate
                // callbacks from a cancelled request cannot satisfy a new one.
                let manager = CLLocationManager()
                self.manager = manager
                pending = continuation
                pendingID = measurement
                manager.desiredAccuracy = kCLLocationAccuracyKilometer
                manager.delegate = self
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    self?.finish(.failure(LocationFailure.unavailable), measurement: measurement)
                }
                switch manager.authorizationStatus {
                case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
                case .notDetermined where allowPrompt: manager.requestWhenInUseAuthorization()
                default: finish(.failure(LocationFailure.permission), measurement: measurement)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), measurement: measurement) }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager, let pendingID else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: finish(.failure(LocationFailure.permission), measurement: pendingID)
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager, let pendingID else { return }
        guard let location = locations.last, CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 5_000,
              location.timestamp.timeIntervalSince1970.isFinite,
              abs(location.timestamp.timeIntervalSinceNow) <= 120 else {
            finish(.failure(LocationFailure.unavailable), measurement: pendingID); return
        }
        finish(.success(LocationSample(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                       accuracy: location.horizontalAccuracy, date: location.timestamp)), measurement: pendingID)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === self.manager, let pendingID else { return }
        finish(.failure(LocationFailure.unavailable), measurement: pendingID)
    }

    private func finish(_ result: Result<LocationSample, Error>, measurement: UUID) {
        guard pendingID == measurement else { return }
        let completion = pending
        pending = nil
        pendingID = nil
        timeout?.cancel()
        timeout = nil
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager = nil
        completion?.resume(with: result)
    }
}

private enum LocationFailure: LocalizedError {
    case permission, unavailable
    var errorDescription: String? {
        switch self {
        case .permission: return "Permití la ubicación Mientras se usa la app en Ajustes para compartir distancia."
        case .unavailable: return "No se pudo obtener una ubicación reciente. Probá de nuevo en un momento."
        }
    }
}
