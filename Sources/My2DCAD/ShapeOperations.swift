import SwiftUI
import CoreGraphics

// MARK: - Opérations sur les formes (menu Développeur > Opérations de Visio)
//
// Union, Combiner, Fragmenter, Intersection et Soustraire travaillent sur les surfaces des formes
// (opérations booléennes de Core Graphics). Joindre, Rogner, Décalage et Ajuster la courbe
// travaillent sur leurs tracés. Le résultat prend le format de la forme principale : la première
// sélectionnée. Toutes les opérations remplacent les formes d'origine, sauf Décalage qui les garde.

enum ShapeOperation: String, CaseIterable, Identifiable {
    case union, combine, fragment, intersect, subtract, join, trim, offset, fitCurve

    var id: String { rawValue }

    var label: String {
        switch self {
        case .union: return "Union"
        case .combine: return "Combiner"
        case .fragment: return "Fragmenter"
        case .intersect: return "Intersection"
        case .subtract: return "Soustraire"
        case .join: return "Joindre"
        case .trim: return "Rogner"
        case .offset: return "Décalage"
        case .fitCurve: return "Ajuster la courbe"
        }
    }

    var symbol: String {
        switch self {
        case .union: return "square.on.square.squareshape.controlhandles"
        case .combine: return "circle.lefthalf.filled"
        case .fragment: return "square.split.diagonal.2x2"
        case .intersect: return "square.on.square.intersection.dashed"
        case .subtract: return "minus.square"
        case .join: return "point.topleft.down.to.point.bottomright.curvepath"
        case .trim: return "scissors"
        case .offset: return "square.dashed"
        case .fitCurve: return "scribble.variable"
        }
    }

    var help: String {
        switch self {
        case .union: return "Fusionne les formes selon leur contour extérieur"
        case .combine: return "Réunit les formes en évidant les zones de chevauchement"
        case .fragment: return "Découpe les formes en morceaux le long de leurs intersections"
        case .intersect: return "Ne garde que la zone commune à toutes les formes"
        case .subtract: return "Retire les autres formes de la première sélectionnée"
        case .join: return "Assemble les traits bout à bout en une seule forme"
        case .trim: return "Coupe les tracés à chaque intersection"
        case .offset: return "Ajoute des contours parallèles à la distance choisie, du côté choisi pour les formes et les traits (l'original est gardé)"
        case .fitCurve: return "Remplace les segments par des courbes lissées"
        }
    }

    /// Opération sur les surfaces (formes fermées) plutôt que sur les tracés.
    var usesRegions: Bool { [.union, .combine, .fragment, .intersect, .subtract].contains(self) }

    /// Nombre minimal de formes à sélectionner.
    var minimumCount: Int { [.offset, .fitCurve].contains(self) ? 1 : 2 }
}

enum ShapeOperationError: LocalizedError, Equatable {
    case needShapes(Int, regions: Bool)
    case emptyResult
    case tooComplex
    case nothingToDo

    var errorDescription: String? {
        switch self {
        case .needShapes(let n, let regions):
            let kind = regions ? "formes fermées (rectangles, ellipses, formes libres…)" : "formes ou traits"
            return n == 1 ? "Sélectionnez au moins une forme." : "Sélectionnez au moins \(n) \(kind)."
        case .emptyResult: return "Le résultat est vide : les formes ne se chevauchent pas."
        case .tooComplex: return "Le résultat est trop complexe."
        case .nothingToDo: return "Les formes sélectionnées ne se croisent pas : rien à modifier."
        }
    }
}

// MARK: - Tracés en coordonnées monde

