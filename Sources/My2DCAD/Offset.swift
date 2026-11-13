import SwiftUI
import CoreGraphics

// MARK: - Décalage : sens pour les formes fermées, direction pour les traits

/// Sens du décalage d'une forme fermée (contour).
/// Choix affichable dans un menu (libellé et symbole).
protocol OffsetChoice {
    var label: String { get }
    var symbol: String { get }
}

enum OffsetSide: String, CaseIterable, Identifiable, OffsetChoice {
    case both, outside, inside

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return "Des deux côtés"
        case .outside: return "Vers l'extérieur"
        case .inside: return "Vers l'intérieur"
        }
    }

    var symbol: String {
        switch self {
        case .both: return "square.dashed"
        case .outside: return "arrow.up.left.and.arrow.down.right"
        case .inside: return "arrow.down.right.and.arrow.up.left"
        }
    }
}

/// Direction du décalage d'un trait (ou d'une courbe) : côté vu sur la page où la parallèle est tracée.
enum LineOffsetDirection: String, CaseIterable, Identifiable, OffsetChoice {
    case both, up, down, left, right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: return "Des deux côtés"
        case .up: return "Au-dessus"
        case .down: return "En dessous"
        case .left: return "À gauche"
        case .right: return "À droite"
        }
    }

    var symbol: String {
        switch self {
        case .both: return "arrow.up.and.down"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    /// Direction sur la page (Y vers le bas).
    var vector: CGVector? {
        switch self {
        case .both: return nil
        case .up: return CGVector(dx: 0, dy: -1)
        case .down: return CGVector(dx: 0, dy: 1)
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        }
    }
}

enum OffsetError: LocalizedError, Equatable {
    case parallelToDirection(LineOffsetDirection)
    case insideTooLarge

    var errorDescription: String? {
        switch self {
        case .parallelToDirection(let d):
            let hint = (d == .left || d == .right)
                ? "Un trait horizontal n'a pas de côté gauche ou droit : choisissez « Au-dessus » ou « En dessous »."
                : "Un trait vertical n'a pas de côté haut ou bas : choisissez « À gauche » ou « À droite »."
            return "Impossible de décaler « \(d.label.lowercased()) » : le trait est parallèle à cette direction. " + hint
        case .insideTooLarge:
            return "La distance est trop grande : le contour intérieur disparaît."
        }
    }
}

enum OffsetGeometry {
    /// Rapport maximal entre la pointe d'un angle et la distance (au-delà, l'angle est coupé).
    static let miterLimit: CGFloat = 4

    /// Contours décalés d'une forme (monde) : formes fermées selon `side`, traits selon `direction`.
    /// Retourne nil si rien n'est produit (contour intérieur disparu).
    static func offset(_ s: Shape, distance d: CGFloat, side: OffsetSide,
                       direction: LineOffsetDirection) throws -> CGPath? {
        guard let geometry = s.worldGeometry else { return nil }
        // Forme fermée (rectangle, ellipse, polygone…) : son contour rempli.
        if !s.kind.isPath, let region = s.worldRegion, isClosedRegion(s) {
            return regionOffset(region, distance: d, side: side)
        }
        // Traits, courbes, formes libres ouvertes : chaque sous-tracé ouvert reçoit sa parallèle ;
        // un sous-tracé fermé est traité comme une forme.
        let all = contours(of: geometry)
        let open = all.filter { !$0.closed }
        let closed = all.filter(\.closed)
        let out = CGMutablePath()
        for c in open {
            let pts = cleaned(c.polyline)
            guard pts.count >= 2 else { continue }
            for sign in try sides(of: pts, direction: direction) {
                let q = offsetPolyline(pts, by: sign * d)
                guard q.count >= 2 else { continue }
                out.addLines(between: q)
            }
        }
        if !closed.isEmpty {
            var path = Path()
            for c in closed { c.add(to: &path) }
            let region = path.cgPath.normalized(using: .winding)
            if !region.isEmpty, let r = regionOffset(region, distance: d, side: side) { out.addPath(r) }
        }
        return out.isEmpty ? nil : out
    }

    /// Le contour rempli de la forme est-il fait de sous-tracés fermés ?
    static func isClosedRegion(_ s: Shape) -> Bool {
        let fill = s.paths(in: s.rect).fill
        let parts = contours(of: fill)
        return !parts.isEmpty && parts.allSatisfy(\.closed)
    }

    /// Contour d'une surface décalé vers l'extérieur (surface agrandie), l'intérieur (surface réduite) ou les deux.
    static func regionOffset(_ region: CGPath, distance d: CGFloat, side: OffsetSide) -> CGPath? {
        let band = region.copy(strokingWithWidth: 2 * d, lineCap: .butt, lineJoin: .miter, miterLimit: miterLimit)
        let out = CGMutablePath()
        if side != .inside {
            let grown = region.union(band)
            if !grown.isEmpty { out.addPath(grown) }
        }
        if side != .outside {
            let shrunk = region.subtracting(band)
            if !shrunk.isEmpty { out.addPath(shrunk) }
        }
        return out.isEmpty ? nil : out
    }

    /// Côtés à tracer : +1 (gauche du sens de parcours, soit au-dessus pour un trait tracé vers la droite),
    /// -1, ou les deux. La direction choisie désigne le côté tourné vers elle sur la page.
    static func sides(of pts: [CGPoint], direction: LineOffsetDirection) throws -> [CGFloat] {
        guard let u = direction.vector else { return [1, -1] }
        // Normale moyenne (pondérée par la longueur) du côté +1.
        var nx: CGFloat = 0, ny: CGFloat = 0, length: CGFloat = 0
        for (a, b) in zip(pts, pts.dropFirst()) {
            nx += b.y - a.y; ny -= b.x - a.x
            length += a.distance(to: b)
        }
        let n = hypot(nx, ny)
        guard length > 0, n > 1e-9 else { throw OffsetError.parallelToDirection(direction) }
        let dot = (nx * u.dx + ny * u.dy) / n
        // Trait parallèle (à 1° près) à la direction : ses deux côtés lui sont perpendiculaires.
        guard abs(dot) > sin(CGFloat.pi / 180) else { throw OffsetError.parallelToDirection(direction) }
        return [dot > 0 ? 1 : -1]
    }

    /// Points consécutifs confondus retirés.
    static func cleaned(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts where out.last.map({ $0.distance(to: p) > 1e-9 }) ?? true { out.append(p) }
        return out
    }

    /// Parallèle à une ligne brisée ouverte, à la distance signée `d` (positive : côté gauche du parcours).
    /// Angles vifs : les segments décalés se rejoignent en pointe, coupée au-delà de `miterLimit`.
    static func offsetPolyline(_ pts: [CGPoint], by d: CGFloat) -> [CGPoint] {
        let p = cleaned(pts)
        guard p.count >= 2 else { return [] }
        let normals: [CGVector] = zip(p, p.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
            return CGVector(dx: dy / len, dy: -dx / len)
        }
        func shifted(_ q: CGPoint, _ n: CGVector) -> CGPoint { CGPoint(x: q.x + n.dx * d, y: q.y + n.dy * d) }
        var out = [shifted(p[0], normals[0])]
        for j in 1..<(p.count - 1) {
            let n1 = normals[j - 1], n2 = normals[j]
            let cosine = n1.dx * n2.dx + n1.dy * n2.dy
            // Pointe : p + (n1 + n2) · d / (1 + cos), à la distance d / cos(θ/2) du sommet.
            if 1 + cosine > 2 / (miterLimit * miterLimit) {
                let k = d / (1 + cosine)
                out.append(CGPoint(x: p[j].x + (n1.dx + n2.dx) * k, y: p[j].y + (n1.dy + n2.dy) * k))
            } else {
                out.append(shifted(p[j], n1))
                out.append(shifted(p[j], n2))
            }
        }
        out.append(shifted(p[p.count - 1], normals[normals.count - 1]))
        return out
    }
}
