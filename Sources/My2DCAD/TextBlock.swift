import Foundation
import CoreGraphics

/// Bloc de texte d'une forme (équivalent de l'« Outil Bloc de texte » de Visio) :
/// position décalée et largeur personnalisable, indépendantes de la forme.
struct TextFrame {
    /// Point d'ancrage dans le monde : centre du bloc, haut du bloc (libellé sous une icône)
    /// ou bas du bloc (cote).
    var anchor: CGPoint
    /// Rectangle du bloc dans le repère du texte (origine = ancrage, axes tournés de `angle`).
    var local: CGRect
    var angle: CGFloat

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x + p.x * cos(angle) - p.y * sin(angle),
                y: anchor.y + p.x * sin(angle) + p.y * cos(angle))
    }

    func toLocal(_ w: CGPoint) -> CGPoint {
        let dx = w.x - anchor.x, dy = w.y - anchor.y
        return CGPoint(x: dx * cos(angle) + dy * sin(angle), y: -dx * sin(angle) + dy * cos(angle))
    }

    func contains(_ w: CGPoint, margin: CGFloat = 0) -> Bool {
        local.insetBy(dx: -margin, dy: -margin).contains(toLocal(w))
    }

    /// Coins du bloc dans le monde (pour l'affichage du cadre).
    var corners: [CGPoint] {
        [CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
         CGPoint(x: local.maxX, y: local.maxY), CGPoint(x: local.minX, y: local.maxY)].map(toWorld)
    }

    /// Poignée jaune de déplacement : coin supérieur gauche du bloc (à l'écart du centre de la forme,
    /// que l'on saisit pour déplacer la forme elle-même).
    var moveHandle: CGPoint { toWorld(CGPoint(x: local.minX, y: local.minY)) }

    /// Rectangle englobant le bloc dans le monde.
    var bounds: CGRect {
        let c = corners
        let xs = c.map(\.x), ys = c.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Poignées de largeur (milieu des côtés gauche et droit).
    var leftHandle: CGPoint { toWorld(CGPoint(x: local.minX, y: local.midY)) }
    var rightHandle: CGPoint { toWorld(CGPoint(x: local.maxX, y: local.midY)) }
}

extension Shape {
    static let textBlockWidthRange: ClosedRange<Double> = 10...100_000

    /// La largeur du bloc de texte est-elle réglable ? (pas pour les traits, courbes et cotes)
    var supportsTextBlockWidth: Bool { !kind.isPath }

    /// Largeur du bloc de texte, en unités du dessin (personnalisée ou automatique).
    var textBlockWidthValue: CGFloat {
        if let w = textBlockWidth { return CGFloat(w) }
        return kind.labelPlacement == .below ? max(rect.width * 2, 120) : max(rect.width - 8, 20)
    }

    /// Angle du repère du texte : celui de la forme, aucun pour un trait, celui de la ligne pour une cote.
    private var textAngle: CGFloat {
        if let l = dimensionLayout { return l.labelAngle }
        return kind.isPath ? 0 : angle
    }

    /// Bloc de texte pour un contenu donné (taille estimée d'après la police et le nombre de lignes).
    func textFrame(content: String) -> TextFrame {
        let size = CGFloat(textStyle.size)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = CGFloat(lines.map(\.count).max() ?? 1)
        let natural = longest * size * 0.55 + 6
        let width = kind.isPath ? natural : textBlockWidthValue
        // Retour à la ligne estimé quand le texte est plus large que le bloc.
        let wrapped = kind.isPath ? CGFloat(lines.count) : CGFloat(lines.count) + max(0, ceil(natural / max(width, 1)) - 1)
        let height = wrapped * size * 1.25 + 4
        let angle = textAngle
        let off = textOffset

        if let l = dimensionLayout {
            let mid = l.labelAnchor
            let base = CGPoint(x: off.x, y: off.y - 2)
            let anchor = CGPoint(x: mid.x + base.x * cos(angle) - base.y * sin(angle),
                                 y: mid.y + base.x * sin(angle) + base.y * cos(angle))
            return TextFrame(anchor: anchor, local: CGRect(x: -width / 2, y: -height, width: width, height: height), angle: angle)
        }
        if kind.isPath {
            let m = pathMidpoint
            return TextFrame(anchor: CGPoint(x: m.x + off.x, y: m.y + off.y),
                             local: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), angle: 0)
        }
        let below = kind.labelPlacement == .below
        let base = below ? CGPoint(x: rect.midX, y: rect.maxY + 4) : center
        let anchor = toWorld(CGPoint(x: base.x + off.x, y: base.y + off.y))
        let local = below ? CGRect(x: -width / 2, y: 0, width: width, height: height)
                          : CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        return TextFrame(anchor: anchor, local: local, angle: angle)
    }

    /// Le texte a-t-il été déplacé ou redimensionné ?
    var hasCustomTextBlock: Bool { textOffset != .zero || textBlockWidth != nil }
}

extension Diagram {
    /// Texte affiché par une forme (mesure automatique d'une cote, « Texte » pour un texte vide).
    func labelContent(_ s: Shape) -> String {
        if s.kind.isDimension, s.text.isEmpty { return dimensionMeasure(s) }
        if s.kind == .text && s.text.isEmpty { return "Texte" }
        return s.text
    }

    /// Bloc de texte d'une forme, s'il y a un texte à afficher.
    func textFrame(_ s: Shape) -> TextFrame? {
        let content = labelContent(s)
        return content.isEmpty ? nil : s.textFrame(content: content)
    }
}

@MainActor
extension DocumentStore {
    /// Remet le texte de la sélection à sa place et à sa largeur par défaut.
    func resetTextBlocks() {
        editSelection(key: "textReset-\(UUID())", shapes: { $0.textOffset = .zero; $0.textBlockWidth = nil })
    }
}
