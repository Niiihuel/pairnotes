import Foundation
import XCTest
@testable import PairNotesCore

final class PairTimelineTests: XCTestCase {
    private func note(_ date: Date, id: String = UUID().uuidString) -> RemoteNote {
        let prefix = "pairs/fictional-pair/1/\(id)/"
        return RemoteNote(id: id, pairID: "fictional-pair", pairEpoch: 1, authorID: "fictional-alex",
                   recipientID: "fictional-sam", revision: 1, revisionHash: String(repeating: "a", count: 64),
                   serverPublishedAt: date,
                   assets: NoteAssetPaths(source: prefix + "source", final: prefix + "final",
                                          widget: prefix + "widget", thumbnail: prefix + "thumbnail"))
    }

    func testMembershipRejectsSelfPairThirdAccountAndDuplicateMembers() throws {
        let partner = SessionIdentity(uid: "fictional-sam", displayName: "Sam")
        let valid = PairMembership(id: "pair", memberIDs: ["fictional-alex", partner.uid], pairEpoch: 1, partner: partner)
        XCTAssertNoThrow(try valid.validate(for: "fictional-alex"))
        XCTAssertThrowsError(try valid.validate(for: "third-account"))
        for members in [["fictional-alex", "fictional-alex"], ["fictional-alex", partner.uid, "third-account"], ["fictional-alex"]] {
            XCTAssertThrowsError(try PairMembership(id: "pair", memberIDs: members, pairEpoch: 1, partner: partner)
                .validate(for: "fictional-alex"))
        }
        XCTAssertThrowsError(try PairMembership(id: "pair", memberIDs: valid.memberIDs, pairEpoch: 0, partner: partner)
            .validate(for: "fictional-alex"))
    }

    func testInviteExpiresExactlyAtBoundary() {
        let deadline = Date(timeIntervalSince1970: 100)
        let invitation = PairInvite(token: "fictional-secret", expiresAt: deadline)
        XCTAssertFalse(invitation.isExpired(at: deadline.addingTimeInterval(-0.001)))
        XCTAssertTrue(invitation.isExpired(at: deadline))
        XCTAssertTrue(invitation.isExpired(at: deadline.addingTimeInterval(1)))
    }

    private let invitationCode = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcDE"