extension Shape {
    /// Rotation de la forme autour de son centre (repère local → monde).
    var worldTransform: CGAffineTransform {
        guard rotation != 0 else { return .identity }
        let c = center
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y)
    }

    /// Surface de la forme (rotation comprise), normalisée ; nil si elle n'en a pas (trait, texte, cote).
    var worldRegion: CGPath? {
        guard !kind.isPath, kind != .text else { return nil }
        let fill = paths(in: rect).fill
        guard !fill.isEmpty else { return nil }
        let region = fill.applying(worldTransform).cgPath.normalized(using: evenOdd ? .evenOdd : .winding)
        return region.isEmpty ? nil : region
    }

    /// Tracé de la forme (contour, trait ou courbe), rotation comprise ; nil pour un texte ou une cote.
    var worldGeometry: Path? {
        guard kind != .text, !kind.isDimension else { return nil }
        var path = Path()
        let p = worldPoints
        switch kind {
        case .line where p.count == 2:
            path.move(to: p[0])
            path.addLine(to: p[1])
        case .curve where p.count == 3:
            path.move(to: p[0])
            path.addQuadCurve(to: p[2], control: p[1])
        default:
            let parts = paths(in: rect)
            path.addPath(parts.fill)
            path.addPath(parts.stroke)
            path = path.applying(worldTransform)
        }
        return path.isEmpty ? nil : path
    }
}

/// Élément d'un sous-tracé (coordonnées monde).
enum ContourSegment: Equatable {
    case line(CGPoint)
    case quad(CGPoint, control: CGPoint)
    case cubic(CGPoint, control1: CGPoint, control2: CGPoint)

    var end: CGPoint {
        switch self {
        case .line(let p), .quad(let p, _), .cubic(let p, _, _): return p
        }
    }
}

/// Sous-tracé continu : point de départ, segments, fermé ou non.
struct Contour: Equatable {
    var start: CGPoint
    var segments: [ContourSegment] = []
    var closed = false

    var end: CGPoint { segments.last?.end ?? start }

    /// Même tracé parcouru dans l'autre sens.
    func reversed() -> Contour {
        var out = Contour(start: end, closed: closed)
        var from = start
        var starts: [CGPoint] = []
        for seg in segments { starts.append(from); from = seg.end }
        for (seg, p) in zip(segments, starts).reversed() {
            switch seg {
            case .line: out.segments.append(.line(p))
            case .quad(_, let c): out.segments.append(.quad(p, control: c))
            case .cubic(_, let c1, let c2): out.segments.append(.cubic(p, control1: c2, control2: c1))
            }
        }
        return out
    }

    func add(to path: inout Path) {
        path.move(to: start)
        for seg in segments {
            switch seg {
            case .line(let p): path.addLine(to: p)
            case .quad(let p, let c): path.addQuadCurve(to: p, control: c)
            case .cubic(let p, let c1, let c2): path.addCurve(to: p, control1: c1, control2: c2)
            }
        }
        if closed { path.closeSubpath() }
    }

    /// Polyligne approchant le tracé (16 points par courbe) ; fermée : le dernier point répète le premier.
    var polyline: [CGPoint] {
        var pts = [start]
        var from = start
        for seg in segments {
            switch seg {
            case .line(let p):
                pts.append(p)
            case .quad(let p, let c):
                pts += (1...16).map { quadPoint(from, c, p, CGFloat($0) / 16) }
            case .cubic(let p, let c1, let c2):
                pts += (1...16).map { i -> CGPoint in
                    let t = CGFloat(i) / 16, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    return CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * p.x,
                                   y: a * from.y + b * c1.y + c * c2.y + d * p.y)
                }
            }
            from = seg.end
        }
        if closed, let first = pts.first, pts.last.map({ $0.distance(to: first) > 1e-9 }) ?? false { pts.append(first) }
        return pts
    }
}

/// Sous-tracés d'un tracé ; un sous-tracé fermé reçoit un segment de fermeture explicite.
func contours(of path: Path) -> [Contour] {
    var out: [Contour] = []
    var current: Contour?
    func flush() {
        if let c = current, !c.segments.isEmpty { out.append(c) }
        current = nil
    }
    path.forEach { e in
        switch e {
        case .move(let p):
            flush()
            current = Contour(start: p)
        case .line(let p):
            if current == nil { current = Contour(start: p) } else { current?.segments.append(.line(p)) }
        case .quadCurve(let p, let c):
            if current == nil { current = Contour(start: p) } else { current?.segments.append(.quad(p, control: c)) }
        case .curve(let p, let c1, let c2):
            if current == nil { current = Contour(start: p) } else {
                current?.segments.append(.cubic(p, control1: c1, control2: c2))
            }
        case .closeSubpath:
            if var c = current, !c.segments.isEmpty {
                if c.end.distance(to: c.start) > 1e-9 { c.segments.append(.line(c.start)) }
                c.closed = true
                out.append(c)
                // Un tracé qui continue après la fermeture repart du point de départ.
                current = Contour(start: c.start)
            }
        }
    }
    flush()
    return out
}

