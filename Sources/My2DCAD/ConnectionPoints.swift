import SwiftUI

// MARK: - Points de connexion aux sommets

extension Port {
    /// Nombre maximal de sommets utilisés comme points de connexion, et indice maximal d'un point.
    static let maxVertices = 32
    static let maxIndex = count + maxVertices
}

extension Shape {
    /// Sommets de la forme (repère local, forme non pivotée) : angles vifs de son contour, sans
    /// ceux qui coïncident avec le milieu d'un côté (sommets d'un losange). Une ellipse n'en a pas.
    var vertexAnchors: [CGPoint] {
        guard !kind.isPath, kind != .text else { return [] }
        let parts = paths(in: rect)
        let midpoints = (0..<Port.count).map { i -> CGPoint in
            switch i {
            case 0: return CGPoint(x: rect.midX, y: rect.minY)
            case 1: return CGPoint(x: rect.maxX, y: rect.midY)
            case 2: return CGPoint(x: rect.midX, y: rect.maxY)
            default: return CGPoint(x: rect.minX, y: rect.midY)
            }
        }
        let tolerance = max(min(rect.width, rect.height) * 0.01, 0.01)
        var result: [CGPoint] = []
        for v in Self.corners(of: parts.fill.isEmpty ? parts.stroke : parts.fill) {
            guard !midpoints.contains(where: { $0.distance(to: v) <= tolerance }),
                  !result.contains(where: { $0.distance(to: v) <= tolerance }) else { continue }
            result.append(v)
            if result.count >= Port.maxVertices { break }
        }
        return result
    }

    /// La forme a-t-elle des sommets à proposer comme points de connexion ?
    var hasVertexAnchors: Bool { !vertexAnchors.isEmpty }

    /// Nombre de points de connexion (milieux des côtés, puis sommets si l'option est activée).
    var portCount: Int { Port.count + (vertexPorts ? vertexAnchors.count : 0) }

    /// Tous les points de connexion, dans le monde.
    var portPoints: [CGPoint] {
        var local = (0..<Port.count).map { portPoint($0) }
        if vertexPorts { local += vertexAnchors.map(toWorld) }
        return local
    }

    /// Sommet d'indice `port` (≥ 4), repère local ; nil si l'option est désactivée ou l'indice inconnu.
    func vertexPort(_ port: Int) -> CGPoint? {
        guard vertexPorts, port >= Port.count else { return nil }
        let v = vertexAnchors
        return v.indices.contains(port - Port.count) ? v[port - Port.count] : nil
    }

    /// Angles vifs d'un tracé : jonctions de segments dont les tangentes diffèrent de plus de 10°,
    /// et extrémités des tracés ouverts.
    static func corners(of path: Path) -> [CGPoint] {
        struct Segment { var start: CGPoint; var end: CGPoint; var t0: CGVector; var t1: CGVector }
        func dir(_ a: CGPoint, _ b: CGPoint) -> CGVector? {
            let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
            return len > 1e-9 ? CGVector(dx: dx / len, dy: dy / len) : nil
        }
        var subpaths: [(segments: [Segment], closed: Bool)] = []
        var current: [Segment] = []
        var start = CGPoint.zero, point = CGPoint.zero
        func add(_ end: CGPoint, _ controls: [CGPoint]) {
            let pts = [point] + controls + [end]
            // Tangentes : premier et dernier point distincts parmi les points de contrôle.
            guard let t0 = pts.dropFirst().lazy.compactMap({ dir(point, $0) }).first,
                  let t1 = pts.dropLast().reversed().lazy.compactMap({ dir($0, end) }).first else { point = end; return }
            current.append(Segment(start: point, end: end, t0: t0, t1: t1))
            point = end
        }
        path.forEach { e in
            switch e {
            case .move(let p):
                if !current.isEmpty { subpaths.append((current, false)) }
                current = []; start = p; point = p
            case .line(let p): add(p, [])
            case .quadCurve(let p, let c): add(p, [c])
            case .curve(let p, let c1, let c2): add(p, [c1, c2])
            case .closeSubpath:
                add(start, [])
                if !current.isEmpty { subpaths.append((current, true)) }
                current = []; point = start
            }
        }
        if !current.isEmpty { subpaths.append((current, false)) }
        var result: [CGPoint] = []
        let threshold = cos(10 * CGFloat.pi / 180)
        for (segs, closed) in subpaths {
            for i in segs.indices {
                let next: Segment?
                if i + 1 < segs.count { next = segs[i + 1] } else { next = closed ? segs.first : nil }
                guard let next else { result.append(segs[i].end); continue }
                let a = segs[i].t1, b = next.t0
                if a.dx * b.dx + a.dy * b.dy < threshold { result.append(segs[i].end) }
            }
            if !closed, let first = segs.first { result.append(first.start) }
        }
        return result
    }
}

@MainActor
extension DocumentStore {
    /// Formes sélectionnées pouvant recevoir des points de connexion aux sommets.
    var vertexPortCandidates: [Shape] { selectedShapes.filter(\.hasVertexAnchors) }

    /// Option cochée si toutes les formes concernées l'ont.
    var selectionHasVertexPorts: Bool {
        let shapes = vertexPortCandidates
        return !shapes.isEmpty && shapes.allSatisfy(\.vertexPorts)
    }

    /// Ajoute (ou retire) les sommets des formes sélectionnées à leurs points de connexion. En les
    /// retirant, les connecteurs collés à un sommet passent au milieu de côté le plus proche.
    func setVertexPorts(_ on: Bool) {
        let ids = Set(vertexPortCandidates.map(\.id))
        guard !ids.isEmpty else { NSSound.beep(); return }
        perform { d in
            for i in d.shapes.indices where ids.contains(d.shapes[i].id) { d.shapes[i].vertexPorts = on }
            guard !on else { return }
            let byID = Dictionary(d.shapes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func remap(_ shape: UUID, _ port: Int) -> Int {
                guard ids.contains(shape), port >= Port.count, var s = byID[shape] else { return port }
                s.vertexPorts = true
                let p = s.portPoint(port)
                s.vertexPorts = false
                return s.nearestPort(to: p)
            }
            for i in d.connectors.indices {
                d.connectors[i].fromPort = remap(d.connectors[i].fromShape, d.connectors[i].fromPort)
                d.connectors[i].toPort = remap(d.connectors[i].toShape, d.connectors[i].toPort)
            }
        }
    }
}