    func testInvitationShareMessageKeepsOpaqueCodeOnItsOwnLine() {
        let invitation = PairInvite(token: invitationCode, expiresAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(invitation.shareMessage, """
        Te invito a PairNotes.

        Código de invitación:
        \(invitationCode)

        Abrí PairNotes → Nosotros → Tengo una invitación y pegá este mensaje.
        """)
        XCTAssertEqual(invitation.shareMessage.components(separatedBy: invitationCode).count, 2)
    }

    func testInvitationImportAcceptsCleanCodeAndCompleteNewOrLegacyMessages() {
        let invitation = PairInvite(token: invitationCode, expiresAt: Date(timeIntervalSince1970: 100))
        let legacy = "\(invitationCode) Pegá este código en Nosotros para vincular nuestras cuentas."
        for input in [invitationCode, " \n\t\(invitationCode)\r\n ", invitation.shareMessage,
                      invitation.shareMessage.replacingOccurrences(of: "\n", with: "\r\n"),
                      invitation.shareMessage.replacingOccurrences(of: "\n", with: " "), legacy,
                      legacy.replacingOccurrences(of: " ", with: "\n")] {
            XCTAssertEqual(InvitationCode.parse(input), invitationCode)
        }
    }

    func testInvitationImportRejectsPartialModifiedAndNonASCIICodes() {
        let damaged = [String(invitationCode.dropLast()), invitationCode + "a",
                       invitationCode.replacingOccurrences(of: "_", with: "- "),
                       invitationCode.replacingOccurrences(of: "A", with: "А"), // Cyrillic A
                       invitationCode.replacingOccurrences(of: "-", with: "–"),
                       invitationCode.replacingOccurrences(of: "_", with: "＿"),
                       invitationCode.replacingOccurrences(of: "I", with: "I\u{200B}"),
                       String(invitationCode.prefix(10)) + "\n" + invitationCode.dropFirst(10),
                       "\u{00A0}" + invitationCode + "\u{00A0}"]
        for code in damaged {
            XCTAssertNil(InvitationCode.parse(code))
            let message = PairInvite(token: code, expiresAt: Date(timeIntervalSince1970: 100)).shareMessage
            XCTAssertNil(InvitationCode.parse(message))
        }
    }

    func testInvitationImportRejectsAmbiguousUnrecognizedAndOversizedMessages() {
        let invitation = PairInvite(token: invitationCode, expiresAt: Date(timeIntervalSince1970: 100))
        let anotherCode = String(repeating: "z", count: 43)
        for input in ["", " \n\t", invitationCode + "\n" + anotherCode,
                      invitationCode + "\n" + invitationCode,
                      invitation.shareMessage + "\n" + anotherCode,
                      "https://example.test/invite/\(invitationCode)",
                      "pairnotes://invite/\(invitationCode)",
                      "Mi código es \(invitationCode)",
                      invitation.shareMessage + " https://example.test",
                      String(repeating: " ", count: 2_049) + invitationCode,
                      String(repeating: "🐱", count: 1_024)] {
            XCTAssertNil(InvitationCode.parse(input))
        }
    }

    func testDaysUseUserTimeZoneAndServerTimeNotLocalCreationTime() throws {
        let formatter = ISO8601DateFormatter()
        let early = try XCTUnwrap(formatter.date(from: "2026-10-05T01:00:00Z"))
        let late = try XCTUnwrap(formatter.date(from: "2026-10-05T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Argentina/Cordoba"))
        let notes = [note(early), note(late)]
        let groups = NoteTimeline.groupedByDay(notes, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(calendar.component(.day, from: groups[0].id), 5)
        XCTAssertEqual(calendar.component(.day, from: groups[1].id), 4)
        XCTAssertEqual(groups[0].notes, [notes[1]])
    }

    func testDayGroupingHandlesTwentyThreeHourDSTDay() throws {
        let formatter = ISO8601DateFormatter()
        let first = try XCTUnwrap(formatter.date(from: "2026-03-08T06:30:00Z")) // 01:30 EST
        let second = try XCTUnwrap(formatter.date(from: "2026-03-08T07:30:00Z")) // 03:30 EDT
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let groups = NoteTimeline.groupedByDay([note(first), note(second)], calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        let start = try XCTUnwrap(groups.first?.id)
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        XCTAssertEqual(groups[0].notes.map(\.serverPublishedAt), [second, first])
    }

    func testCursorOrderIsDeterministicWhenTimestampsTieAndPageOverlapDeduplicates() throws {
        let date = Date(timeIntervalSince1970: 100)
        let first = note(date, id: "00000000-0000-0000-0000-000000000001")
        let second = note(date, id: "00000000-0000-0000-0000-000000000002")
        let merged = try NoteTimeline.merging([first, second], [first])
        XCTAssertEqual(merged.map(\.id), [second.id, first.id])
        XCTAssertEqual(merged.last?.cursor, TimelineCursor(serverPublishedAt: date, noteID: first.id))
        XCTAssertThrowsError(try NoteTimeline.merging([first], [note(date.addingTimeInterval(1), id: first.id)]))
    }

    func testRemoteMetadataRejectsPublicURLsAndTraversalPaths() throws {
        let baseline = note(Date())
        XCTAssertNoThrow(try baseline.validate())
        for path in ["https://example.test/public.png", "private/../other", "/absolute", "private//file",
                     "pairs/different-pair/1/\(baseline.id)/source"] {
            let bad = RemoteNote(id: baseline.id, pairID: baseline.pairID, pairEpoch: 1,
                                 authorID: baseline.authorID, recipientID: baseline.recipientID,
                                 revision: 1, revisionHash: baseline.revisionHash, serverPublishedAt: Date(),
                                 assets: NoteAssetPaths(source: path, final: baseline.assets.final,
                                                        widget: baseline.assets.widget, thumbnail: baseline.assets.thumbnail))
            XCTAssertThrowsError(try bad.validate())
        }
    }
}
