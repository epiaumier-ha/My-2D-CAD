import Foundation
import CoreGraphics

// MARK: - Cotation (cotes dynamiques, comme la bibliothèque « Cotation » de Visio)
//
// Points stockés de chaque type de cote (coordonnées monde) :
// - linéaires (alignée, horizontale, verticale) : a, b (points mesurés), h (poignée de la ligne de cote) ;
// - angulaire : v (sommet), a et b (un point sur chaque branche), h (poignée de l'arc) ;
// - rayon et diamètre : c (centre), e (point du cercle).
// Les points mesurés peuvent être collés à des points d'autres formes (coins, milieux des côtés,
// centre, extrémités d'un trait) : la cote suit alors la forme et sa mesure se met à jour.

extension ShapeKind {
    /// Toutes les cotes (linéaires, angulaire, rayon, diamètre).
    var isDimension: Bool {
        switch self {
        case .dimension, .dimensionHorizontal, .dimensionVertical,
             .angularDimension, .radiusDimension, .diameterDimension:
            return true
        default:
            return false
        }
    }

    /// Indice du point de contrôle (poignée ronde, jamais collée) : point de contrôle d'une courbe,
    /// poignée de la ligne de cote ou de l'arc.
    var controlPointIndex: Int? {
        switch self {
        case .curve, .dimension, .dimensionHorizontal, .dimensionVertical: return self == .curve ? 1 : 2
        case .angularDimension: return 3
        default: return nil
        }
    }

    /// Points d'une cote qui peuvent être collés à une forme.
    var gluePointIndices: Range<Int> {
        switch self {
        case .dimension, .dimensionHorizontal, .dimensionVertical: return 0..<2
        case .angularDimension: return 0..<3
        case .radiusDimension, .diameterDimension: return 0..<2
        default: return 0..<0
        }
    }
}

/// Extrémité collée d'une cote : point `point` de la cote collé au point `anchor` de la forme `shape`.
struct GluePoint: Codable, Equatable {
    var point: Int
    var shape: UUID
    var anchor: Int

    /// Nombre maximal de points de collage d'une forme (validation des fichiers).
    static let maxAnchors = 16
}

// MARK: - Géométrie d'affichage

/// Tout ce qu'il faut pour dessiner une cote (coordonnées monde), quel que soit son type.
struct DimensionLayout {
    /// Lignes d'attache, déjà raccourcies côté forme et prolongées au-delà de la ligne de cote.
    var extensionLines: [(CGPoint, CGPoint)] = []
    /// Ligne de cote (polyligne ; l'arc d'une cote angulaire est échantillonné).
    var line: [CGPoint] = []
    /// Extrémités fléchées : pointe et point donnant la direction.
    var begin: (tip: CGPoint, from: CGPoint)?
    var end: (tip: CGPoint, from: CGPoint)?
    /// Mesure : longueur du dessin, ou angle en degrés pour une cote angulaire.
    var value: CGFloat = 0
    /// Position et angle (radians) du texte, placé au-dessus de la ligne de cote.
    var labelAnchor: CGPoint = .zero
    var labelAngle: CGFloat = 0
    /// Points dont l'enveloppe forme le cadre de la cote.
    var samples: [CGPoint] = []

    /// Jeu entre l'objet coté et la ligne d'attache, et dépassement au-delà de la ligne de cote.
    static let gap: CGFloat = 2
    static let overshoot: CGFloat = 4

    /// Distance d'un point au tracé de la cote (sélection au clic).
    func distance(to q: CGPoint) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for (a, b) in extensionLines { best = min(best, distanceFromPoint(q, toSegment: a, b)) }
        if line.count >= 2 {
            for i in 0..<(line.count - 1) { best = min(best, distanceFromPoint(q, toSegment: line[i], line[i + 1])) }
        }
        return best
    }
}

private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

