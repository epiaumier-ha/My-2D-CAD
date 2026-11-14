import Foundation
import CoreGraphics

/// Poignées du cadre d'un groupe ou d'une sélection multiple : 4 coins et 4 milieux de côtés, comme Visio.
enum FrameHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Direction dans le repère du cadre : -1 (gauche / haut), 0 (milieu), 1 (droite / bas).
    var direction: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: return (-1, -1)
        case .top: return (0, -1)
        case .topRight: return (1, -1)
        case .right: return (1, 0)
        case .bottomRight: return (1, 1)
        case .bottom: return (0, 1)
        case .bottomLeft: return (-1, 1)
        case .left: return (-1, 0)
        }
    }

    var isCorner: Bool { direction.x != 0 && direction.y != 0 }
}

/// Mise à l'échelle d'un cadre orienté : facteurs le long de ses axes, autour d'un point fixe.
struct FrameScaling: Equatable {
    var frame: RotationFrame
    /// Point fixe, dans le repère du cadre (origine au centre).
    var anchor: CGPoint
    var sx: CGFloat
    var sy: CGFloat

    /// Image d'un point du monde.
    func apply(_ world: CGPoint) -> CGPoint {
        let p = frame.toLocal(world)
        return frame.toWorld(CGPoint(x: anchor.x + (p.x - anchor.x) * sx, y: anchor.y + (p.y - anchor.y) * sy))
    }

    /// Cadre obtenu.
    var scaledFrame: RotationFrame {
        let c = apply(frame.center)
        return RotationFrame(center: c, size: CGSize(width: frame.size.width * sx, height: frame.size.height * sy),
                             angle: frame.angle)
    }
}

extension RotationFrame {
    /// Position d'une poignée dans le monde.
    func handlePoint(_ h: FrameHandle) -> CGPoint {
        let d = h.direction
        return toWorld(CGPoint(x: d.x * size.width / 2, y: d.y * size.height / 2))
    }

    /// Mise à l'échelle quand la poignée `h` est amenée en `pointer` (monde), le côté ou le coin opposé
    /// restant fixe. Pas de retournement ; `minSize` : plus petite taille obtenue par réduction.
    /// `proportional` (Maj, poignées de coin) : même facteur sur les deux axes.
    func scaling(handle h: FrameHandle, to pointer: CGPoint, proportional: Bool,
                 minSize: CGFloat) -> FrameScaling? {
        guard pointer.x.isFinite, pointer.y.isFinite else { return nil }
        let d = h.direction
        let anchor = CGPoint(x: -d.x * size.width / 2, y: -d.y * size.height / 2)
        let q = toLocal(pointer)
        func factor(_ dir: CGFloat, _ length: CGFloat, _ pos: CGFloat, _ fixed: CGFloat) -> CGFloat {
            // Axe sans poignée ou cadre plat (traits alignés) : pas de mise à l'échelle sur cet axe.
            guard dir != 0, length > 1e-9 else { return 1 }
            let newLength = max((pos - fixed) * dir, min(minSize, length))
            return newLength / length
        }
        var sx = factor(d.x, size.width, q.x, anchor.x)
        var sy = factor(d.y, size.height, q.y, anchor.y)
        if proportional && h.isCorner {
            let s = size.width <= 1e-9 ? sy : size.height <= 1e-9 ? sx : max(sx, sy)
            sx = size.width <= 1e-9 ? 1 : s
            sy = size.height <= 1e-9 ? 1 : s
        }
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return nil }
        return FrameScaling(frame: self, anchor: anchor, sx: sx, sy: sy)
    }
}

extension Shape {
    /// Forme mise à l'échelle avec le cadre de son groupe : traits, courbes et cotes point par point ;
    /// les autres formes gardent leur angle et leur centre suit le cadre, largeur et hauteur suivant
    /// l'étirement le long de leurs propres axes (exact quand l'angle relatif est un multiple de 90°).
    /// Texte et épaisseurs de trait inchangés, comme Visio.
    func scaled(_ t: FrameScaling) -> Shape {
        var s = self
        if kind.isPath {
            s.setWorldPoints(worldPoints.map(t.apply))
            s.rotation = 0
            return s
        }
        let rel = CGFloat((rotation - t.frame.angle) * .pi / 180)
        let u = (x: cos(rel), y: sin(rel)), v = (x: -sin(rel), y: cos(rel))
        let w = rect.width * hypot(t.sx * u.x, t.sy * u.y)
        let h = rect.height * hypot(t.sx * v.x, t.sy * v.y)
        let c = t.apply(center)
        s.rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: max(w, 1e-3), height: max(h, 1e-3))
        return s
    }
}

extension Diagram {
    /// Met à l'échelle les formes `originals` (état au début du geste) avec leur cadre.
    mutating func applyScaling(_ t: FrameScaling, to originals: [Shape]) {
        let scaled = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.scaled(t)) })
        for i in shapes.indices {
            if let s = scaled[shapes[i].id] { shapes[i] = s }
        }
    }
}
