import Foundation
import CoreGraphics

// MARK: - Points de connexion

enum Port {
    static let count = 4

    /// Direction de sortie d'un point de connexion non pivoté (0 haut, 1 droite, 2 bas, 3 gauche).
    static func direction(_ index: Int) -> CGVector {
        switch index {
        case 0: return CGVector(dx: 0, dy: -1)
        case 1: return CGVector(dx: 1, dy: 0)
        case 2: return CGVector(dx: 0, dy: 1)
        default: return CGVector(dx: -1, dy: 0)
        }
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }

    /// Rotation autour de `c` ; angle positif = sens horaire à l'écran (axe Y vers le bas).
    func rotated(by angle: CGFloat, around c: CGPoint) -> CGPoint {
        let s = sin(angle), co = cos(angle)
        let dx = x - c.x, dy = y - c.y
        return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
    }
}

extension CGVector {
    func rotated(by angle: CGFloat) -> CGVector {
        let s = sin(angle), c = cos(angle)
        return CGVector(dx: dx * c - dy * s, dy: dx * s + dy * c)
    }
}

/// Ramène un angle en degrés dans [0, 360) et supprime le bruit numérique.
func normalizedAngle(_ degrees: Double) -> Double {
    guard degrees.isFinite else { return 0 }
    var r = degrees.truncatingRemainder(dividingBy: 360)
    if r < 0 { r += 360 }
    r = (r * 1_000_000).rounded() / 1_000_000
    return r >= 360 ? 0 : r
}

extension Shape {
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// Rotation en radians.
    var angle: CGFloat { CGFloat(rotation) * .pi / 180 }

    /// Repère local (forme non pivotée) → monde.
    func toWorld(_ p: CGPoint) -> CGPoint { rotation == 0 ? p : p.rotated(by: angle, around: center) }

    /// Monde → repère local (forme non pivotée).
    func toLocal(_ p: CGPoint) -> CGPoint { rotation == 0 ? p : p.rotated(by: -angle, around: center) }

    /// Coins dans le monde : haut-gauche, haut-droite, bas-droite, bas-gauche.
    var corners: [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map(toWorld)
    }

    /// Rectangle englobant aligné sur les axes, rotation comprise.
    var bounds: CGRect {
        guard rotation != 0 else { return rect }
        let c = corners
        let xs = c.map(\.x), ys = c.map(\.y)
        let minX = xs.min()!, minY = ys.min()!
        return CGRect(x: minX, y: minY, width: xs.max()! - minX, height: ys.max()! - minY)
    }

    func portPoint(_ port: Int) -> CGPoint {
        let local: CGPoint
        switch port {
        case 0: local = CGPoint(x: rect.midX, y: rect.minY)
        case 1: local = CGPoint(x: rect.maxX, y: rect.midY)
        case 2: local = CGPoint(x: rect.midX, y: rect.maxY)
        default: local = CGPoint(x: rect.minX, y: rect.midY)
        }
        return toWorld(local)
    }

    func portDirection(_ port: Int) -> CGVector { Port.direction(port).rotated(by: angle) }

    func nearestPort(to p: CGPoint) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<Port.count {
            let d = portPoint(i).distance(to: p)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Test de sélection tenant compte de la forme réelle (ellipse, losange) et de la rotation.
    func contains(_ point: CGPoint) -> Bool {
        let p = toLocal(point)
        switch kind {
        case .ellipse:
            let rx = rect.width / 2, ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            let dx = (p.x - rect.midX) / rx, dy = (p.y - rect.midY) / ry
            return dx * dx + dy * dy <= 1
        case .diamond:
            let rx = rect.width / 2, ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            return abs(p.x - rect.midX) / rx + abs(p.y - rect.midY) / ry <= 1
        default:
            // Autres formes et symboles : rectangle englobant (plus facile à saisir).
            return rect.contains(p)
        }
    }
}

// MARK: - Routage orthogonal des connecteurs

/// Les directions de sortie sont ramenées à l'axe dominant (horizontal ou vertical).
func routeConnector(from a: CGPoint, dirA: CGVector, to b: CGPoint, dirB: CGVector) -> [CGPoint] {
    let aHorizontal = abs(dirA.dx) >= abs(dirA.dy)
    let bHorizontal = abs(dirB.dx) >= abs(dirB.dy)
    if aHorizontal && !bHorizontal { return [a, CGPoint(x: b.x, y: a.y), b] }
    if !aHorizontal && bHorizontal { return [a, CGPoint(x: a.x, y: b.y), b] }
    if aHorizontal {
        let mx = (a.x + b.x) / 2
        return [a, CGPoint(x: mx, y: a.y), CGPoint(x: mx, y: b.y), b]
    }
    let my = (a.y + b.y) / 2
    return [a, CGPoint(x: a.x, y: my), CGPoint(x: b.x, y: my), b]
}

func routeConnector(from a: CGPoint, portA: Int, to b: CGPoint, portB: Int) -> [CGPoint] {
    routeConnector(from: a, dirA: Port.direction(portA), to: b, dirB: Port.direction(portB))
}

func distanceFromPoint(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    if len2 == 0 { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
}
