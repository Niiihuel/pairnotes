import Foundation
import XCTest
@testable import PairNotesCore

final class CoupleSpaceTests: XCTestCase {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func day(_ text: String) -> CoupleDate { CoupleDate(rawValue: text)! }

    func testCivilDateRoundTripNeverAddsATimeZoneOrTime() throws {
        let value = day("2024-02-29")
        XCTAssertEqual(String(data: try JSONEncoder().encode(value), encoding: .utf8), "\"2024-02-29\"")
        XCTAssertEqual(try JSONDecoder().decode(CoupleDate.self, from: Data("\"2024-02-29\"".utf8)), value)
        let local = try XCTUnwrap(value.date(in: calendar("America/Argentina/Cordoba")))
        XCTAssertEqual(CoupleDate(date: local, calendar: calendar("America/Argentina/Cordoba")), value)
    }

    func testInvalidAndNormalizedDatesAreRejected() {
        for input in ["", "2023-02-29", "2024-02-30", "2024-04-31", "2024-00-12", "2024-13-01",
                      "2024-01-00", "0000-01-01", "2024-2-03", " 2024-02-03", "2024-02-03Z",
                      "２０２４-02-03", "2024-02-03T00:00:00Z"] {
            XCTAssertNil(CoupleDate(rawValue: input))
            let encoded = try! JSONEncoder().encode(input)
            XCTAssertThrowsError(try JSONDecoder().decode(CoupleDate.self, from: encoded))
        }
    }

    func testDaysTogetherUsesCalendarDaysAcrossDSTAndRejectsFutureStart() {
        let local = calendar("America/New_York")
        XCTAssertEqual(day("2026-03-08").daysTogether(on: instant("2026-03-09T04:00:00Z"), calendar: local), 1)
        XCTAssertEqual(day("2026-11-01").daysTogether(on: instant("2026-11-02T05:00:00Z"), calendar: local), 1)
        XCTAssertEqual(day("2026-03-08").daysTogether(on: instant("2026-03-08T23:00:00Z"), calendar: local), 0)
        XCTAssertNil(day("2026-03-10").daysTogether(on: instant("2026-03-09T12:00:00Z"), calendar: local))
    }

    func testAnniversaryUsesTodayAndLeapDayPolicy() {
        XCTAssertEqual(day("2024-02-29").daysUntilAnniversary(on: instant("2025-02-27T23:00:00Z"), calendar: calendar()), 1)
        XCTAssertEqual(day("2024-02-29").daysUntilAnniversary(on: instant("2025-02-28T23:00:00Z"), calendar: calendar()), 0)
        XCTAssertEqual(day("2024-02-29").daysUntilAnniversary(on: instant("2028-02-28T12:00:00Z"), calendar: calendar()), 1)
        XCTAssertNil(day("2027-03-01").daysUntilAnniversary(on: instant("2026-03-01T12:00:00Z"), calendar: calendar()))
    }

    func testMonthlyMilestonesClampEachMonthWithoutDriftingAndCountFromOrigin() {
        let milestones = day("2024-01-31").monthlyMilestones(after: instant("2024-02-01T10:00:00Z"), count: 3, calendar: calendar())
        XCTAssertEqual(milestones.map(\.months), [1, 2, 3])
        XCTAssertEqual(milestones.map(\.date), [instant("2024-02-29T09:00:00Z"), instant("2024-03-31T09:00:00Z"), instant("2024-04-30T09:00:00Z")])
        let later = day("2024-01-31").monthlyMilestones(after: instant("2024-02-29T09:00:00Z"), count: 1, calendar: calendar())
        XCTAssertEqual(later, [CoupleMonthlyMilestone(months: 2, date: instant("2024-03-31T09:00:00Z"))])
        let old = day("2020-01-31").monthlyMilestones(after: instant("2026-02-01T10:00:00Z"), count: 1, calendar: calendar())
        XCTAssertEqual(old.first?.months, 73)
        XCTAssertEqual(old.first?.date, instant("2026-02-28T09:00:00Z"))
    }