// MARK: - Algorithmes sur les tracés

/// Point d'intersection de deux segments (paramètres dans [0, 1]), ou nil.
private func segmentIntersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> (t: CGFloat, u: CGFloat)? {
    let r = CGVector(dx: b.x - a.x, dy: b.y - a.y), s = CGVector(dx: d.x - c.x, dy: d.y - c.y)
    let den = r.dx * s.dy - r.dy * s.dx
    guard abs(den) > 1e-12 else { return nil }
    let qx = c.x - a.x, qy = c.y - a.y
    let t = (qx * s.dy - qy * s.dx) / den
    let u = (qx * r.dy - qy * r.dx) / den
    guard t >= -1e-9, t <= 1 + 1e-9, u >= -1e-9, u <= 1 + 1e-9 else { return nil }
    return (min(max(t, 0), 1), min(max(u, 0), 1))
}

private func polylineBounds(_ p: [CGPoint]) -> CGRect {
    guard let f = p.first else { return .null }
    var r = CGRect(origin: f, size: .zero)
    for q in p.dropFirst() { r = r.union(CGRect(origin: q, size: .zero)) }
    return r
}

/// Simplification de Douglas-Peucker (garde les extrémités).
func simplifyPolyline(_ p: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
    guard p.count > 2 else { return p }
    var keep = [Bool](repeating: false, count: p.count)
    keep[0] = true
    keep[p.count - 1] = true
    var stack = [(0, p.count - 1)]
    while let (i, j) = stack.popLast() {
        guard j > i + 1 else { continue }
        var best = -1, bestDistance: CGFloat = 0
        for k in (i + 1)..<j {
            let d = distanceFromPoint(p[k], toSegment: p[i], p[j])
            if d > bestDistance { bestDistance = d; best = k }
        }
        if bestDistance > tolerance, best > 0 {
            keep[best] = true
            stack.append((i, best))
            stack.append((best, j))
        }
    }
    return p.indices.filter { keep[$0] }.map { p[$0] }
}

/// Courbe lissée (Catmull-Rom convertie en Bézier cubiques) passant par les points.
func smoothContour(through p: [CGPoint], closed: Bool) -> Contour {
    var c = Contour(start: p[0], closed: closed)
    let n = p.count
    guard n >= 2 else { return c }
    func at(_ i: Int) -> CGPoint {
        if closed { return p[(i % n + n) % n] }
        return p[min(max(i, 0), n - 1)]
    }
    let count = closed ? n : n - 1
    for i in 0..<count {
        let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        c.segments.append(.cubic(p2, control1: c1, control2: c2))
    }
    return c
}

