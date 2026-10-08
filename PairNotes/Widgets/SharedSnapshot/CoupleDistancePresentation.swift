import Foundation
import PairNotesCore

/// Distance is approximate. Only a fresh fix whose uncertainty still fits
/// inside the proximity threshold can confidently say they are together.
struct CoupleDistancePresentation {
    let title: String
    let detail: String
    let separation: CGFloat
    let fresh: Bool

    init(distance: CoupleDistance, at date: Date) {
        let status = distance.displayStatus(at: date)
        fresh = status == .available
        guard let meters = distance.displayMeters(at: date) else {
            separation = 0.35
            switch status {
            case .disabled: title = "Ubicación pausada"; detail = "Compartir en Nosotros"
            case .waiting: title = "Esperando ubicación"; detail = "Nuestra distancia"
            case .available, .stale: title = "Sin ubicación reciente"; detail = "Abrí para actualizar"
            }
            return
        }
        separation = min(1, max(0, log10(1 + meters / 100) / log10(1 + 100_000 / 100)))
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
