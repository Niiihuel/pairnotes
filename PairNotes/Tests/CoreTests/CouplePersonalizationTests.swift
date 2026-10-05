import Foundation
import XCTest
@testable import PairNotesCore

final class CouplePersonalizationTests: XCTestCase {
    func testDefaultAndRoundTripPreserveSharedSettings() throws {
        var value = CouplePersonalization()
        try value.validate(memberIDs: ["a", "b"])
        value.theme = .lavender
        value.nicknames = ["a": "  Sol  ", "b": ""]
        value.phrase = "Nuestro rincón"
        value.homeOrder = [.drawing, .story, .distance, .message]
        let restored = try JSONDecoder().decode(CouplePersonalization.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        XCTAssertEqual(restored.name(for: "a", fallback: "Ana"), "Sol")
        XCTAssertEqual(restored.name(for: "b", fallback: "Bruno"), "Bruno")
        XCTAssertEqual(restored.name(for: "c", fallback: "Otro"), "Otro")
    }

    func testRejectsInvalidOrderForeignNicknamesAndOversizedText() throws {
        var value = CouplePersonalization()
        value.homeOrder = [.story, .story, .drawing, .distance]
        XCTAssertThrowsError(try value.validate(memberIDs: ["a", "b"]))
        value = CouplePersonalization(nicknames: ["outsider": "No"])
        XCTAssertThrowsError(try value.validate(memberIDs: ["a", "b"]))
        value = CouplePersonalization(phrase: String(repeating: "💌", count: 81))
        XCTAssertThrowsError(try value.validate(memberIDs: ["a", "b"]))
        value = CouplePersonalization(coverMemoryId: "../photo")
        XCTAssertThrowsError(try value.validate(memberIDs: ["a", "b"]))
    }

    func testLegacySnapshotAndMemoryDecodeWithoutNewFields() throws {
        let snapshot = Data(#"{"profiles":[{"uid":"a","displayName":"Ana"},{"uid":"b","displayName":"Bruno"}],"distance":{"status":"disabled"}}"#.utf8)
        let restored = try JSONDecoder().decode(CoupleWidgetSnapshot.self, from: snapshot)
        XCTAssertNil(restored.personalization)
        try restored.validate(for: "a")
        let memory = Data(#"{"id":"m","pairId":"p","pairEpoch":1,"authorId":"a","title":"Un día","date":"2024-01-01","kind":"memory","recursYearly":false,"body":"Texto","createdAt":0,"updatedAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SharedMemory.self, from: memory).decoration)
        for layout in MemoryDecoration.Layout.allCases {
            let decoration = MemoryDecoration(layout: layout, sticker: .flower)
            XCTAssertEqual(try JSONDecoder().decode(MemoryDecoration.self, from: JSONEncoder().encode(decoration)), decoration)
        }
    }
}
