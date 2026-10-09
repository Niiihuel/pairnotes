import CoreLocation
import Foundation

struct WidgetLocationSample: Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let capturedAt: Date

    func isUsable(at date: Date = Date()) -> Bool {
        latitude.isFinite && (-90...90).contains(latitude) &&
        longitude.isFinite && (-180...180).contains(longitude) &&
        horizontalAccuracy.isFinite && (0...5_000).contains(horizontalAccuracy) &&
        capturedAt.timeIntervalSince1970.isFinite &&
        capturedAt <= date.addingTimeInterval(60) && date.timeIntervalSince(capturedAt) <= 120
    }
}

/// A single, bounded measurement during a WidgetKit refresh. It never asks for
/// permission, starts a background session or stores coordinates on disk.
@MainActor
final class WidgetLocationSampler: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var pending: CheckedContinuation<WidgetLocationSample?, Never>?
    private var timeout: Task<Void, Never>?

    func sample() async -> WidgetLocationSample? {
        guard !Task.isCancelled, pending == nil else { return nil }
        let manager = CLLocationManager()
        guard manager.isAuthorizedForWidgetUpdates,
              manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else {
            return nil
        }
        self.manager = manager
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    self.manager = nil
                    continuation.resume(returning: nil)
                    return
                }
                pending = continuation
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(nil)
                }
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard manager === self.manager, let location = locations.last else { return }
            let value = WidgetLocationSample(latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude, horizontalAccuracy: location.horizontalAccuracy,
                capturedAt: location.timestamp)
            finish(value.isUsable() ? value : nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            guard manager === self.manager else { return }
            finish(nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager === self.manager else { return }
            if !manager.isAuthorizedForWidgetUpdates ||
                (manager.authorizationStatus != .authorizedWhenInUse && manager.authorizationStatus != .authorizedAlways) {
                finish(nil)
            }
        }
    }

    private func finish(_ value: WidgetLocationSample?) {
        let continuation = pending
        pending = nil
        timeout?.cancel()
        timeout = nil
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager = nil
        continuation?.resume(returning: value)
    }
}
