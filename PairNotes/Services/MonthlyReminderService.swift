import Combine
import Foundation
import UserNotifications
import PairNotesCore

/// Small boundary so cancellation races can be tested without permissions or
/// scheduling real notifications on the simulator running the tests.
@MainActor
protocol MonthlyNotificationCenter {
    func authorize() async throws -> Bool
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor
private final class SystemMonthlyNotificationCenter: MonthlyNotificationCenter {
    private let center = UNUserNotificationCenter.current()
    func authorize() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound]) }
    func pendingIdentifiers() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func deliveredIdentifiers() async -> [String] { await center.deliveredNotifications().map { $0.request.identifier } }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

struct MonthlyReminderSchedule: Equatable {
    let scope: String
    let startedOn: CoupleDate
}

@MainActor
final class MonthlyReminderService: ObservableObject {
    static let shared = MonthlyReminderService()
    @Published private(set) var working = false
    @Published private(set) var errorMessage: String?
    private let prefix = "PairNotes.monthly."
    private let center: any MonthlyNotificationCenter
    private let defaults: UserDefaults
    private var signature: String?
    private var pendingSignature: String?
    private var generation = UUID()
    private var preferenceOperation: UUID?
    private var preferenceScope: String?
    private var activeSchedule: MonthlyReminderSchedule?

    init(center: (any MonthlyNotificationCenter)? = nil, defaults: UserDefaults = .standard) {
        self.center = center ?? SystemMonthlyNotificationCenter()
        self.defaults = defaults
    }

    private func key(_ services: AppServices) -> String? {
        guard let uid = services.identity?.uid, let pair = services.membership else { return nil }
        return prefix + "enabled.\(uid).\(pair.id).\(pair.pairEpoch)"
    }

    func isEnabled(services: AppServices) -> Bool {
        guard let key = key(services) else { return false }
        return defaults.bool(forKey: key)
    }

    func setEnabled(_ enabled: Bool, services: AppServices) async {
        guard let key = key(services) else { return }
        // Disabling remains possible while authorization or scheduling is in
        // flight. The old operation loses ownership before the first await.
        if !enabled {
            preferenceOperation = nil
            preferenceScope = nil
            working = false
            defaults.set(false, forKey: key)
            errorMessage = nil
            await clearScheduled()
            objectWillChange.send()
            return
        }
        guard !working, services.coupleSpace?.startedOn != nil else { return }
        let operation = UUID()
        preferenceOperation = operation
        preferenceScope = key
        working = true
        errorMessage = nil
        defer {
            if preferenceOperation == operation { preferenceOperation = nil; preferenceScope = nil; working = false }
        }
        do {
            let allowed = try await center.authorize()
            guard preferenceOperation == operation, self.key(services) == key, !Task.isCancelled else { return }
            guard allowed else {
                errorMessage = "Permití las notificaciones de PairNotes en Ajustes para recibir el aviso mensual."
                return
            }
            defaults.set(true, forKey: key)
            signature = nil
            await synchronize(services: services)
            objectWillChange.send()
        } catch {
            if preferenceOperation == operation, self.key(services) == key, !Task.isCancelled {
                errorMessage = "No se pudo activar el aviso. Intentá nuevamente."
            }
        }
    }

    func clearScheduled() async {
        generation = UUID()
        preferenceOperation = nil
        preferenceScope = nil
        working = false
        signature = nil
        pendingSignature = nil
        activeSchedule = nil
        errorMessage = nil
        await removeObsoleteNotifications()
    }

    func synchronize(services: AppServices) async {
        // A routine refresh while the permission sheet is open must not cancel
        // that same account's explicit opt-in before its preference is written.
        if preferenceOperation != nil, preferenceScope == key(services), !isEnabled(services: services) { return }
        guard let key = key(services), isEnabled(services: services), let started = services.coupleSpace?.startedOn else {
            // Clearing must not depend on an in-memory signature: a process can
            // restart with old system requests, or opt-out can reset it first.
            await clearScheduled()
            return
        }
        let schedule = MonthlyReminderSchedule(scope: key, startedOn: started)
        await reconcile(schedule: schedule) { [weak services] in
            guard let services else { return false }
            return self.key(services) == key && self.isEnabled(services: services) &&
                services.coupleSpace?.startedOn == started
        }
    }

    /// A request namespace belongs to one generation. A late `add` completion
    /// can only remove its own requests, never those of a replacement account.
    func reconcile(schedule: MonthlyReminderSchedule, now: Date = Date(),
                   calendar inputCalendar: Calendar = .current,
                   isCurrent: @escaping @MainActor () -> Bool = { true }) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = inputCalendar.timeZone
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        let newSignature = "\(schedule.scope)|\(schedule.startedOn.rawValue)|\(calendar.timeZone.identifier)|\(day)"
        guard isCurrent(), !Task.isCancelled,
              newSignature != signature, newSignature != pendingSignature else { return }
        generation = UUID()
        let captured = generation
        let requestPrefix = prefix + captured.uuidString + "."
        activeSchedule = schedule
        pendingSignature = newSignature
        signature = nil
        var attempted: [String] = []
        defer { if captured == generation { pendingSignature = nil } }
        func valid() -> Bool {
            captured == generation && activeSchedule == schedule && isCurrent() && !Task.isCancelled
        }
        await removeObsoleteNotifications()
        guard valid() else { return }
        do {
            // Replenish in the foreground. Month 1, 2, 3... fires at 09:00 in
            // the current local time zone, without a timer or location access.
            for milestone in schedule.startedOn.monthlyMilestones(after: now, count: 48, calendar: calendar, hour: 9) {
                guard valid() else { remove(attempted); return }
                let content = UNMutableNotificationContent()
                content.title = "Otro mes juntos 💕"
                content.body = "Hoy cumplen \(milestone.months) \(milestone.months == 1 ? "mes" : "meses") de relación."
                content.sound = .default
                content.userInfo = ["type": "monthlyAnniversary"]
                let components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: milestone.date)
                let identifier = requestPrefix + "\(milestone.months)"
                attempted.append(identifier)
                try await center.add(UNNotificationRequest(identifier: identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
                // Clearing while add was suspended may not have seen this ID.
                guard valid() else { remove(attempted); return }
            }
            guard valid() else { remove(attempted); return }
            signature = newSignature
            errorMessage = nil
        } catch {
            remove(attempted)
            if valid() { errorMessage = "No se pudieron programar todos los avisos. Abrí la app para reintentar." }
        }
    }

    private func removeObsoleteNotifications() async {
        let requests = await center.pendingIdentifiers()
        center.removePending(obsolete(requests))
        let delivered = await center.deliveredIdentifiers()
        center.removeDelivered(obsolete(delivered))
    }

    private func obsolete(_ identifiers: [String]) -> [String] {
        let preserved = activeSchedule == nil ? nil : prefix + generation.uuidString + "."
        return identifiers.filter { id in
            id.hasPrefix(prefix) && !(preserved.map { id.hasPrefix($0) } ?? false)
        }
    }

    private func remove(_ identifiers: [String]) {
        center.removePending(identifiers)
        center.removeDelivered(identifiers)
    }
}
