import SwiftUI

// MARK: - Attributs de trait (équivalent de « Format > Trait » de Visio)

enum DashPattern: String, Codable, CaseIterable, Identifiable {
    case solid, dash, dot, dashDot, longDash, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: return "Continu"
        case .dash: return "Tirets"
        case .dot: return "Pointillés"
        case .dashDot: return "Tiret-point"
        case .longDash: return "Tirets longs"
        case .none: return "Aucun trait"
        }
    }

    /// Motif en multiples de l'épaisseur du trait.
    var unitPattern: [CGFloat] {
        switch self {
        case .solid, .none: return []
        case .dash: return [4, 3]
        case .dot: return [1, 2]
        case .dashDot: return [6, 3, 1, 3]
        case .longDash: return [10, 4]
        }
    }
}

enum ArrowHead: String, Codable, CaseIterable, Identifiable {
    case none, open, filled, circle, diamond

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Aucune"
        case .open: return "Flèche ouverte"
        case .filled: return "Flèche pleine"
        case .circle: return "Cercle"
        case .diamond: return "Losange"
        }
    }
}

enum LineCapStyle: String, Codable, CaseIterable, Identifiable {
    case round, square, flat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .round: return "Arrondie"
        case .square: return "Carrée"
        case .flat: return "Plate"
        }
    }

    var cgCap: CGLineCap {
        switch self {
        case .round: return .round
        case .square: return .square
        case .flat: return .butt
        }
    }
}

struct LineStyle: Codable, Equatable {
    var color = RGBA(r: 0.25, g: 0.25, b: 0.25, a: 1)
    /// Épaisseur en points (suit le zoom).
    var width: Double = 1.5
    var dash: DashPattern = .solid
    /// 0 = opaque, 1 = invisible.
    var transparency: Double = 0
    var cap: LineCapStyle = .round
    var beginArrow: ArrowHead = .none
    var endArrow: ArrowHead = .none
    /// Multiplicateur de la taille des flèches.
    var arrowSize: Double = 1

    static let widthPresets: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2.25, 3, 4.5, 6, 8]
    static let arrowSizePresets: [(Double, String)] = [
        (0.5, "Très petite"), (0.75, "Petite"), (1, "Moyenne"), (1.5, "Grande"), (2, "Très grande"), (3, "Énorme"),
    ]
    static let maxWidth: Double = 50

    static let pathDefault = LineStyle(color: RGBA(r: 0.2, g: 0.2, b: 0.2, a: 1), width: 2)
    static let connectorDefault = LineStyle(color: RGBA(r: 0.3, g: 0.3, b: 0.3, a: 1), endArrow: .filled)
    static let dimensionDefault = LineStyle(color: RGBA(r: 0.15, g: 0.15, b: 0.15, a: 1), width: 0.75,
                                            beginArrow: .filled, endArrow: .filled, arrowSize: 0.75)

    enum CodingKeys: String, CodingKey {
        case color, width, dash, transparency, cap, beginArrow, endArrow, arrowSize
    }

    var isValid: Bool {
        let c = [color.r, color.g, color.b, color.a]
        return c.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
            && width.isFinite && width >= 0 && width <= Self.maxWidth
            && transparency.isFinite && transparency >= 0 && transparency <= 1
            && arrowSize.isFinite && arrowSize >= 0.1 && arrowSize <= 10
    }
}

extension LineStyle {
    /// Décodage tolérant : tout attribut absent prend sa valeur par défaut.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LineStyle()
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        dash = try c.decodeIfPresent(DashPattern.self, forKey: .dash) ?? d.dash
        transparency = try c.decodeIfPresent(Double.self, forKey: .transparency) ?? d.transparency
        cap = try c.decodeIfPresent(LineCapStyle.self, forKey: .cap) ?? d.cap
        beginArrow = try c.decodeIfPresent(ArrowHead.self, forKey: .beginArrow) ?? d.beginArrow
        endArrow = try c.decodeIfPresent(ArrowHead.self, forKey: .endArrow) ?? d.endArrow
        arrowSize = try c.decodeIfPresent(Double.self, forKey: .arrowSize) ?? d.arrowSize
    }
}

extension LineStyle {
    var displayColor: Color { color.color.opacity(1 - transparency) }

    /// Style de tracé à l'écran pour un zoom donné.
    func strokeStyle(zoom: CGFloat) -> StrokeStyle {
        let w = max(CGFloat(width) * zoom, 0.5)
        let unit = max(CGFloat(width), 1) * zoom
        return StrokeStyle(lineWidth: w, lineCap: cap.cgCap, lineJoin: .round,
                           dash: dash.unitPattern.map { $0 * unit })
    }

    /// Longueur d'une pointe de flèche à l'écran.
    func arrowLength(zoom: CGFloat) -> CGFloat {
        CGFloat((6 + 2.5 * width) * arrowSize) * zoom
    }
}

// MARK: - Modification groupée depuis l'inspecteur

@MainActor
extension DocumentStore {
    /// Style de trait affiché par l'inspecteur : celui du premier élément sélectionné qui en a un.
    var selectionLineStyle: LineStyle? {
        if let s = doc.shapes.first(where: { selection.contains($0.id) && $0.kind != .text }) { return s.line }
        return doc.connectors.first(where: { selection.contains($0.id) })?.line
    }

    /// Vrai si la sélection contient un élément qui peut porter des flèches (trait, courbe, connecteur).
    var selectionSupportsArrows: Bool {
        doc.shapes.contains { selection.contains($0.id) && $0.kind.isPath }
            || doc.connectors.contains { selection.contains($0.id) }
    }
}