/// Coupe des polylignes à chacune de leurs intersections avec les polylignes d'autres propriétaires.
/// Renvoie, pour chaque polyligne, ses morceaux (nil si elle n'est pas coupée).
func trimPolylines(_ lines: [(points: [CGPoint], closed: Bool, owner: Int)]) -> [[[CGPoint]]?] {
    let boxes = lines.map { polylineBounds($0.points).insetBy(dx: -0.01, dy: -0.01) }
    return lines.indices.map { i -> [[CGPoint]]? in
        let a = lines[i].points
        guard a.count >= 2 else { return nil }
        // Paramètres de coupe le long de la polyligne (indice du segment + position dans le segment).
        var cuts: [CGFloat] = []
        for j in lines.indices where lines[j].owner != lines[i].owner && boxes[i].intersects(boxes[j]) {
            let b = lines[j].points
            guard b.count >= 2 else { continue }
            for k in 0..<(a.count - 1) {
                let sa = polylineBounds([a[k], a[k + 1]]).insetBy(dx: -0.01, dy: -0.01)
                guard sa.intersects(boxes[j]) else { continue }
                for m in 0..<(b.count - 1) {
                    guard sa.intersects(polylineBounds([b[m], b[m + 1]]).insetBy(dx: -0.01, dy: -0.01)),
                          let hit = segmentIntersection(a[k], a[k + 1], b[m], b[m + 1]) else { continue }
                    cuts.append(CGFloat(k) + hit.t)
                }
            }
        }
        let last = CGFloat(a.count - 1)
        func point(_ t: CGFloat) -> CGPoint {
            let k = min(Int(t), a.count - 2), f = t - CGFloat(k)
            return CGPoint(x: a[k].x + (a[k + 1].x - a[k].x) * f, y: a[k].y + (a[k + 1].y - a[k].y) * f)
        }
        // Coupes distinctes ; celles d'une polyligne ouverte situées aux extrémités ne coupent rien.
        var sorted: [CGFloat] = []
        for t in cuts.sorted() where sorted.last.map({ point(t).distance(to: point($0)) > 1e-6 }) ?? true {
            sorted.append(t)
        }
        if lines[i].closed, sorted.count > 1, point(sorted[0]).distance(to: point(sorted[sorted.count - 1])) <= 1e-6 {
            sorted.removeLast()
        }
        if !lines[i].closed {
            sorted = sorted.filter { point($0).distance(to: a[0]) > 1e-6 && point($0).distance(to: a[a.count - 1]) > 1e-6 }
        }
        guard !sorted.isEmpty else { return nil }

        /// Morceau entre deux paramètres ; pour une polyligne fermée, `to` peut dépasser la fin (tour complet).
        func piece(from: CGFloat, to: CGFloat) -> [CGPoint] {
            var pts = [point(from)]
            var k = Int(from.rounded(.down)) + 1
            while CGFloat(k) < to - 1e-9 {
                pts.append(a[k % (a.count - 1)])
                k += 1
            }
            let end = to > last ? to - last : to
            pts.append(point(end))
            return pts
        }
        var pieces: [[CGPoint]] = []
        if lines[i].closed {
            for (n, t) in sorted.enumerated() {
                let next = n + 1 < sorted.count ? sorted[n + 1] : sorted[0] + last
                pieces.append(piece(from: t, to: next))
            }
        } else {
            let bounds = [0] + sorted + [last]
            for n in 0..<(bounds.count - 1) { pieces.append(piece(from: bounds[n], to: bounds[n + 1])) }
        }
        return pieces.filter { p in zip(p, p.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } > 1e-3 }
    }
}

/// Assemble des sous-tracés bout à bout (extrémités distantes d'au plus `tolerance`).
func joinContours(_ input: [Contour], tolerance: CGFloat) -> [Contour] {
    var open = input.filter { !$0.closed }
    var out = input.filter(\.closed)
    while !open.isEmpty {
        var chain = open.removeFirst()
        var grew = true
        while grew && !chain.closed {
            grew = false
            for (i, c) in open.enumerated() {
                if chain.end.distance(to: c.start) <= tolerance {
                    chain.segments += c.segments
                } else if chain.end.distance(to: c.end) <= tolerance {
                    chain.segments += c.reversed().segments
                } else if chain.start.distance(to: c.end) <= tolerance {
                    var joined = c
                    joined.segments += chain.segments
                    chain = joined
                } else if chain.start.distance(to: c.start) <= tolerance {
                    var joined = c.reversed()
                    joined.segments += chain.segments
                    chain = joined
                } else {
                    continue
                }
                open.remove(at: i)
                grew = true
                break
            }
            if chain.segments.count > 1, chain.end.distance(to: chain.start) <= tolerance {
                chain.closed = true
            }
        }
        out.append(chain)
    }
    return out
}

// MARK: - Exécution dans le document

