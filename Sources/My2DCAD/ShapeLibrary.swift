import SwiftUI

/// Position du libellé d'une forme.
enum LabelPlacement {
    case center, below
}

/// Tracé d'une forme : `fill` est rempli puis contourné, `stroke` est seulement contourné (détails, symboles).
struct ShapePaths {
    var fill = Path()
    var stroke = Path()

    /// Contour principal (aperçu pendant le dessin).
    var outline: Path { fill.isEmpty ? stroke : fill }
}

extension ShapeKind {
    /// Symboles électriques : traits seuls, sans remplissage.
    var isLineArt: Bool {
        switch self {
        case .resistor, .capacitor, .inductor, .diode, .battery, .electricSwitch,
             .ground, .lamp, .acSource, .motor, .fuse:
            return true
        default:
            return false
        }
    }

    var labelPlacement: LabelPlacement {
        switch self {
        case .server, .workstation, .laptop, .router, .networkSwitch, .firewall, .cloud, .printer, .accessPoint:
            return .below
        case .motor:
            return .center
        default:
            return isLineArt ? .below : .center
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func paths(in r: CGRect) -> ShapePaths {
        let w = r.width, h = r.height
        let m = min(w, h)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        func R(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            CGRect(x: r.minX + x0 * w, y: r.minY + y0 * h, width: (x1 - x0) * w, height: (y1 - y0) * h)
        }
        func polygon(_ pts: [CGPoint]) -> Path {
            var p = Path()
            p.addLines(pts)
            p.closeSubpath()
            return p
        }
        func line(_ p: inout Path, _ a: CGPoint, _ b: CGPoint) {
            p.move(to: a)
            p.addLine(to: b)
        }
        func rounded(_ p: inout Path, _ rect: CGRect, _ radius: CGFloat) {
            p.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        }
        func arrow(_ p: inout Path, from a: CGPoint, to b: CGPoint) {
            let head = m * 0.09
            line(&p, a, b)
            let len = max(a.distance(to: b), 0.001)
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            p.move(to: CGPoint(x: b.x - ux * head - uy * head * 0.6, y: b.y - uy * head + ux * head * 0.6))
            p.addLine(to: b)
            p.addLine(to: CGPoint(x: b.x - ux * head + uy * head * 0.6, y: b.y - uy * head - ux * head * 0.6))
        }
        /// Fils de connexion horizontaux de 0 à `a` et de `b` à 1.
        func leads(_ p: inout Path, _ a: CGFloat, _ b: CGFloat) {
            line(&p, P(0, 0.5), P(a, 0.5))
            line(&p, P(b, 0.5), P(1, 0.5))
        }
        /// Cercle central avec ses fils (lampe, source, moteur). Retourne le centre et le rayon.
        func circleWithLeads(_ p: inout Path) -> (CGPoint, CGFloat) {
            let c = P(0.5, 0.5)
            let radius = min(0.2 * w, 0.45 * h)
            line(&p, P(0, 0.5), CGPoint(x: c.x - radius, y: c.y))
            line(&p, CGPoint(x: c.x + radius, y: c.y), P(1, 0.5))
            p.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
            return (c, radius)
        }

        var out = ShapePaths()
        switch self {
        // MARK: Formes de base
        case .rectangle, .text:
            out.fill = Path(r)
        case .ellipse:
            out.fill = Path(ellipseIn: r)
        case .diamond:
            out.fill = polygon([P(0.5, 0), P(1, 0.5), P(0.5, 1), P(0, 0.5)])

        // MARK: Organigramme
        case .terminator:
            out.fill = Path(roundedRect: r, cornerRadius: m / 2)
        case .data:
            out.fill = polygon([P(0.15, 0), P(1, 0), P(0.85, 1), P(0, 1)])
        case .document:
            var p = Path()
            p.move(to: P(0, 0))
            p.addLine(to: P(1, 0))
            p.addLine(to: P(1, 0.85))
            p.addCurve(to: P(0, 0.85), control1: P(0.7, 0.62), control2: P(0.3, 1.08))
            p.closeSubpath()
            out.fill = p
        case .predefinedProcess:
            out.fill = Path(r)
            line(&out.stroke, P(0.1, 0), P(0.1, 1))
            line(&out.stroke, P(0.9, 0), P(0.9, 1))
        case .manualInput:
            out.fill = polygon([P(0, 0.25), P(1, 0), P(1, 1), P(0, 1)])
        case .preparation:
            out.fill = polygon([P(0.15, 0), P(0.85, 0), P(1, 0.5), P(0.85, 1), P(0.15, 1), P(0, 0.5)])
        case .database:
            let ry = min(h * 0.15, w * 0.25)
            let k: CGFloat = 4.0 / 3.0
            let top = r.minY + ry, bottom = r.maxY - ry
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: top))
            p.addLine(to: CGPoint(x: r.minX, y: bottom))
            p.addCurve(to: CGPoint(x: r.maxX, y: bottom),
                       control1: CGPoint(x: r.minX, y: bottom + k * ry), control2: CGPoint(x: r.maxX, y: bottom + k * ry))
            p.addLine(to: CGPoint(x: r.maxX, y: top))
            p.addCurve(to: CGPoint(x: r.minX, y: top),
                       control1: CGPoint(x: r.maxX, y: top - k * ry), control2: CGPoint(x: r.minX, y: top - k * ry))
            p.closeSubpath()
            out.fill = p
            out.stroke.move(to: CGPoint(x: r.minX, y: top))
            out.stroke.addCurve(to: CGPoint(x: r.maxX, y: top),
                                control1: CGPoint(x: r.minX, y: top + k * ry), control2: CGPoint(x: r.maxX, y: top + k * ry))
        case .offPageReference:
            out.fill = polygon([P(0, 0), P(1, 0), P(1, 0.7), P(0.5, 1), P(0, 0.7)])
        case .delay:
            var p = Path()
            p.move(to: P(0, 0))
            p.addLine(to: P(0.6, 0))
            p.addCurve(to: P(0.6, 1), control1: P(1.133, 0), control2: P(1.133, 1))
            p.addLine(to: P(0, 1))
            p.closeSubpath()
            out.fill = p
        case .manualOperation:
            out.fill = polygon([P(0, 0), P(1, 0), P(0.8, 1), P(0.2, 1)])

        // MARK: Réseau
        case .server:
            rounded(&out.fill, R(0.2, 0, 0.8, 1), m * 0.06)
            for y: CGFloat in [0.15, 0.27, 0.39] { line(&out.stroke, P(0.3, y), P(0.7, y)) }
            let c = P(0.5, 0.8), cr = m * 0.05
            out.stroke.addEllipse(in: CGRect(x: c.x - cr, y: c.y - cr, width: 2 * cr, height: 2 * cr))
        case .workstation:
            rounded(&out.fill, R(0, 0, 1, 0.72), m * 0.05)
            out.fill.addRect(R(0.3, 0.88, 0.7, 0.97))
            out.stroke.addRect(R(0.07, 0.08, 0.93, 0.62))
            line(&out.stroke, P(0.5, 0.72), P(0.5, 0.88))
        case .laptop:
            rounded(&out.fill, R(0.12, 0, 0.88, 0.72), m * 0.05)
            out.fill.addPath(polygon([P(0.02, 0.78), P(0.98, 0.78), P(1, 0.95), P(0, 0.95)]))
            out.stroke.addRect(R(0.18, 0.07, 0.82, 0.65))
        case .router:
            out.fill = Path(ellipseIn: r)
            arrow(&out.stroke, from: P(0.5, 0.42), to: P(0.5, 0.12))
            arrow(&out.stroke, from: P(0.5, 0.58), to: P(0.5, 0.88))
            arrow(&out.stroke, from: P(0.42, 0.5), to: P(0.12, 0.5))
            arrow(&out.stroke, from: P(0.58, 0.5), to: P(0.88, 0.5))
        case .networkSwitch:
            rounded(&out.fill, R(0, 0.15, 1, 0.85), m * 0.08)
            arrow(&out.stroke, from: P(0.12, 0.37), to: P(0.88, 0.37))
            arrow(&out.stroke, from: P(0.88, 0.63), to: P(0.12, 0.63))
        case .firewall:
            out.fill = Path(r)
            for y: CGFloat in [0.25, 0.5, 0.75] { line(&out.stroke, P(0, y), P(1, y)) }
            let joints: [(CGFloat, CGFloat, [CGFloat])] = [
                (0, 0.25, [0.5]), (0.25, 0.5, [0.25, 0.75]), (0.5, 0.75, [0.5]), (0.75, 1, [0.25, 0.75]),
            ]
            for (y0, y1, xs) in joints { for x in xs { line(&out.stroke, P(x, y0), P(x, y1)) } }
        case .cloud:
            var p = Path()
            p.move(to: P(0.22, 0.9))
            p.addCurve(to: P(0.12, 0.5), control1: P(0.02, 0.9), control2: P(0.0, 0.55))
            p.addCurve(to: P(0.38, 0.22), control1: P(0.12, 0.28), control2: P(0.28, 0.18))
            p.addCurve(to: P(0.75, 0.25), control1: P(0.48, 0.02), control2: P(0.72, 0.05))
            p.addCurve(to: P(0.9, 0.6), control1: P(0.95, 0.25), control2: P(1.02, 0.5))
            p.addCurve(to: P(0.78, 0.9), control1: P(1.0, 0.75), control2: P(0.92, 0.9))
            p.closeSubpath()
            out.fill = p
        case .printer:
            out.fill.addRect(R(0.25, 0, 0.75, 0.3))
            rounded(&out.fill, R(0, 0.3, 1, 0.78), m * 0.05)
            out.fill.addRect(R(0.18, 0.78, 0.82, 1))
            line(&out.stroke, P(0.7, 0.45), P(0.86, 0.45))
        case .accessPoint:
            rounded(&out.fill, R(0.15, 0.72, 0.85, 1), m * 0.05)
            let c = P(0.5, 0.64)
            for k in [0.14 * m, 0.28 * m, 0.42 * m] {
                out.stroke.move(to: CGPoint(x: c.x - k * 0.707, y: c.y - k * 0.707))
                out.stroke.addQuadCurve(to: CGPoint(x: c.x + k * 0.707, y: c.y - k * 0.707),
                                        control: CGPoint(x: c.x, y: c.y - k * 1.414))
            }

        // MARK: Électricité (IEC)
        case .resistor:
            leads(&out.stroke, 0.25, 0.75)
            out.stroke.addRect(R(0.25, 0.3, 0.75, 0.7))
        case .capacitor:
            leads(&out.stroke, 0.45, 0.55)
            line(&out.stroke, P(0.45, 0.12), P(0.45, 0.88))
            line(&out.stroke, P(0.55, 0.12), P(0.55, 0.88))
        case .inductor:
            leads(&out.stroke, 0.2, 0.8)
            let bump = 0.15 * w
            var x = r.minX + 0.2 * w
            let y = r.midY
            out.stroke.move(to: CGPoint(x: x, y: y))
            for _ in 0..<4 {
                out.stroke.addCurve(to: CGPoint(x: x + bump, y: y),
                                    control1: CGPoint(x: x, y: y - bump * 0.9),
                                    control2: CGPoint(x: x + bump, y: y - bump * 0.9))
                x += bump
            }
        case .diode:
            leads(&out.stroke, 0.3, 0.7)
            out.stroke.addPath(polygon([P(0.3, 0.15), P(0.3, 0.85), P(0.7, 0.5)]))
            line(&out.stroke, P(0.7, 0.15), P(0.7, 0.85))
        case .battery:
            leads(&out.stroke, 0.45, 0.55)
            line(&out.stroke, P(0.45, 0.1), P(0.45, 0.9))
            line(&out.stroke, P(0.55, 0.3), P(0.55, 0.7))
        case .electricSwitch:
            leads(&out.stroke, 0.3, 0.7)
            line(&out.stroke, P(0.3, 0.5), P(0.68, 0.12))
        case .ground:
            line(&out.stroke, P(0.5, 0), P(0.5, 0.45))
            line(&out.stroke, P(0.15, 0.45), P(0.85, 0.45))
            line(&out.stroke, P(0.3, 0.65), P(0.7, 0.65))
            line(&out.stroke, P(0.43, 0.85), P(0.57, 0.85))
        case .lamp:
            let (c, rr) = circleWithLeads(&out.stroke)
            let d = rr * 0.707
            line(&out.stroke, CGPoint(x: c.x - d, y: c.y - d), CGPoint(x: c.x + d, y: c.y + d))
            line(&out.stroke, CGPoint(x: c.x - d, y: c.y + d), CGPoint(x: c.x + d, y: c.y - d))
        case .acSource:
            let (c, rr) = circleWithLeads(&out.stroke)
            out.stroke.move(to: CGPoint(x: c.x - rr * 0.6, y: c.y))
            out.stroke.addCurve(to: c, control1: CGPoint(x: c.x - rr * 0.45, y: c.y - rr * 0.7),
                                control2: CGPoint(x: c.x - rr * 0.15, y: c.y - rr * 0.7))
            out.stroke.addCurve(to: CGPoint(x: c.x + rr * 0.6, y: c.y),
                                control1: CGPoint(x: c.x + rr * 0.15, y: c.y + rr * 0.7),
                                control2: CGPoint(x: c.x + rr * 0.45, y: c.y + rr * 0.7))
        case .motor:
            _ = circleWithLeads(&out.stroke)
        case .fuse:
            leads(&out.stroke, 0.25, 0.75)
            out.stroke.addRect(R(0.25, 0.35, 0.75, 0.65))
            line(&out.stroke, P(0.25, 0.5), P(0.75, 0.5))
        }
        return out
    }
}
