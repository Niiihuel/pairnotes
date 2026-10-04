import Foundation
import XCTest
@testable import PairNotesCore

final class SharedMemoryTests: XCTestCase {
    private let pair = PairMembership(id: "fictional-pair", memberIDs: ["fictional-alex", "fictional-sam"],
                                     pairEpoch: 2, partner: SessionIdentity(uid: "fictional-sam", displayName: "Sam"))
    private func data(_ changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["id": "memory_fictional-1", "pairId": "fictional-pair", "pairEpoch": 2,
            "authorId": "fictional-alex", "title": "Un recuerdo ficticio", "date": "2024-02-29",
            "kind": "memory", "recursYearly": false, "body": "Una descripción ficticia",
            "noteId": NSNull(), "photo": NSNull(), "createdAt": 1_000, "updatedAt": 2_000]
        value.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func decode(_ changes: [String: Any] = [:]) throws -> SharedMemory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(SharedMemory.self, from: data(changes))
    }

    func testServerContractAcceptsOpaqueIDsAndFullTitleLimit() throws {
        let memory = try decode(["title": String(repeating: "a", count: 120), "noteId": "drawing_fictional-1"])
        XCTAssertNoThrow(try memory.validate(for: pair))
        XCTAssertEqual(memory.date.rawValue, "2024-02-29")
        XCTAssertEqual(memory.createdAt, Date(timeIntervalSince1970: 1))
    }

    func testOtherPairEpochAndThirdAuthorCannotEnterCurrentMemoryList() throws {
        for invalid: [String: Any] in [["pairId": "other-pair"], ["pairEpoch": 1], ["authorId": "third-user"]] {
            let memory = try decode(invalid)
            XCTAssertThrowsError(try memory.validate(for: pair))
        }
    }

    func testMalformedDateAndMissingRequiredMetadataFailDecode() throws {
        XCTAssertThrowsError(try decode(["date": "2023-02-29"]))
        XCTAssertThrowsError(try decode(["date": "2024-02-29T00:00:00Z"]))
        XCTAssertThrowsError(try decode(["pairEpoch": NSNull()]))
    }

    func testInvalidKindsIDsWhitespaceAndLongTextFailValidation() throws {
        for invalid: [String: Any] in [
            ["kind": "unknown"], ["id": "../outside"], ["noteId": "https://example.test/note"],
            ["title": "   "], ["title": String(repeating: "a", count: 121)],
            ["body": String(repeating: "🐱", count: 1_001)], ["updatedAt": 500]
        ] {
            let memory = try decode(invalid)
            XCTAssertThrowsError(try memory.validate(for: pair))
        }
    }

    func testPhotosNeedValidOpaqueMetadataAndCanCoexistWithLinkedDrawing() throws {
        let goodPhoto = ["id": "50000000-0000-4000-8000-000000000005", "sha256": String(repeating: "a", count: 64)]
        let valid = try decode(["photo": goodPhoto])
        XCTAssertNoThrow(try valid.validate(for: pair))
        for photo in [["id": "../image", "sha256": goodPhoto["sha256"]!],
                      ["id": goodPhoto["id"]!, "sha256": "not-a-digest"]] {
            let memory = try decode(["photo": photo])
            XCTAssertThrowsError(try memory.validate(for: pair))
        }
        let linked = try decode(["photo": goodPhoto, "noteId": "drawing_1"])
        XCTAssertNoThrow(try linked.validate(for: pair))
    }
}
