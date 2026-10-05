import Foundation
import PairNotesCore

/// Private, account/pair/epoch-scoped working copy. Never read again during editing.
struct MemoryCompositionDraft: Codable, Equatable {
    var id: String
    var title: String
    var date: Date
    var body: String
    var recursYearly: Bool
    var noteID: String
    var removePhoto: Bool
    var decoration: MemoryDecoration
}

struct MemoryCompositionStorage {
    let key: String
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryCompositions", isDirectory: true)
    }
    private var baseName: String { ContentDigest.sha256(Data(key.utf8)) }
    private var textURL: URL { directory.appendingPathComponent(baseName + ".json") }
    private var drawingURL: URL { directory.appendingPathComponent(baseName + ".png") }
    private var audioURL: URL { directory.appendingPathComponent(baseName + ".wav") }
    private var photoURL: URL { directory.appendingPathComponent(baseName + ".jpg") }
    func load() -> MemoryCompositionDraft? { loadValue() }
    func loadValue<T: Decodable>() -> T? {
        guard let data = try? Data(contentsOf: textURL) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func drawing() -> Data? { try? Data(contentsOf: drawingURL) }
    func saveDrawing(_ data: Data?) throws {
        try prepare()
        if let data { try data.write(to: drawingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        else if FileManager.default.fileExists(atPath: drawingURL.path) { try FileManager.default.removeItem(at: drawingURL) }
    }
    func audio() -> Data? { try? Data(contentsOf: audioURL) }
    func saveAudio(_ data: Data?) throws {
        try prepare()
        if let data { try data.write(to: audioURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        else if FileManager.default.fileExists(atPath: audioURL.path) { try FileManager.default.removeItem(at: audioURL) }
    }
    func photo() -> Data? { try? Data(contentsOf: photoURL) }
    func save(_ draft: MemoryCompositionDraft) throws { try saveValue(draft) }
    func saveValue<T: Encodable>(_ draft: T) throws {
        try prepare()
        try JSONEncoder().encode(draft).write(to: textURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func savePhoto(_ photo: Data?) throws {
        try prepare()
        if let photo { try photo.write(to: photoURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        else if FileManager.default.fileExists(atPath: photoURL.path) { try FileManager.default.removeItem(at: photoURL) }
    }
    func clear() {
        try? FileManager.default.removeItem(at: drawingURL)
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: textURL)
        try? FileManager.default.removeItem(at: photoURL)
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