@MainActor
extension DocumentStore {
    /// Formes concernées, dans l'ordre de sélection (la première est la forme principale).
    func operationShapes(for op: ShapeOperation) -> [Shape] {
        let d = doc
        var byID: [UUID: Shape] = [:]
        for s in d.shapes where selection.contains(s.id) && d.isSelectable(s) { byID[s.id] = s }
        return selectionOrder.compactMap { byID[$0] }.filter {
            op.usesRegions ? $0.worldRegion != nil : $0.worldGeometry != nil
        }
    }

    func canApply(_ op: ShapeOperation) -> Bool {
        operationShapes(for: op).count >= op.minimumCount
    }

    /// Lance une opération depuis un menu ou un bouton ; un échec est signalé par une alerte.
    func runOperation(_ op: ShapeOperation) {
        endTextEditing()
        do {
            try applyOperation(op)
        } catch {
            showError("Opération « \(op.label) » impossible", error)
        }
    }

    /// Applique l'opération à la sélection (une seule étape d'annulation).
    func applyOperation(_ op: ShapeOperation) throws {
        let shapes = operationShapes(for: op)
        guard shapes.count >= op.minimumCount, let primary = shapes.first else {
            throw ShapeOperationError.needShapes(op.minimumCount, regions: op.usesRegions)
        }
        var results: [Shape] = []
        var consumed = Set(shapes.map(\.id))

        switch op {
        case .union, .combine, .intersect, .subtract:
            let regions = shapes.compactMap(\.worldRegion)
            var result = regions[0]
            for r in regions.dropFirst() {
                switch op {
                case .union: result = result.union(r)
                case .combine: result = result.symmetricDifference(r)
                case .intersect: result = result.intersection(r)
                default: break
                }
            }
            if op == .subtract {
                let others = regions.dropFirst().dropFirst().reduce(regions[1]) { $0.union($1) }
                result = regions[0].subtracting(others)
            }
            results = [try makeResult(result, like: primary, region: true, keepText: true)]

        case .fragment:
            var pieces: [CGPath] = []
            for region in shapes.compactMap(\.worldRegion) {
                var next: [CGPath] = []
                var rest = region
                for p in pieces {
                    next.append(p.intersection(region))
                    next.append(p.subtracting(region))
                    rest = rest.subtracting(p)
                }
                next.append(rest)
                pieces = next.filter { !$0.isEmpty }
                guard pieces.count <= 2_000 else { throw ShapeOperationError.tooComplex }
            }
            let parts = pieces.flatMap { $0.componentsSeparated() }.filter {
                let b = $0.boundingBoxOfPath
                return !$0.isEmpty && b.width > 0.01 && b.height > 0.01
            }
            guard parts.count <= 2_000 else { throw ShapeOperationError.tooComplex }
            results = try parts.map { try makeResult($0, like: primary, region: true, keepText: false) }

        case .join:
            let all = shapes.flatMap { contours(of: $0.worldGeometry ?? Path()) }
            var path = Path()
            let joined = joinContours(all, tolerance: 0.5)
            for c in joined { c.add(to: &path) }
            results = [try makeResult(path.cgPath, like: primary, region: joined.allSatisfy(\.closed), keepText: true)]

        case .trim:
            var lines: [(points: [CGPoint], closed: Bool, owner: Int)] = []
            var sources: [(shape: Int, contour: Contour)] = []
            for (n, s) in shapes.enumerated() {
                for c in contours(of: s.worldGeometry ?? Path()) {
                    lines.append((c.polyline, c.closed, n))
                    sources.append((n, c))
                }
            }
            guard lines.reduce(0, { $0 + $1.points.count }) <= 20_000 else { throw ShapeOperationError.tooComplex }
            let cut = trimPolylines(lines)
            let touched = Set(cut.indices.filter { cut[$0] != nil }.map { sources[$0].shape })
            guard !touched.isEmpty else { throw ShapeOperationError.nothingToDo }
            consumed = Set(touched.map { shapes[$0].id })
            for (i, pieces) in cut.enumerated() where touched.contains(sources[i].shape) {
                let source = shapes[sources[i].shape]
                if let pieces {
                    for p in pieces {
                        var path = Path()
                        path.addLines(p)
                        results.append(try makeResult(path.cgPath, like: source, region: false, keepText: false))
                    }
                } else {
                    var path = Path()
                    sources[i].contour.add(to: &path)
                    results.append(try makeResult(path.cgPath, like: source, region: sources[i].contour.closed,
                                                  keepText: false))
                }
            }
            guard results.count <= 2_000 else { throw ShapeOperationError.tooComplex }

        case .offset:
            // Formes fermées : vers l'extérieur, l'intérieur ou les deux ; traits : côté choisi ou deux parallèles.
            let d = max(offsetDistance, 0.01)
            consumed = []
            for s in shapes {
                guard let path = try OffsetGeometry.offset(s, distance: d, side: offsetSide,
                                                           direction: lineOffsetDirection) else { continue }
                results.append(try makeResult(path, like: s, region: false, keepText: false, closedOutline: true))
            }
            if results.isEmpty && offsetSide == .inside { throw OffsetError.insideTooLarge }

        case .fitCurve:
            let tolerance: CGFloat = 1.5
            for s in shapes {
                var path = Path()
                for c in contours(of: s.worldGeometry ?? Path()) {
                    var pts = c.polyline
                    if c.closed, pts.count > 1 { pts.removeLast() }
                    var simple = c.closed ? simplifyPolyline(pts + [pts[0]], tolerance: tolerance).dropLast().map { $0 }
                                          : simplifyPolyline(pts, tolerance: tolerance)
                    if c.closed && simple.count < 3 { simple = pts }
                    guard simple.count >= 2 else { continue }
                    if !c.closed && simple.count == 2 {
                        Contour(start: simple[0], segments: [.line(simple[1])]).add(to: &path)
                    } else {
                        smoothContour(through: simple, closed: c.closed).add(to: &path)
                    }
                }
                let closed = contours(of: path).allSatisfy(\.closed) && !s.kind.isPath
                results.append(try makeResult(path.cgPath, like: s, region: closed, keepText: true))
            }
        }

        guard !results.isEmpty else { throw ShapeOperationError.emptyResult }
        let ids = consumed
        let added = results
        perform { d in
            let insertAt = d.shapes.firstIndex { ids.contains($0.id) } ?? d.shapes.count
            d.removeItems(ids)
            d.shapes.insert(contentsOf: added, at: min(insertAt, d.shapes.count))
        }
        selection = Set(added.map(\.id))
    }