/// Ligne d'attache de p (point coté) vers q (ligne de cote), ou nil si les deux sont confondus.
private func extensionLine(from p: CGPoint, to q: CGPoint) -> (CGPoint, CGPoint)? {
    let len = p.distance(to: q)
    guard len > 0.5 else { return nil }
    let ux = (q.x - p.x) / len, uy = (q.y - p.y) / len
    return (CGPoint(x: p.x + ux * DimensionLayout.gap, y: p.y + uy * DimensionLayout.gap),
            CGPoint(x: q.x + ux * DimensionLayout.overshoot, y: q.y + uy * DimensionLayout.overshoot))
}

/// Angle lisible (jamais à l'envers) d'un texte posé le long du segment a → b.
private func readableLabelAngle(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    a.distance(to: b) > 0.01 ? DiagramPainter.readableAngle(a, b) : 0
}

/// Angle signé de u vers v, dans ]-π, π].
private func signedAngle(from u: CGVector, to v: CGVector) -> CGFloat {
    var d = atan2(v.dy, v.dx) - atan2(u.dy, u.dx)
    if d > .pi { d -= 2 * .pi } else if d <= -.pi { d += 2 * .pi }
    return d
}

/// Géométrie d'affichage d'une cote à partir de ses points monde (nil si ce n'est pas une cote valide).
func makeDimensionLayout(kind: ShapeKind, points p: [CGPoint]) -> DimensionLayout? {
    guard kind.isDimension, p.count == kind.pointCount else { return nil }
    var l = DimensionLayout()
    switch kind {
    case .dimension, .dimensionHorizontal, .dimensionVertical:
        let a = p[0], b = p[1], h = p[2]
        let a2: CGPoint, b2: CGPoint
        switch kind {
        case .dimensionHorizontal:
            a2 = CGPoint(x: a.x, y: h.y); b2 = CGPoint(x: b.x, y: h.y)
            l.value = abs(b.x - a.x)
        case .dimensionVertical:
            a2 = CGPoint(x: h.x, y: a.y); b2 = CGPoint(x: h.x, y: b.y)
            l.value = abs(b.y - a.y)
        default:
            let g = dimensionGeometry(a, b, h)
            a2 = g.a2; b2 = g.b2
            l.value = g.length
        }
        l.extensionLines = [extensionLine(from: a, to: a2), extensionLine(from: b, to: b2)].compactMap { $0 }
        l.line = [a2, b2]
        l.begin = (a2, b2)
        l.end = (b2, a2)
        l.labelAnchor = mid(a2, b2)
        l.labelAngle = readableLabelAngle(a2, b2)
        l.samples = [a, a2, b2, b]

    case .angularDimension:
        let v = p[0], a = p[1], b = p[2]
        let u1 = CGVector(dx: a.x - v.x, dy: a.y - v.y), u2 = CGVector(dx: b.x - v.x, dy: b.y - v.y)
        let l1 = hypot(u1.dx, u1.dy), l2 = hypot(u2.dx, u2.dy)
        l.samples = [v, a, b]
        guard l1 > 0.01, l2 > 0.01 else {
            l.line = [a, v, b]
            l.labelAnchor = v
            return l
        }
        let t1 = atan2(u1.dy, u1.dx)
        let sweep = signedAngle(from: u1, to: u2)
        let r = max(v.distance(to: p[3]), 1)
        let steps = max(4, Int((abs(sweep) / (.pi / 36)).rounded(.up)))
        l.line = (0...steps).map { i in
            let t = t1 + sweep * CGFloat(i) / CGFloat(steps)
            return CGPoint(x: v.x + r * cos(t), y: v.y + r * sin(t))
        }
        // Lignes d'attache seulement si l'arc passe au-delà de l'extrémité de la branche.
        for (point, length, t) in [(a, l1, t1), (b, l2, t1 + sweep)] where r > length + 0.5 {
            if let e = extensionLine(from: point, to: CGPoint(x: v.x + r * cos(t), y: v.y + r * sin(t))) {
                l.extensionLines.append(e)
            }
        }
        // Flèches tangentes à l'arc, pointant vers l'extérieur de l'arc.
        let s: CGFloat = sweep >= 0 ? 1 : -1
        func tangent(_ t: CGFloat) -> CGVector { CGVector(dx: -sin(t) * s * 10, dy: cos(t) * s * 10) }
        if let first = l.line.first, let last = l.line.last {
            let ts = tangent(t1), te = tangent(t1 + sweep)
            l.begin = (first, CGPoint(x: first.x + ts.dx, y: first.y + ts.dy))
            l.end = (last, CGPoint(x: last.x - te.dx, y: last.y - te.dy))
        }
        l.value = abs(sweep) * 180 / .pi
        let tm = t1 + sweep / 2
        l.labelAnchor = CGPoint(x: v.x + r * cos(tm), y: v.y + r * sin(tm))
        let tg = tangent(tm)
        l.labelAngle = readableLabelAngle(l.labelAnchor, CGPoint(x: l.labelAnchor.x + tg.dx, y: l.labelAnchor.y + tg.dy))
        l.samples += l.line + l.extensionLines.flatMap { [$0.0, $0.1] }

    case .radiusDimension:
        let c = p[0], e = p[1]
        l.line = [c, e]
        l.begin = (c, e)
        l.end = (e, c)
        l.value = c.distance(to: e)
        l.labelAnchor = mid(c, e)
        l.labelAngle = readableLabelAngle(c, e)
        l.samples = [c, e]

    case .diameterDimension:
        let c = p[0], e = p[1]
        let a = CGPoint(x: 2 * c.x - e.x, y: 2 * c.y - e.y)
        l.line = [a, e]
        l.begin = (a, e)
        l.end = (e, a)
        l.value = 2 * c.distance(to: e)
        l.labelAnchor = c
        l.labelAngle = readableLabelAngle(a, e)
        l.samples = [a, e]

    default:
        return nil
    }
    return l
}

