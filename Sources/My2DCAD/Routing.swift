import Foundation
import CoreGraphics

/// Style de tracé d'un connecteur.
enum ConnectorRouting: String, Codable, CaseIterable, Identifiable {
    case orthogonal, straight, curved

    var id: String { rawValue }

    var label: String {
        switch self {
        case .orthogonal: return "Orthogonal"
        case .straight: return "Droit"
        case .curved: return "Courbe"
        }
    }
}

/// Index des formes par identifiant et obstacles de routage d'une page, calculés une seule fois
/// pour tracer ou tester tous les connecteurs (au lieu d'une recherche linéaire par connecteur).
struct RoutingContext {
    let byID: [UUID: Shape]
    let obstacles: [CGRect]

    init(_ d: Diagram) {
        byID = Dictionary(d.shapes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        obstacles = d.shapes.filter { !$0.kind.isPath && d.isVisible($0) }.map(\.bounds)
    }

    /// Obstacles proches du segment a–b (au plus 40).
    func obstacles(near a: CGPoint, _ b: CGPoint) -> [CGRect] {
        let zone = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .insetBy(dx: -150, dy: -150)
        var result: [CGRect] = []
        for r in obstacles where r.intersects(zone) {
            result.append(r)
            if result.count >= 40 { break }
        }
        return result
    }
}

extension Diagram {
    /// Tracé d'un connecteur (polyligne en coordonnées monde ; une courbe est échantillonnée).
    func connectorPoints(_ c: Connector) -> [CGPoint]? {
        connectorPoints(c, context: RoutingContext(self))
    }

    /// Même tracé, avec un contexte partagé entre plusieurs connecteurs.
    func connectorPoints(_ c: Connector, context: RoutingContext) -> [CGPoint]? {
        guard let a = context.byID[c.fromShape], let b = context.byID[c.toShape] else { return nil }
        let pa = a.portPoint(c.fromPort), pb = b.portPoint(c.toPort)
        let da = a.portDirection(c.fromPort), db = b.portDirection(c.toPort)
        switch c.routing {
        case .straight:
            return [pa, pb]
        case .curved:
            return curvedConnector(from: pa, dirA: da, to: pb, dirB: db)
        case .orthogonal:
            return orthogonalRoute(from: pa, dirA: da, to: pb, dirB: db, obstacles: context.obstacles(near: pa, pb))
        }
    }
}

/// Connecteur courbe : Bézier cubique qui sort perpendiculairement des formes.
func curvedConnector(from a: CGPoint, dirA: CGVector, to b: CGPoint, dirB: CGVector) -> [CGPoint] {
    let k = max(hypot(b.x - a.x, b.y - a.y) * 0.4, 30)
    let c1 = CGPoint(x: a.x + dirA.dx * k, y: a.y + dirA.dy * k)
    let c2 = CGPoint(x: b.x + dirB.dx * k, y: b.y + dirB.dy * k)
    return (0...24).map { i in
        let t = CGFloat(i) / 24, u = 1 - t
        let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
        return CGPoint(x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x,
                       y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y)
    }
}

// MARK: - Routage orthogonal qui contourne les formes

/// Cache des tracés : le routage est recalculé seulement quand les extrémités ou les obstacles changent.
final class RouteCache: @unchecked Sendable {
    static let shared = RouteCache()
    private var routes: [Int: [CGPoint]] = [:]
    private let lock = NSLock()

    func value(_ key: Int) -> [CGPoint]? {
        lock.lock(); defer { lock.unlock() }
        return routes[key]
    }

    func store(_ key: Int, _ route: [CGPoint]) {
        lock.lock(); defer { lock.unlock() }
        if routes.count > 4096 { routes.removeAll() }
        routes[key] = route
    }
}

/// Direction ramenée à l'axe dominant (unitaire).
private func axisUnit(_ v: CGVector) -> CGVector {
    abs(v.dx) >= abs(v.dy) ? CGVector(dx: v.dx >= 0 ? 1 : -1, dy: 0) : CGVector(dx: 0, dy: v.dy >= 0 ? 1 : -1)
}

/// Tas binaire minimal pour l'algorithme A*.
private struct MinHeap {
    private var items: [(cost: CGFloat, state: Int)] = []
    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ cost: CGFloat, _ state: Int) {
        items.append((cost, state))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if items[p].cost <= items[i].cost { break }
            items.swapAt(p, i); i = p
        }
    }

    mutating func pop() -> (cost: CGFloat, state: Int)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].cost < items[m].cost { m = l }
                if r < items.count && items[r].cost < items[m].cost { m = r }
                if m == i { break }
                items.swapAt(m, i); i = m
            }
        }
        return top
    }
}

