import Foundation
import PairNotesCore

/// Distance is approximate. Only a fresh fix whose uncertainty still fits
/// inside the proximity threshold can confidently say they are together.
struct CoupleDistancePresentation {
    let title: String
    let detail: String
    let separation: CGFloat
    let fresh: Bool
    let updatedAt: Date?
    let hasDistance: Bool
    let symbol: String

    init(distance: CoupleDistance, at date: Date) {
        let status = distance.displayStatus(at: date)
        fresh = status == .available
        guard let meters = distance.displayMeters(at: date) else {
            separation = 0.5
            updatedAt = nil
            hasDistance = false
            symbol = status == .disabled ? "location.slash" : "location"
            switch status {
            case .disabled: title = "Ubicación pausada"; detail = "Privacidad de ubicación"
            case .waiting: title = "Esperando ubicación"; detail = "Cuando ambos la compartan"
            case .available, .stale: title = "Esperando ubicación"; detail = "Sin distancia guardada"
            }
            return
        }
        hasDistance = true
        symbol = "heart.fill"
        updatedAt = distance.updatedAt.map { min($0, date) }
        // A logarithmic scale keeps nearby changes visible without making all
        // distances above 100 km look identical. The whole valid range fits.
        separation = min(1, max(0, log1p(meters / 100) / log1p(21_000_000 / 100)))
        if fresh, let accuracy = distance.accuracyMeters, meters + accuracy <= 100 {
            title = "¡Estamos juntos!"; detail = "A menos de 100 m"
        } else {
            if meters < 100 { title = "≈ menos de 100 m" }
            else if meters < 1_000 { title = "≈ \(Int((meters / 100).rounded()) * 100) m" }
            else { title = "≈ \((meters / 1_000).formatted(.number.precision(.fractionLength(meters >= 100_000 ? 0 : 1)))) km" }
            detail = fresh ? "Nuestra distancia" : "Ubicación anterior"
        }
    }
}

/// Keeps both portraits and their connection inside even a narrow accessory.
/// Separation changes only the gap; it never stretches or fades either face.
struct CoupleDistanceAvatarLayout {
    let width: CGFloat
    let avatarDiameter: CGFloat
    let connectorWidth: CGFloat
    let leadingInset: CGFloat

    init(width: CGFloat, preferredAvatarSize: CGFloat, separation: CGFloat, compact: Bool) {
        self.width = width.isFinite ? max(0, width) : 0
        let minimumGap: CGFloat = compact ? 24 : 28
        let reservedGap = min(minimumGap, self.width)
        let preferred = preferredAvatarSize.isFinite ? max(0, preferredAvatarSize) : 0
        avatarDiameter = min(preferred, max(0, (self.width - reservedGap) / 2))
        let maximumGap = max(0, self.width - avatarDiameter * 2)
        let minimum = min(minimumGap, maximumGap)
        let fraction = separation.isFinite ? min(1, max(0, separation)) : 0.5
        connectorWidth = minimum + (maximumGap - minimum) * fraction
        leadingInset = max(0, (self.width - avatarDiameter * 2 - connectorWidth) / 2)
    }
}