// MARK: - Édition des points

/// Poignée d'une cote angulaire : sur la bissectrice, à la distance r du sommet.
private func angularHandle(_ v: CGPoint, _ a: CGPoint, _ b: CGPoint, radius r: CGFloat) -> CGPoint {
    let u1 = CGVector(dx: a.x - v.x, dy: a.y - v.y), u2 = CGVector(dx: b.x - v.x, dy: b.y - v.y)
    let t = atan2(u1.dy, u1.dx) + signedAngle(from: u1, to: u2) / 2
    return CGPoint(x: v.x + r * cos(t), y: v.y + r * sin(t))
}

/// Remet la poignée d'une cote à sa place canonique (milieu de la ligne de cote, bissectrice de l'angle).
func normalizedDimensionPoints(kind: ShapeKind, _ p: [CGPoint]) -> [CGPoint] {
    guard p.count == kind.pointCount else { return p }
    var q = p
    switch kind {
    case .dimension:
        q = makeDimensionPoints(p[0], p[1], offset: dimensionGeometry(p[0], p[1], p[2]).offset)
    case .dimensionHorizontal:
        q[2] = CGPoint(x: (p[0].x + p[1].x) / 2, y: p[2].y)
    case .dimensionVertical:
        q[2] = CGPoint(x: p[2].x, y: (p[0].y + p[1].y) / 2)
    case .angularDimension:
        q[3] = angularHandle(p[0], p[1], p[2], radius: max(p[0].distance(to: p[3]), 4))
    default:
        break
    }
    return q
}

extension Shape {
    /// Géométrie d'affichage (nil si la forme n'est pas une cote).
    var dimensionLayout: DimensionLayout? {
        kind.isDimension ? makeDimensionLayout(kind: kind, points: worldPoints) : nil
    }

