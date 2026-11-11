import SwiftUI

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left: return "À gauche"
        case .center: return "Centré"
        case .right: return "À droite"
        }
    }

    var symbol: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

/// Mise en forme du texte d'une forme.
struct TextStyle: Codable, Equatable {
    /// Taille en points (suit le zoom).
    var size: Double = 14
    var color = RGBA(r: 0, g: 0, b: 0, a: 1)
    var bold = false
    var italic = false
    var alignment: TextAlign = .center

    static let sizePresets: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72]
    static let sizeRange: ClosedRange<Double> = 4...400

    enum CodingKeys: String, CodingKey { case size, color, bold, italic, alignment }

    var isValid: Bool {
        let c = [color.r, color.g, color.b, color.a]
        return size.isFinite && Self.sizeRange.contains(size)
            && c.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }

    /// Police à l'écran pour un zoom donné.
    func font(zoom: CGFloat) -> Font {
        .system(size: max(CGFloat(size) * zoom, 1), weight: bold ? .bold : .regular)
    }
}

extension TextStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextStyle()
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? d.bold
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? d.italic
        alignment = try c.decodeIfPresent(TextAlign.self, forKey: .alignment) ?? d.alignment
    }
}