    /// Forme libre résultat, au format de la forme `like`.
    /// - region : surface fermée (remplie comme l'original) ; sinon tracé seul, sans remplissage.
    /// - closedOutline : contour fermé non rempli (décalage).
    private func makeResult(_ path: CGPath, like source: Shape, region: Bool, keepText: Bool,
                            closedOutline: Bool = false) throws -> Shape {
        guard !path.isEmpty else { throw ShapeOperationError.emptyResult }
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        guard count <= Shape.maxSegments else { throw ShapeOperationError.tooComplex }
        let box = path.boundingBoxOfPath
        guard box.minX.isFinite, box.minY.isFinite, abs(box.minX) <= DiagramIO.maxCoordinate,
              abs(box.maxX) <= DiagramIO.maxCoordinate, abs(box.minY) <= DiagramIO.maxCoordinate,
              abs(box.maxY) <= DiagramIO.maxCoordinate,
              var s = Shape.freeform(from: Path(path)) else { throw ShapeOperationError.emptyResult }
        s.line = source.line
        s.line.beginArrow = .none
        s.line.endArrow = .none
        if source.kind.isPath {
            // Trait ou courbe : la ligne garde sa couleur ; une surface fermée reçoit le remplissage par défaut.
            s.fill = .defaultFill
            s.noFill = !region
        } else {
            s.fill = source.fill
            s.noFill = region ? source.noFill : true
            s.fillTransparency = source.fillTransparency
        }
        if closedOutline { s.noFill = true }
        s.evenOdd = true
        s.textStyle = source.textStyle
        s.layerID = source.layerID
        if keepText {
            s.text = source.text
            s.textBlockWidth = source.textBlockWidth
        }
        return s
    }
}
