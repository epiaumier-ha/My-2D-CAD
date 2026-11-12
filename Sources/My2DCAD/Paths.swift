import Foundation
import CoreGraphics
import SwiftUI

extension ShapeKind {
    /// Trait, courbe ou cote : défini par des points plutôt que par un rectangle.
    var isPath: Bool { self == .line || self == .curve || isDimension }

    /// Nombre de points attendus (trait, rayon et diamètre 2 ; cote angulaire 4 ; courbe et cotes linéaires 3).
    var pointCount: Int {
        switch self {
        case .line, .radiusDimension, .diameterDimension: return 2
        case .angularDimension: return 4
        default: return 3
        }
    }
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
        return kind.isDimension ? (makeDimensionLayout(kind: kind, points: p)?.samples ?? []) : []
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
        if let l = dimensionLayout { return l.labelAnchor }
        if p.count >= 2 { return CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2) }
        return center
    }

    func distanceToPath(_ q: CGPoint) -> CGFloat {
        if let l = dimensionLayout { return l.distance(to: q) }
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
        if kind == .dimension { return makeDimensionPoints(a, b, offset: 24) }
        guard kind == .curve else { return [a, b] }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let control = CGPoint(x: mid.x - (b.y - a.y) * 0.25, y: mid.y + (b.x - a.x) * 0.25)
        return [a, control, b]
    }

    /// Ajout direct (à utiliser à l'intérieur d'une transaction, comme insertShape).
    func insertPath(kind: ShapeKind, from a: CGPoint, to b: CGPoint) {
        guard kind.isPath, doc.shapes.count < DiagramIO.maxShapes else { return }
        var s = Shape(kind: kind, rect: .zero, fill: Self.defaultLineColor,
                      line: kind.isDimension ? .dimensionDefault : .pathDefault)
        var points = Self.initialPathPoints(kind: kind, from: a, to: b)
        if kind.isDimension {
            // Cote tracée d'un point de collage à l'autre (coin, milieu, centre) : elle est collée.
            for i in kind.gluePointIndices {
                guard let hit = doc.nearestGlueAnchor(to: points[i], tolerance: 8 / zoom, excluding: s.id) else { continue }
                points[i] = hit.point
                s.glue.append(GluePoint(point: i, shape: hit.shapeID, anchor: hit.anchor))
            }
            points = normalizedDimensionPoints(kind: kind, points)
        }
        s.setWorldPoints(points)
        s.layerID = doc.activeLayerID
        doc.shapes.append(s)
        selection = [s.id]
    }
}

// MARK: - Cotes

/// Géométrie d'une cote : points mesurés a et b, ligne de cote a2–b2 décalée parallèlement,
/// `offset` = distance signée entre la ligne mesurée et la ligne de cote.
struct DimensionGeometry {
    var a, b, a2, b2: CGPoint
    var offset: CGFloat
    var length: CGFloat { hypot(b.x - a.x, b.y - a.y) }
}

/// Normale unitaire (à gauche du sens a → b, vers le haut pour une cote horizontale).
private func dimensionNormal(_ a: CGPoint, _ b: CGPoint) -> CGVector {
    let len = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
    return CGVector(dx: (b.y - a.y) / len, dy: -(b.x - a.x) / len)
}

/// Calcule la cote à partir des points stockés : a, b et le point de décalage p.
func dimensionGeometry(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> DimensionGeometry {
    let n = dimensionNormal(a, b)
    let d = (p.x - a.x) * n.dx + (p.y - a.y) * n.dy
    return DimensionGeometry(a: a, b: b,
                             a2: CGPoint(x: a.x + n.dx * d, y: a.y + n.dy * d),
                             b2: CGPoint(x: b.x + n.dx * d, y: b.y + n.dy * d),
                             offset: d)
}

/// Points stockés d'une cote : a, b et le milieu de la ligne de cote (poignée de décalage).
func makeDimensionPoints(_ a: CGPoint, _ b: CGPoint, offset d: CGFloat) -> [CGPoint] {
    let n = dimensionNormal(a, b)
    return [a, b, CGPoint(x: (a.x + b.x) / 2 + n.dx * d, y: (a.y + b.y) / 2 + n.dy * d)]
}

extension Shape {
    /// Géométrie de la cote (nil si la forme n'est pas une cote).
    var dimension: DimensionGeometry? {
        guard kind == .dimension else { return nil }
        let p = worldPoints
        guard p.count == 3 else { return nil }
        return dimensionGeometry(p[0], p[1], p[2])
    }
}

// MARK: - Formes libres

/// Élément du tracé d'une forme libre (coordonnées relatives au rectangle : 0…1).
enum PathSegment: Codable, Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, control: CGPoint)
    case cubic(CGPoint, control1: CGPoint, control2: CGPoint)
    case close

    var points: [CGPoint] {
        switch self {
        case .move(let p), .line(let p): return [p]
        case .quad(let p, let c): return [p, c]
        case .cubic(let p, let c1, let c2): return [p, c1, c2]
        case .close: return []
        }
    }
}

extension Shape {
    static let maxSegments = 20_000

    /// Forme libre à partir d'un tracé en coordonnées monde (nil si le tracé est vide).
    static func freeform(from path: Path) -> Shape? {
        let box = path.cgPath.boundingBoxOfPath
        guard !path.isEmpty, box.minX.isFinite, box.minY.isFinite else { return nil }
        let w = max(box.width, 1), h = max(box.height, 1)
        func n(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - box.minX) / w, y: (p.y - box.minY) / h) }
        var segments: [PathSegment] = []
        path.forEach { e in
            guard segments.count < maxSegments else { return }
            switch e {
            case .move(let p): segments.append(.move(n(p)))
            case .line(let p): segments.append(.line(n(p)))
            case .quadCurve(let p, let c): segments.append(.quad(n(p), control: n(c)))
            case .curve(let p, let c1, let c2): segments.append(.cubic(n(p), control1: n(c1), control2: n(c2)))
            case .closeSubpath: segments.append(.close)
            }
        }
        var s = Shape(kind: .freeform, rect: CGRect(x: box.minX, y: box.minY, width: w, height: h))
        s.segments = segments
        return s
    }

    /// Tracé de la forme dans le rectangle `r` (formes libres : leur tracé, sinon le tracé du type).
    func paths(in r: CGRect) -> ShapePaths {
        guard kind == .freeform, !segments.isEmpty else { return kind.paths(in: r) }
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height) }
        var path = Path()
        for seg in segments {
            switch seg {
            case .move(let p): path.move(to: m(p))
            case .line(let p): path.addLine(to: m(p))
            case .quad(let p, let c): path.addQuadCurve(to: m(p), control: m(c))
            case .cubic(let p, let c1, let c2): path.addCurve(to: m(p), control1: m(c1), control2: m(c2))
            case .close: path.closeSubpath()
            }
        }
        return ShapePaths(fill: path)
    }
}
