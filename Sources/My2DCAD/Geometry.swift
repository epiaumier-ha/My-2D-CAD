import Foundation
import CoreGraphics

// MARK: - Points de connexion

enum Port {
    static let count = 4

    /// Direction de sortie d'un point de connexion (0 haut, 1 droite, 2 bas, 3 gauche).
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
}

extension Shape {
    func portPoint(_ port: Int) -> CGPoint {
        switch port {
        case 0: return CGPoint(x: rect.midX, y: rect.minY)
        case 1: return CGPoint(x: rect.maxX, y: rect.midY)
        case 2: return CGPoint(x: rect.midX, y: rect.maxY)
        default: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    func nearestPort(to p: CGPoint) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<Port.count {
            let d = portPoint(i).distance(to: p)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Test de sélection tenant compte de la forme réelle (ellipse, losange).
    func contains(_ p: CGPoint) -> Bool {
        switch kind {
        case .rectangle, .text:
            return rect.contains(p)
        case .ellipse:
            let rx = rect.width / 2, ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            let dx = (p.x - rect.midX) / rx, dy = (p.y - rect.midY) / ry
            return dx * dx + dy * dy <= 1
        case .diamond:
            let rx = rect.width / 2, ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            return abs(p.x - rect.midX) / rx + abs(p.y - rect.midY) / ry <= 1
        }
    }
}

// MARK: - Routage orthogonal des connecteurs

func routeConnector(from a: CGPoint, portA: Int, to b: CGPoint, portB: Int) -> [CGPoint] {
    let aHorizontal = Port.direction(portA).dx != 0
    let bHorizontal = Port.direction(portB).dx != 0
    if aHorizontal && !bHorizontal { return [a, CGPoint(x: b.x, y: a.y), b] }
    if !aHorizontal && bHorizontal { return [a, CGPoint(x: a.x, y: b.y), b] }
    if aHorizontal {
        let mx = (a.x + b.x) / 2
        return [a, CGPoint(x: mx, y: a.y), CGPoint(x: mx, y: b.y), b]
    }
    let my = (a.y + b.y) / 2
    return [a, CGPoint(x: a.x, y: my), CGPoint(x: b.x, y: my), b]
}

func distanceFromPoint(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    if len2 == 0 { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
}
