import XCTest
import UserNotifications
import PairNotesCore
@testable import PairNotes

final class MonthlyReminderServiceTests: XCTestCase {
    @MainActor
    func testClearRemovesPendingAndDeliveredEvenWithoutAnInMemorySignature() async throws {
        let center = ReminderCenterFake()
        center.pending = ["PairNotes.monthly.old.1": request("PairNotes.monthly.old.1"),
                          "other.notification": request("other.notification")]
        center.delivered = ["PairNotes.monthly.old.2", "other.delivered"]
        let reminders = MonthlyReminderService(center: center)
        await reminders.clearScheduled()
        XCTAssertEqual(Set(center.pending.keys), ["other.notification"])
        XCTAssertEqual(center.delivered, ["other.delivered"])
        XCTAssertFalse(reminders.working)
    }

    @MainActor
    func testAnAddThatFinishesAfterOptOutIsRemoved() async throws {
        let center = ReminderCenterFake()
        let started = expectation(description: "add is suspended")
        center.onSuspendedAdd = { started.fulfill() }
        center.suspendNextAdd = true
        let reminders = MonthlyReminderService(center: center)
        let schedule = MonthlyReminderSchedule(scope: "account-a.pair-a.1", startedOn: try XCTUnwrap(CoupleDate(rawValue: "2026-01-15")))
        let task = Task { await reminders.reconcile(schedule: schedule, now: fixedDate(), calendar: utcCalendar()) }
        await fulfillment(of: [started], timeout: 2)
        await reminders.clearScheduled()
        center.releaseAdd()
        await task.value
        XCTAssertTrue(center.pending.isEmpty, "Clearing before add completed must still remove the late request")
        XCTAssertTrue(center.delivered.isEmpty)
    }

    @MainActor
    func testOldAccountCompletionCannotDeleteNewAccountsSchedule() async throws {
        let center = ReminderCenterFake()
        let started = expectation(description: "old account add suspended")
        center.onSuspendedAdd = { started.fulfill() }
        center.suspendNextAdd = true
        let reminders = MonthlyReminderService(center: center)
        let old = MonthlyReminderSchedule(scope: "account-a.pair-a.1", startedOn: try XCTUnwrap(CoupleDate(rawValue: "2026-01-15")))
        let new = MonthlyReminderSchedule(scope: "account-b.pair-b.1", startedOn: try XCTUnwrap(CoupleDate(rawValue: "2026-02-20")))
        let task = Task { await reminders.reconcile(schedule: old, now: fixedDate(), calendar: utcCalendar()) }
        await fulfillment(of: [started], timeout: 2)
        await reminders.clearScheduled()
        await reminders.reconcile(schedule: new, now: fixedDate(), calendar: utcCalendar())
        let newIDs = Set(center.pending.keys)
        XCTAssertEqual(newIDs.count, 48)
        center.releaseAdd()
        await task.value
        XCTAssertEqual(Set(center.pending.keys), newIDs)
        for request in center.pending.values {
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertEqual(trigger.dateComponents.day, 20)
            XCTAssertEqual(trigger.dateComponents.hour, 9)
            XCTAssertEqual(trigger.dateComponents.minute, 0)
            XCTAssertFalse(trigger.repeats)
        }
    }

    @MainActor
    func testCancellationAfterAddLeavesNoPartialScheduleAndCanRetry() async throws {
        let center = ReminderCenterFake()
        let started = expectation(description: "cancelled add suspended")
        center.onSuspendedAdd = { started.fulfill() }
        center.suspendNextAdd = true
        let reminders = MonthlyReminderService(center: center)
        let schedule = MonthlyReminderSchedule(scope: "account.pair.1", startedOn: try XCTUnwrap(CoupleDate(rawValue: "2026-01-15")))
        let task = Task { await reminders.reconcile(schedule: schedule, now: fixedDate(), calendar: utcCalendar()) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        center.releaseAdd()
        await task.value
        XCTAssertTrue(center.pending.isEmpty)
        await reminders.reconcile(schedule: schedule, now: fixedDate(), calendar: utcCalendar())
        XCTAssertEqual(center.pending.count, 48)
    }

    @MainActor
    private func request(_ identifier: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: identifier, content: UNMutableNotificationContent(), trigger: nil)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func fixedDate() -> Date {
        utcCalendar().date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
    }
}

@MainActor
private final class ReminderCenterFake: MonthlyNotificationCenter {
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: [String] = []
    var suspendNextAdd = false
    var onSuspendedAdd: (() -> Void)?
    private var suspendedAdd: CheckedContinuation<Void, Never>?

    func authorize() async throws -> Bool { true }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func deliveredIdentifiers() async -> [String] { delivered }
    func add(_ request: UNNotificationRequest) async throws {
        if suspendNextAdd {
            suspendNextAdd = false
            await withCheckedContinuation { continuation in
                suspendedAdd = continuation
                onSuspendedAdd?()
            }
        }
        pending[request.identifier] = request
    }
    func releaseAdd() { let continuation = suspendedAdd; suspendedAdd = nil; continuation?.resume() }
    func removePending(_ identifiers: [String]) { for id in identifiers { pending.removeValue(forKey: id) } }
    func removeDelivered(_ identifiers: [String]) { delivered.removeAll { identifiers.contains($0) } }
}
