import Foundation
import XCTest
@testable import PairNotesCore

final class AffectionTests: XCTestCase {
    private func letter(_ additions: [String: Any] = [:]) throws -> TimeCapsuleLetter {
        var value: [String: Any] = ["id": "letter", "authorId": "a", "recipientId": "b", "status": "sealed",
            "opensAt": 9999999999999.0, "createdAt": 1000, "canOpen": false]
        value.merge(additions) { _, new in new }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TimeCapsuleLetter.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testLockedEnvelopeHasNoContentAndDoesNotTrustDeviceDate() throws {
        let envelope = try letter()
        try envelope.validate(uid: "b", memberIDs: ["a", "b"])
        XCTAssertFalse(envelope.canOpen)
        XCTAssertNil(envelope.title); XCTAssertNil(envelope.audio); XCTAssertNil(envelope.drawing)
        for field in ["title", "body", "noteId"] {
            XCTAssertThrowsError(try letter([field: "secret"]).validate(uid: "b", memberIDs: ["a", "b"]))
        }
        try letter(["title": "Author preview", "body": "Secret"]).validate(uid: "a", memberIDs: ["a", "b"])
    }
    func testLetterRejectsForeignMembersDraftDisclosureAndInvalidAudio() throws {
        XCTAssertThrowsError(try letter().validate(uid: "c", memberIDs: ["a", "b"]))
        XCTAssertThrowsError(try letter(["status": "draft"]).validate(uid: "b", memberIDs: ["a", "b"]))
        XCTAssertThrowsError(try letter(["canOpen": true, "audio": ["id": UUID().uuidString,
            "sha256": String(repeating: "a", count: 64), "duration": 61]]).validate(uid: "b", memberIDs: ["a", "b"]))
        let open = try letter(["canOpen": true, "title": "Abierta", "audio": ["id": UUID().uuidString,
            "sha256": String(repeating: "a", count: 64), "duration": 30]])
        try open.validate(uid: "b", memberIDs: ["a", "b"])
        XCTAssertTrue(open.canOpen)
    }
    func testGestureIsScopedToExactlyTheCouple() throws {
        let data = Data(#"{"id":"g","authorId":"a","recipientId":"b","kind":"hug","sentAt":1000}"#.utf8)
        let gesture = try JSONDecoder().decode(CoupleGesture.self, from: data)
        try gesture.validate(memberIDs: ["a", "b"])
        XCTAssertThrowsError(try gesture.validate(memberIDs: ["a", "c"]))
        XCTAssertEqual(gesture.kind, .hug)
    }
    func testWaveformUsesRealBoundedPCMAndRejectsCorruptChunks() {
        var bytes = [UInt8](repeating: 0, count: 44 + 320)
        func put(_ text: String, _ offset: Int) { for (i, value) in text.utf8.enumerated() { bytes[offset + i] = value } }
        func word(_ value: Int, _ offset: Int) { bytes[offset] = UInt8(value & 255); bytes[offset + 1] = UInt8((value >> 8) & 255) }
        put("RIFF", 0); put("WAVEfmt ", 8); word(16, 16); word(1, 20); word(1, 22); word(16, 34); put("data", 36); word(320, 40)
        XCTAssertEqual(VoiceWaveform.levels(Data(bytes)), [Double](repeating: 0, count: 32))
        for i in stride(from: 44, to: bytes.count, by: 2) { word(16384, i) }
        XCTAssertTrue(VoiceWaveform.levels(Data(bytes)).allSatisfy { $0 == 1 })
        word(65535, 40)
        XCTAssertTrue(VoiceWaveform.levels(Data(bytes)).isEmpty)
        XCTAssertTrue(VoiceWaveform.levels(Data("not audio".utf8)).isEmpty)
        XCTAssertTrue(VoiceWaveform.levels(Data(bytes), bins: 0).isEmpty)
    }
}