    /// Nouveaux points d'une cote quand l'utilisateur déplace la poignée `index` :
    /// la ligne de cote (ou le rayon de l'arc) garde sa position ; seule sa poignée la déplace.
    func dimensionPoints(moving index: Int, to q: CGPoint) -> [CGPoint] {
        var p = worldPoints
        guard kind.isDimension, p.count == kind.pointCount, p.indices.contains(index) else { return p }
        switch kind {
        case .dimension:
            guard let g = dimension else { return p }
            switch index {
            case 0: return makeDimensionPoints(q, p[1], offset: g.offset)
            case 1: return makeDimensionPoints(p[0], q, offset: g.offset)
            default: return makeDimensionPoints(p[0], p[1], offset: dimensionGeometry(p[0], p[1], q).offset)
            }
        case .angularDimension:
            var r = p[0].distance(to: p[3])
            if index == 3 { r = p[0].distance(to: q) } else { p[index] = q }
            return [p[0], p[1], p[2], angularHandle(p[0], p[1], p[2], radius: max(r, 4))]
        default:
            p[index] = q
            return normalizedDimensionPoints(kind: kind, p)
        }
    }

    /// Nouveaux points quand des points collés suivent leur forme : la ligne de cote garde
    /// son écart avec l'objet coté (elle se déplace avec lui).
    func dimensionPointsFollowing(_ updates: [Int: CGPoint]) -> [CGPoint] {
        let old = worldPoints
        guard kind.isDimension, old.count == kind.pointCount else { return old }
        var p = old
        for (i, q) in updates where p.indices.contains(i) { p[i] = q }
        switch kind {
        case .dimension:
            guard let g = dimension else { return p }
            return makeDimensionPoints(p[0], p[1], offset: g.offset)
        case .dimensionHorizontal, .dimensionVertical:
            // La ligne de cote suit le point coté qui en est le plus proche.
            let horizontal = kind == .dimensionHorizontal
            func coord(_ q: CGPoint) -> CGFloat { horizontal ? q.y : q.x }
            let near = abs(coord(old[0]) - coord(old[2])) <= abs(coord(old[1]) - coord(old[2])) ? 0 : 1
            let delta = coord(p[near]) - coord(old[near])
            p[2] = horizontal ? CGPoint(x: p[2].x, y: p[2].y + delta) : CGPoint(x: p[2].x + delta, y: p[2].y)
            return normalizedDimensionPoints(kind: kind, p)
        case .angularDimension:
            return [p[0], p[1], p[2], angularHandle(p[0], p[1], p[2], radius: max(old[0].distance(to: old[3]), 4))]
        default:
            return p
        }
    }

    /// Points de collage : 4 coins, 4 milieux des côtés et centre (rotation comprise) ;
    /// extrémités d'un trait ou d'une courbe ; aucun pour une cote.
    var glueAnchors: [CGPoint] {
        if kind.isDimension { return [] }
        if kind.isPath {
            let p = worldPoints
            guard let first = p.first, let last = p.last else { return [] }
            return [first, last]
        }
        let r = rect
        let local = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
            CGPoint(x: r.midX, y: r.midY),
        ]
        return local.map { toWorld($0) }
    }
}

/// Points initiaux d'une cote déposée depuis la bibliothèque, dans le cadre r.
func initialDimensionPoints(kind: ShapeKind, in r: CGRect) -> [CGPoint] {
    let c = CGPoint(x: r.midX, y: r.midY)
    let rad = min(r.width, r.height) / 2
    let edge = CGPoint(x: c.x + rad * cos(-.pi / 6), y: c.y + rad * sin(-.pi / 6))
    switch kind {
    case .dimensionHorizontal:
        return [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.minY)]
    case .dimensionVertical:
        return [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    case .angularDimension:
        let v = CGPoint(x: r.minX, y: r.maxY)
        let len = min(r.width, r.height)
        let a = CGPoint(x: r.maxX, y: r.maxY)
        let b = CGPoint(x: v.x + len * cos(-.pi / 3), y: v.y + len * sin(-.pi / 3))
        return [v, a, b, angularHandle(v, a, b, radius: len * 0.7)]
    case .radiusDimension, .diameterDimension:
        return [c, edge]
    default:
        return makeDimensionPoints(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY - r.height * 0.4),
                                   offset: r.height * 0.4)
    }
}

// MARK: - Mesure et collage dans la page

