import Foundation
import CoreGraphics

/// Unité de mesure affichée. Une unité « monde » du dessin vaut 1 point typographique (1/72 pouce),
/// comme dans le PDF exporté à 100 %.
enum MeasureUnit: String, Codable, CaseIterable, Identifiable {
    case mm, cm, m
    case inch = "in"
    case pt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mm: return "Millimètres"
        case .cm: return "Centimètres"
        case .m: return "Mètres"
        case .inch: return "Pouces"
        case .pt: return "Points"
        }
    }

    var symbol: String {
        switch self {
        case .mm: return "mm"
        case .cm: return "cm"
        case .m: return "m"
        case .inch: return "in"
        case .pt: return "pt"
        }
    }

    /// Décimales proposées quand on choisit cette unité (1 mm de précision environ, comme Visio).
    var defaultPrecision: Int {
        switch self {
        case .mm, .pt: return 1
        case .cm: return 2
        case .m: return 3
        case .inch: return 2
        }
    }

    var millimetres: Double {
        switch self {
        case .mm: return 1
        case .cm: return 10
        case .m: return 1000
        case .inch: return 25.4
        case .pt: return 25.4 / 72
        }
    }
}

/// Repère (ligne guide) tiré d'une règle : vertical (position en X) ou horizontal (position en Y).
struct GuideLine: Identifiable, Codable, Equatable {
    var id = UUID()
    var vertical: Bool
    var position: CGFloat
}

extension Diagram {
    static let millimetresPerWorldUnit = 25.4 / 72
    static let scaleRange: ClosedRange<Double> = 0.0001...1_000_000
    static let maxGuides = 200

    /// Longueur réelle (unité de la page, échelle comprise) d'une longueur du dessin.
    func measure(_ worldLength: CGFloat) -> Double {
        Double(worldLength) * Diagram.millimetresPerWorldUnit * scale / unit.millimetres
    }

    /// Longueur du dessin correspondant à une valeur dans l'unité de la page.
    func worldLength(forMeasure value: Double) -> CGFloat {
        CGFloat(value * unit.millimetres / (Diagram.millimetresPerWorldUnit * scale))
    }

    /// Nombre formaté à la française (virgule décimale).
    static func format(_ value: Double, decimals: Int) -> String {
        let d = min(max(decimals, 0), 4)
        return String(format: "%.\(d)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Nombre à la française sans zéros inutiles : « 5 », « 0,25 », « 2,5 ».
    static func formatCompact(_ value: Double, maxDecimals: Int = 4) -> String {
        var s = format(value, decimals: maxDecimals)
        if s.contains(",") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(",") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// Texte d'une cote : « 123,4 mm ».
    func formatLength(_ worldLength: CGFloat) -> String {
        Diagram.format(measure(worldLength), decimals: precision) + " " + unit.symbol
    }
}