    func testMonthlyMilestonesUseLocalHourAcrossDSTAndRejectInvalidRequests() {
        let local = calendar("America/New_York")
        let source = day("2026-01-15")
        let milestones = source.monthlyMilestones(after: instant("2026-01-16T00:00:00Z"), count: 3, calendar: local)
        XCTAssertEqual(milestones.map { local.component(.hour, from: $0.date) }, [9, 9, 9])
        XCTAssertEqual(milestones[0].date, instant("2026-02-15T14:00:00Z"))
        XCTAssertEqual(milestones[1].date, instant("2026-03-15T13:00:00Z"))
        XCTAssertTrue(source.monthlyMilestones(after: instant("2026-01-01T00:00:00Z"), count: 3).isEmpty)
        for count in [-1, 0, 61] { XCTAssertTrue(source.monthlyMilestones(after: Date(), count: count).isEmpty) }
        XCTAssertTrue(source.monthlyMilestones(after: Date(), count: 3, hour: 24).isEmpty)
    }

    func testDistanceAgesToStaleThenHidesNumberAtThirtyMinutes() {
        let update = instant("2026-10-04T12:00:00Z")
        let distance = CoupleDistance(status: .available, meters: 1_200, updatedAt: update, accuracyMeters: 200)
        XCTAssertEqual(distance.displayStatus(at: update.addingTimeInterval(899)), .available)
        XCTAssertEqual(distance.displayStatus(at: update.addingTimeInterval(900)), .stale)
        XCTAssertEqual(distance.displayMeters(at: update.addingTimeInterval(1_799)), 1_200)
        XCTAssertNil(distance.displayMeters(at: update.addingTimeInterval(1_800)))
    }

    func testDisabledWaitingInvalidAndFutureDistancesNeverExposeANumber() {
        let now = instant("2026-10-04T12:00:00Z")
        for status in [CoupleDistanceStatus.disabled, .waiting] {
            XCTAssertNil(CoupleDistance(status: status, meters: 300, updatedAt: now, accuracyMeters: 100).displayMeters(at: now))
        }
        for meters in [-1.0, .infinity, .nan, 21_000_001] {
            let invalid = CoupleDistance(status: .available, meters: meters, updatedAt: now, accuracyMeters: 100)
            XCTAssertEqual(invalid.displayStatus(at: now), .waiting)
            XCTAssertNil(invalid.displayMeters(at: now))
        }
        XCTAssertNil(CoupleDistance(status: .available, meters: 300, updatedAt: now.addingTimeInterval(61), accuracyMeters: 100).displayMeters(at: now))
        XCTAssertNil(CoupleDistance(status: .available, meters: 300, updatedAt: now, accuracyMeters: -1).displayMeters(at: now))
        XCTAssertNil(CoupleDistance(status: .stale, updatedAt: now.addingTimeInterval(-1_800)).displayMeters(at: now))
        XCTAssertEqual(CoupleDistance(status: .stale, updatedAt: now.addingTimeInterval(-1_800)).displayStatus(at: now), .stale)
    }

    func testWidgetSnapshotRejectsThirdUserDuplicateMembersAndSentMessage() throws {
        let profiles = [CoupleProfile(uid: "fictional-alex", displayName: "Alex"), CoupleProfile(uid: "fictional-sam", displayName: "Sam")]
        let message = CoupleMessage(id: "fictional-message_1", authorID: "fictional-sam",
                                    recipientID: "fictional-alex", text: "Un mensaje ficticio", sentAt: Date())
        let valid = CoupleWidgetSnapshot(profiles: profiles, startedOn: nil, latestMessage: message, distance: CoupleDistance(status: .disabled))
        XCTAssertNoThrow(try valid.validate(for: "fictional-alex"))
        XCTAssertThrowsError(try valid.validate(for: "third-user"))
        XCTAssertThrowsError(try valid.validate(for: "fictional-sam"))
        let duplicate = CoupleWidgetSnapshot(profiles: [profiles[0], profiles[0]], startedOn: nil, latestMessage: nil, distance: CoupleDistance(status: .waiting))
        XCTAssertThrowsError(try duplicate.validate(for: "fictional-alex"))
    }
}
