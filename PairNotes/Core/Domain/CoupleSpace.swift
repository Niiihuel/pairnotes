import Foundation

/// A Gregorian civil date, independent of the time the person entered it.
public struct CoupleDate: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }),
              let year = Int(rawValue.prefix(4)), year >= 1,
              let month = Int(rawValue.dropFirst(5).prefix(2)),
              let day = Int(rawValue.suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        self.rawValue = rawValue
    }

    public init?(date: Date, calendar: Calendar = .current) {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let calendar = Self.gregorian(in: calendar)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        self.init(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
    }

    public func date(in calendar: Calendar = .current) -> Date? {
        let calendar = Self.gregorian(in: calendar)
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.year, from: date) == parts[0],
              calendar.component(.month, from: date) == parts[1],
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// Completed calendar days; future start dates do not fabricate a duration.
    public func daysTogether(on now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let calendar = Self.gregorian(in: calendar)
        guard now.timeIntervalSince1970.isFinite, let start = date(in: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        guard start <= today else { return nil }
        return calendar.dateComponents([.day], from: start, to: today).day
    }

    /// February 29 anniversaries use February 28 in a non-leap year.
    public func daysUntilAnniversary(on now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let calendar = Self.gregorian(in: calendar)
        guard daysTogether(on: now, calendar: calendar) != nil, let start = date(in: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        let month = calendar.component(.month, from: start)
        let day = calendar.component(.day, from: start)
        let year = calendar.component(.year, from: today)
        for candidateYear in year...(year + 1) {
            guard let monthStart = calendar.date(from: DateComponents(year: candidateYear, month: month, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: monthStart),
                  let anniversary = calendar.date(from: DateComponents(year: candidateYear, month: month,
                                                                         day: min(day, days.count))),
                  anniversary >= today else { continue }
            return calendar.dateComponents([.day], from: today, to: anniversary).day
        }
        return nil
    }

    /// Calendar-month milestones, clamped to each month's last day. The hour
    /// belongs to the optional reminder, never to the stored relationship date.
    public func monthlyMilestones(after date: Date, count: Int, calendar: Calendar = .current,
                                  hour: Int = 9) -> [CoupleMonthlyMilestone] {
        let calendar = Self.gregorian(in: calendar)
        guard (1...60).contains(count), (0...23).contains(hour),
              daysTogether(on: date, calendar: calendar) != nil, let start = self.date(in: calendar),
              let startMonth = calendar.dateInterval(of: .month, for: start)?.start,
              let currentMonth = calendar.dateInterval(of: .month, for: date)?.start,
              let elapsed = calendar.dateComponents([.month], from: startMonth, to: currentMonth).month else { return [] }
        let desiredDay = calendar.component(.day, from: start)
        let firstOffset = max(1, elapsed)
        var results: [CoupleMonthlyMilestone] = []
        for offset in firstOffset..<(firstOffset + count + 2) {
            guard let month = calendar.date(byAdding: .month, value: offset, to: startMonth),
                  let days = calendar.range(of: .day, in: .month, for: month) else { continue }
            var parts = calendar.dateComponents([.year, .month], from: month)
            parts.day = min(desiredDay, days.count)
            parts.hour = hour
            guard let reminder = calendar.date(from: parts), reminder > date else { continue }
            results.append(CoupleMonthlyMilestone(months: offset, date: reminder))
            if results.count == count { break }
        }
        return results
    }

    private static func gregorian(in calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        return result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let valid = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid civil date")
        }
        self = valid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CoupleMonthlyMilestone: Codable, Equatable, Sendable {
    public let months: Int
    public let date: Date
    public init(months: Int, date: Date) { self.months = months; self.date = date }
}

public struct CoupleAvatar: Codable, Equatable, Sendable {
    public let id: String
    public let sha256: String
    public init(id: String, sha256: String) { self.id = id; self.sha256 = sha256 }
}

public struct CoupleProfile: Codable, Equatable, Identifiable, Sendable {
    public let uid: String
    public let displayName: String
    public let avatar: CoupleAvatar?
    public var id: String { uid }
    public var initials: String {
        let words = displayName.split(whereSeparator: { $0.isWhitespace })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
    public init(uid: String, displayName: String, avatar: CoupleAvatar? = nil) {
        self.uid = uid; self.displayName = displayName; self.avatar = avatar
    }
}

public struct CoupleMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let authorID: String
    public let recipientID: String
    public let text: String
    public let sentAt: Date
    enum CodingKeys: String, CodingKey { case id, authorID = "authorId", recipientID = "recipientId", text, sentAt }
    public init(id: String, authorID: String, recipientID: String, text: String, sentAt: Date) {
        self.id = id; self.authorID = authorID; self.recipientID = recipientID; self.text = text; self.sentAt = sentAt
    }
}

public enum CoupleDistanceStatus: String, Codable, Sendable {
    case available, disabled, waiting, stale
}

/// Only the computed distance reaches widgets; coordinates remain on the server.
/// A previous distance stays visible with its age until sharing is revoked.
public struct CoupleDistance: Codable, Equatable, Sendable {
    public static let freshAge: TimeInterval = 15 * 60
    public static let maximumAge: TimeInterval = 30 * 60
    public let status: CoupleDistanceStatus
    public let meters: Double?
    public let updatedAt: Date?
    public let accuracyMeters: Double?

    public init(status: CoupleDistanceStatus, meters: Double? = nil, updatedAt: Date? = nil,
                accuracyMeters: Double? = nil) {
        self.status = status; self.meters = meters; self.updatedAt = updatedAt; self.accuracyMeters = accuracyMeters
    }

    public func displayStatus(at date: Date = Date()) -> CoupleDistanceStatus {
        guard status == .available || status == .stale else { return status }
        guard let updatedAt, updatedAt.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970.isFinite,
              updatedAt <= date.addingTimeInterval(60) else { return .waiting }
        if status == .stale, meters == nil { return .stale }
        guard let meters, meters.isFinite, meters >= 0, meters <= 21_000_000,
              let accuracyMeters, accuracyMeters.isFinite, accuracyMeters >= 0 else { return .waiting }
        if status == .stale || date.timeIntervalSince(updatedAt) >= Self.freshAge { return .stale }
        return .available
    }

    public func displayMeters(at date: Date = Date()) -> Double? {
        guard displayStatus(at: date) == .available || displayStatus(at: date) == .stale,
              let meters, meters.isFinite, meters >= 0, meters <= 21_000_000,
              let accuracyMeters, accuracyMeters.isFinite, accuracyMeters >= 0 else { return nil }
        return meters
    }
}

public struct CoupleWidgetSnapshot: Codable, Equatable, Sendable {
    public let profiles: [CoupleProfile]
    public let startedOn: CoupleDate?
    public let latestMessage: CoupleMessage?
    public let distance: CoupleDistance
    public let personalization: CouplePersonalization?
    public let latestGesture: CoupleGesture?
    public let latestPhoto: CouplePhoto?

    public init(profiles: [CoupleProfile], startedOn: CoupleDate?, latestMessage: CoupleMessage?, distance: CoupleDistance, personalization: CouplePersonalization? = nil, latestGesture: CoupleGesture? = nil, latestPhoto: CouplePhoto? = nil) {
        self.profiles = profiles; self.startedOn = startedOn; self.latestMessage = latestMessage; self.distance = distance; self.personalization = personalization; self.latestGesture = latestGesture
        self.latestPhoto = latestPhoto
    }

    public func validate(for uid: String, at date: Date = Date()) throws {
        try personalization?.validate(memberIDs: profiles.map(\.uid))
        try latestGesture?.validate(memberIDs: profiles.map(\.uid))
        try latestPhoto?.validate(memberIDs: profiles.map(\.uid), at: date)
        if let latestPhoto, latestPhoto.recipientId != uid { throw AccountDomainError.invalidPublication }
        guard profiles.count == 2, Set(profiles.map(\.uid)).count == 2,
              profiles.contains(where: { $0.uid == uid }),
              profiles.allSatisfy({ !$0.uid.isEmpty && $0.uid.utf8.count <= 256 &&
                  !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.displayName.count <= 100 }) else {
            throw AccountDomainError.invalidMembership
        }
        for profile in profiles {
            if let avatar = profile.avatar {
                guard UUID(uuidString: avatar.id) != nil, avatar.sha256.utf8.count == 64,
                      avatar.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw LocalStoreError.corruptData
                }
            }
        }
        if let message = latestMessage {
            guard (1...128).contains(message.id.utf8.count), message.id.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }), message.recipientID == uid, message.authorID != uid,
                  profiles.contains(where: { $0.uid == message.authorID }),
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.text.utf16.count <= 500,
                  message.sentAt.timeIntervalSince1970.isFinite, message.sentAt <= date.addingTimeInterval(60) else {
                throw AccountDomainError.invalidPublication
            }
        }
    }
}
