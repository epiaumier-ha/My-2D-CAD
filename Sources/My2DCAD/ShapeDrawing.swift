import CoreGraphics

// Tracé d'une forme par cliquer-glisser (outils du ruban et formes des bibliothèques), comme dans Visio :
// - un simple clic ne crée rien, il faut glisser ;
// - Maj : proportions conservées (carré, cercle, proportions de la forme de bibliothèque) ou,
//   pour un trait, angle multiple de 45° ;
// - ⌥ : la forme est tracée depuis son centre (le point de départ est le centre).

enum ShapeDrawing {
    /// Distance minimale du glisser, en pixels écran, en dessous de laquelle rien n'est créé (simple clic).
    static let minimumDragPixels: CGFloat = 5

    /// Taille minimale d'une forme tracée, en unités du dessin (un glisser presque horizontal
    /// ne donne pas une forme de hauteur nulle).
    static func minimumSize(for kind: ShapeKind) -> CGSize {
        kind == .text ? CGSize(width: 20, height: 20) : CGSize(width: 10, height: 10)
    }

    /// Le glisser est-il assez long pour créer une forme ?
    static func isDrag(from start: CGPoint, to end: CGPoint, zoom: CGFloat) -> Bool {
        guard zoom > 0, zoom.isFinite else { return false }
        return start.distance(to: end) * zoom >= minimumDragPixels
    }

    /// Cadre de la forme tracée de `anchor` (point de départ) à `current` (pointeur).
    /// `aspect` : largeur / hauteur imposée par Maj (nil : proportions libres).
    static func rect(from anchor: CGPoint, to current: CGPoint, kind: ShapeKind,
                     aspect: CGFloat?, fromCenter: Bool) -> CGRect {
        var dx = current.x - anchor.x, dy = current.y - anchor.y
        if let aspect, aspect > 0, aspect.isFinite {
            // La plus grande des deux dimensions décide de la taille.
            let w = abs(dx), h = abs(dy)
            if w / aspect >= h {
                dy = (dy < 0 ? -1 : 1) * w / aspect
            } else {
                dx = (dx < 0 ? -1 : 1) * h * aspect
            }
        }
        let minimum = minimumSize(for: kind)
        var width = abs(dx) * (fromCenter ? 2 : 1)
        var height = abs(dy) * (fromCenter ? 2 : 1)
        if let aspect, aspect > 0, aspect.isFinite {
            // Taille minimale sans perdre les proportions.
            let k = max(minimum.width / max(width, 1e-9), minimum.height / max(height, 1e-9), 1)
            if k > 1 { width *= k; height *= k }
        } else {
            width = max(width, minimum.width)
            height = max(height, minimum.height)
        }
        let x: CGFloat, y: CGFloat
        if fromCenter {
            x = anchor.x - width / 2
            y = anchor.y - height / 2
        } else {
            x = dx < 0 ? anchor.x - width : anchor.x
            y = dy < 0 ? anchor.y - height : anchor.y
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Extrémités d'un trait, d'une courbe ou d'une cote tracés de `anchor` à `current`.
    static func segment(from anchor: CGPoint, to current: CGPoint,
                        constrainAngle: Bool, fromCenter: Bool) -> (start: CGPoint, end: CGPoint) {
        var end = current
        if constrainAngle {
            let dx = end.x - anchor.x, dy = end.y - anchor.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            end = CGPoint(x: anchor.x + cos(angle) * len, y: anchor.y + sin(angle) * len)
        }
        if fromCenter {
            return (CGPoint(x: 2 * anchor.x - end.x, y: 2 * anchor.y - end.y), end)
        }
        return (anchor, end)
    }

    /// Proportions imposées par Maj : celles de la forme de bibliothèque, sinon carré / cercle.
    static func aspect(stencil: StencilItem?) -> CGFloat? {
        if let stencil, stencil.size.width > 0, stencil.size.height > 0 {
            return stencil.size.width / stencil.size.height
        }
        return 1
    }
}