/// Tracé orthogonal entre deux points de connexion, qui contourne les rectangles `obstacles`
/// (A* sur la grille formée par les bords des obstacles, avec une pénalité par changement de direction).
/// Si aucun chemin n'est trouvé, le tracé simple est utilisé.
func orthogonalRoute(from a: CGPoint, dirA: CGVector, to b: CGPoint, dirB: CGVector,
                     obstacles: [CGRect]) -> [CGPoint] {
    let simple = routeConnector(from: a, dirA: dirA, to: b, dirB: dirB)
    guard !obstacles.isEmpty else { return simple }

    var hasher = Hasher()
    for v in [a.x, a.y, b.x, b.y, dirA.dx, dirA.dy, dirB.dx, dirB.dy] { hasher.combine(v) }
    for r in obstacles { hasher.combine(r.minX); hasher.combine(r.minY); hasher.combine(r.width); hasher.combine(r.height) }
    let key = hasher.finalize()
    if let cached = RouteCache.shared.value(key) { return cached }

    let margin: CGFloat = 12, stub: CGFloat = 20, bendPenalty: CGFloat = 30
    let ua = axisUnit(dirA), ub = axisUnit(dirB)
    let sa = CGPoint(x: a.x + ua.dx * stub, y: a.y + ua.dy * stub)
    let sb = CGPoint(x: b.x + ub.dx * stub, y: b.y + ub.dy * stub)
    let blocks = obstacles.map { $0.insetBy(dx: -margin, dy: -margin) }

    func strictlyInside(_ p: CGPoint) -> Bool {
        blocks.contains { p.x > $0.minX + 0.01 && p.x < $0.maxX - 0.01 && p.y > $0.minY + 0.01 && p.y < $0.maxY - 0.01 }
    }
    guard !strictlyInside(sa), !strictlyInside(sb) else { return simple }

    var xs = Set([sa.x, sb.x, (sa.x + sb.x) / 2])
    var ys = Set([sa.y, sb.y, (sa.y + sb.y) / 2])
    for r in blocks { xs.insert(r.minX); xs.insert(r.maxX); ys.insert(r.minY); ys.insert(r.maxY) }
    let gx = xs.sorted(), gy = ys.sorted()
    guard let si = gx.firstIndex(of: sa.x), let sj = gy.firstIndex(of: sa.y),
          let ti = gx.firstIndex(of: sb.x), let tj = gy.firstIndex(of: sb.y) else { return simple }

    let nx = gx.count, ny = gy.count
    // État : nœud (i, j) et direction d'arrivée d (0 droite, 1 gauche, 2 bas, 3 haut).
    func state(_ i: Int, _ j: Int, _ d: Int) -> Int { (j * nx + i) * 4 + d }
    let moves = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    func dirIndex(_ v: CGVector) -> Int { v.dx > 0 ? 0 : (v.dx < 0 ? 1 : (v.dy > 0 ? 2 : 3)) }
    let startDir = dirIndex(ua)
    let goalDir = dirIndex(CGVector(dx: -ub.dx, dy: -ub.dy))   // on arrive face à la forme cible

    var best = [CGFloat](repeating: .greatestFiniteMagnitude, count: nx * ny * 4)
    var parent = [Int](repeating: -1, count: nx * ny * 4)
    var heap = MinHeap()
    let start = state(si, sj, startDir)
    best[start] = 0
    func heuristic(_ i: Int, _ j: Int) -> CGFloat { abs(gx[i] - sb.x) + abs(gy[j] - sb.y) }
    heap.push(heuristic(si, sj), start)
    var goal: Int?
    var expanded = 0

    while let (_, s) = heap.pop() {
        expanded += 1
        if expanded > 60_000 { break }
        let d = s % 4, node = s / 4, i = node % nx, j = node / nx
        // La pénalité d'arrivée est déjà dans le coût : le premier but extrait est optimal.
        if i == ti && j == tj { goal = s; break }
        for (k, m) in moves.enumerated() {
            let ni = i + m.0, nj = j + m.1
            guard ni >= 0, ni < nx, nj >= 0, nj < ny else { continue }
            let p = CGPoint(x: gx[ni], y: gy[nj])
            let mid = CGPoint(x: (gx[i] + p.x) / 2, y: (gy[j] + p.y) / 2)
            guard !strictlyInside(p), !strictlyInside(mid) else { continue }
            var cost = best[s] + abs(p.x - gx[i]) + abs(p.y - gy[j])
            if k != d { cost += bendPenalty }
            if ni == ti && nj == tj && k != goalDir { cost += bendPenalty }
            let ns = state(ni, nj, k)
            if cost < best[ns] {
                best[ns] = cost
                parent[ns] = s
                heap.push(cost + heuristic(ni, nj), ns)
            }
        }
    }

    guard let found = goal else { return simple }
    var nodes: [CGPoint] = []
    var cur = found
    while cur >= 0 {
        let node = cur / 4
        nodes.append(CGPoint(x: gx[node % nx], y: gy[node / nx]))
        cur = parent[cur]
    }
    nodes.reverse()
    // Suppression des points alignés.
    var route: [CGPoint] = []
    for p in [a] + nodes + [b] {
        if let last = route.last, last == p { continue }
        if route.count >= 2 {
            let p0 = route[route.count - 2], p1 = route[route.count - 1]
            if (p0.x == p1.x && p1.x == p.x) || (p0.y == p1.y && p1.y == p.y) { route.removeLast() }
        }
        route.append(p)
    }
    RouteCache.shared.store(key, route)
    return route
}