/// Point de collage trouvé près du pointeur.
struct GlueCandidate: Equatable {
    var shapeID: UUID
    var anchor: Int
    var point: CGPoint
}

extension Diagram {
    /// Écart toléré entre un point collé et son point de collage (au-delà, l'utilisateur l'a décollé).
    static let glueTolerance: CGFloat = 0.01

    /// Mesure d'une cote, dans l'unité et à l'échelle de la page : « 50,8 mm », « 45° », « R 12 mm », « Ø 24 mm ».
    func dimensionMeasure(_ s: Shape) -> String {
        guard let l = s.dimensionLayout else { return "" }
        switch s.kind {
        case .angularDimension: return Diagram.format(Double(l.value), decimals: min(precision, 2)) + "°"
        case .radiusDimension: return "R " + formatLength(l.value)
        case .diameterDimension: return "Ø " + formatLength(l.value)
        default: return formatLength(l.value)
        }
    }

    /// Point de collage le plus proche de q, sur une forme visible et non verrouillée (hors cotes).
    func nearestGlueAnchor(to q: CGPoint, tolerance: CGFloat, excluding id: UUID) -> GlueCandidate? {
        var best: GlueCandidate?
        var bestDistance = tolerance
        for s in shapes.reversed() where s.id != id && !s.kind.isDimension && isSelectable(s) {
            guard s.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(q) else { continue }
            for (i, p) in s.glueAnchors.enumerated() {
                let d = p.distance(to: q)
                if d < bestDistance {
                    bestDistance = d
                    best = GlueCandidate(shapeID: s.id, anchor: i, point: p)
                }
            }
        }
        return best
    }

    /// Recale les cotes collées sur leurs formes. `previous` est la page avant la modification :
    /// si l'utilisateur a lui-même déplacé une extrémité collée (sans sa forme), elle est décollée.
    mutating func resolveGlue(previous: Diagram?) {
        guard shapes.contains(where: { !$0.glue.isEmpty }) else { return }
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(shapes.count)
        for (i, s) in shapes.enumerated() { indexByID[s.id] = i }
        var before: [UUID: [CGPoint]] = [:]
        if let previous {
            for s in previous.shapes where !s.glue.isEmpty { before[s.id] = s.worldPoints }
        }
        for i in shapes.indices where !shapes[i].glue.isEmpty {
            var s = shapes[i]
            let pts = s.worldPoints
            guard s.kind.isDimension, pts.count == s.kind.pointCount else {
                shapes[i].glue = []
                continue
            }
            let edited = before[s.id].map { old in
                old.count != pts.count || zip(old, pts).contains { $0.distance(to: $1) > 1e-6 }
            } ?? false
            var kept: [GluePoint] = []
            var updates: [Int: CGPoint] = [:]
            for g in s.glue {
                guard s.kind.gluePointIndices.contains(g.point), !kept.contains(where: { $0.point == g.point }),
                      let ti = indexByID[g.shape], ti != i else { continue }
                let anchors = shapes[ti].glueAnchors
                guard anchors.indices.contains(g.anchor) else { continue }
                let target = anchors[g.anchor]
                let d = pts[g.point].distance(to: target)
                if edited && d > Self.glueTolerance { continue }
                kept.append(g)
                if d > 1e-9 { updates[g.point] = target }
            }
            if !updates.isEmpty { s.setWorldPoints(s.dimensionPointsFollowing(updates)) }
            s.glue = kept
            if s != shapes[i] { shapes[i] = s }
        }
    }
}

@MainActor
extension DocumentStore {
    /// Vrai si la sélection contient une cote collée.
    var selectionHasGlue: Bool {
        doc.shapes.contains { selection.contains($0.id) && !$0.glue.isEmpty }
    }

    /// Décolle les cotes sélectionnées (elles restent en place).
    func unglueSelection() {
        let ids = selection
        perform { d in
            for i in d.shapes.indices where ids.contains(d.shapes[i].id) && !d.shapes[i].glue.isEmpty {
                d.shapes[i].glue = []
            }
        }
    }
}
