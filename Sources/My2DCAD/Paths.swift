import Foundation
import CoreGraphics

extension ShapeKind {
    /// Trait ou courbe : défini par des points plutôt que par un rectangle.
    var isPath: Bool { self == .line || self == .curve }
}

/// Point d'une courbe de Bézier quadratique (début a, contrôle c, fin b) pour t ∈ [0, 1].
func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                   y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
}

/// Polyligne approchant le tracé (2 points pour un trait, 33 pour une courbe).
func pathSamples(kind: ShapeKind, points p: [CGPoint]) -> [CGPoint] {
    switch kind {
    case .line where p.count == 2:
        return p
    case .curve where p.count == 3:
        return (0...32).map { quadPoint(p[0], p[1], p[2], CGFloat($0) / 32) }
    default:
        return []
    }
}

extension Shape {
    /// Points dans le monde (rotation comprise).
    var worldPoints: [CGPoint] {
        points.map { toWorld(CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y)) }
    }

    /// Remplace les points (coordonnées monde) et recalcule le rectangle englobant du tracé.
    /// La rotation éventuelle est intégrée aux points.
    mutating func setWorldPoints(_ world: [CGPoint]) {
        rotation = 0
        let samples = pathSamples(kind: kind, points: world)
        let all = samples.isEmpty ? world : samples
        guard let first = all.first else { return }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in all {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        rect = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        points = world.map { CGPoint(x: $0.x - minX, y: $0.y - minY) }
    }

    var pathSamplesInWorld: [CGPoint] { pathSamples(kind: kind, points: worldPoints) }

    /// Milieu du tracé (position du libellé).
    var pathMidpoint: CGPoint {
        let p = worldPoints
        if kind == .curve, p.count == 3 { return quadPoint(p[0], p[1], p[2], 0.5) }
        if p.count >= 2 { return CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2) }
        return center
    }

    func distanceToPath(_ q: CGPoint) -> CGFloat {
        let s = pathSamplesInWorld
        guard s.count >= 2 else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<(s.count - 1) { best = min(best, distanceFromPoint(q, toSegment: s[i], s[i + 1])) }
        return best
    }
}

@MainActor
extension DocumentStore {
    static let defaultLineColor = RGBA(r: 0.2, g: 0.2, b: 0.2, a: 1)

    /// Points d'une nouvelle forme : trait direct, ou courbe dont le point de contrôle
    /// est décalé perpendiculairement (à ajuster ensuite avec sa poignée).
    static func initialPathPoints(kind: ShapeKind, from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        guard kind == .curve else { return [a, b] }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let control = CGPoint(x: mid.x - (b.y - a.y) * 0.25, y: mid.y + (b.x - a.x) * 0.25)
        return [a, control, b]
    }

    /// Ajout direct (à utiliser à l'intérieur d'une transaction, comme insertShape).
    func insertPath(kind: ShapeKind, from a: CGPoint, to b: CGPoint) {
        guard kind.isPath, doc.shapes.count < DiagramIO.maxShapes else { return }
        var s = Shape(kind: kind, rect: .zero, fill: Self.defaultLineColor, line: .pathDefault)
        s.setWorldPoints(Self.initialPathPoints(kind: kind, from: a, to: b))
        s.layerID = doc.activeLayerID
        doc.shapes.append(s)
        selection = [s.id]
    }
}
