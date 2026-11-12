import SwiftUI
import AppKit

/// Dessin d'une page (connecteurs, formes, libellés), partagé par le canevas et l'export.
/// Les coordonnées écran valent : monde × zoom + décalage.
struct DiagramPainter {
    let diagram: Diagram
    let zoom: CGFloat
    let offset: CGSize
    /// Forme dont le texte est en cours d'édition (son libellé n'est pas dessiné).
    var editingShapeID: UUID?
    /// Export / impression : seuls les calques visibles et imprimables sont dessinés.
    var forExport = false
    /// Zone visible à l'écran : ce qui est en dehors n'est pas dessiné (nil : tout dessiner).
    var viewport: CGRect?
    private let routingBox: RoutingBox

    /// Contexte de routage construit à la première utilisation, puis partagé.
    private final class RoutingBox {
        let diagram: Diagram
        lazy var context = RoutingContext(diagram)
        init(_ diagram: Diagram) { self.diagram = diagram }
    }

    var routing: RoutingContext { routingBox.context }

    init(diagram: Diagram, zoom: CGFloat, offset: CGSize, editingShapeID: UUID? = nil,
         forExport: Bool = false, viewport: CGRect? = nil) {
        self.diagram = diagram
        self.zoom = zoom
        self.offset = offset
        self.editingShapeID = editingShapeID
        self.forExport = forExport
        self.viewport = viewport
        routingBox = RoutingBox(diagram)
    }

    /// La forme est-elle (au moins en partie) dans la zone visible ? Marge pour les libellés et les traits.
    func isOnScreen(_ s: Shape) -> Bool {
        guard let viewport else { return true }
        return toScreen(s.bounds).insetBy(dx: -150, dy: -150).intersects(viewport)
    }

    /// Connecteur potentiellement visible : zone englobant ses deux formes (avec marge de contournement).
    func isOnScreen(_ c: Connector) -> Bool {
        guard let viewport else { return true }
        guard let a = routing.byID[c.fromShape], let b = routing.byID[c.toShape] else { return false }
        return toScreen(a.bounds.union(b.bounds)).insetBy(dx: -200 * zoom - 20, dy: -200 * zoom - 20).intersects(viewport)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height)
    }

    func toScreen(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x * zoom + offset.width, y: r.origin.y * zoom + offset.height,
               width: r.width * zoom, height: r.height * zoom)
    }

    func isDrawn(_ s: Shape) -> Bool { forExport ? diagram.isPrintable(s) : diagram.isVisible(s) }

    func isDrawn(_ c: Connector) -> Bool {
        guard let a = routing.byID[c.fromShape], let b = routing.byID[c.toShape] else { return false }
        return isDrawn(a) && isDrawn(b)
    }

    /// Formes dessinées, dans l'ordre de superposition.
    var drawnShapes: [Shape] { diagram.shapes.filter { isDrawn($0) } }

    /// Formes dont le libellé doit être préparé (texte non vide, à l'écran) : les autres n'ont pas de vue.
    var labelledShapes: [Shape] {
        diagram.shapes.filter { s in
            let hasText = !s.text.isEmpty || s.kind == .text || s.kind == .dimension
            return hasText && s.id != editingShapeID && isDrawn(s) && isOnScreen(s)
        }
    }

    /// Connecteurs sous les formes, puis les formes dans leur ordre (seulement ce qui est à l'écran).
    func drawContent(_ ctx: inout GraphicsContext) {
        for c in diagram.connectors where isDrawn(c) && isOnScreen(c) { drawConnector(c, in: &ctx) }
        for s in diagram.shapes where isDrawn(s) && isOnScreen(s) { drawShape(s, in: &ctx) }
    }

    /// Rotation autour du centre du rectangle écran (le zoom est uniforme, l'angle est conservé).
    func rotationTransform(_ s: Shape, screenRect r: CGRect) -> CGAffineTransform {
        guard s.rotation != 0 else { return .identity }
        return CGAffineTransform(translationX: r.midX, y: r.midY)
            .rotated(by: s.angle)
            .translatedBy(x: -r.midX, y: -r.midY)
    }

    /// Tracé écran d'un trait ou d'une courbe à partir de ses points monde.
    func screenPath(kind: ShapeKind, points world: [CGPoint]) -> Path {
        var p = world.map { toScreen($0) }
        if kind == .dimension, p.count == 3 {
            let g = dimensionGeometry(p[0], p[1], p[2])
            p = [g.a, g.a2, g.b2, g.b]
        }
        var path = Path()
        if kind == .curve, p.count == 3 {
            path.move(to: p[0])
            path.addQuadCurve(to: p[2], control: p[1])
        } else if p.count >= 2 {
            path.move(to: p[0])
            for q in p.dropFirst() { path.addLine(to: q) }
        }
        return path
    }

    func drawPathShape(_ s: Shape, in ctx: inout GraphicsContext) {
        if s.kind == .dimension { drawDimension(s, in: &ctx); return }
        let world = s.worldPoints
        if s.line.dash != .none {
            ctx.stroke(screenPath(kind: s.kind, points: world), with: .color(s.line.displayColor),
                       style: s.line.strokeStyle(zoom: zoom))
        }
        // Flèches : direction donnée par la tangente à chaque extrémité.
        let pts = world.map { toScreen($0) }
        if pts.count >= 2 {
            let beforeEnd = pts.count == 3 ? pts[1] : pts[pts.count - 2]
            let afterStart = pts[1]
            drawArrow(s.line.beginArrow, tip: pts[0],
                      from: afterStart.distance(to: pts[0]) > 0.5 ? afterStart : pts[pts.count - 1],
                      style: s.line, in: &ctx)
            drawArrow(s.line.endArrow, tip: pts[pts.count - 1],
                      from: beforeEnd.distance(to: pts[pts.count - 1]) > 0.5 ? beforeEnd : pts[0],
                      style: s.line, in: &ctx)
        }
        guard !s.text.isEmpty, editingShapeID != s.id,
              let label = ctx.resolveSymbol(id: s.id) else { return }
        let m = s.pathMidpoint
        ctx.draw(label, at: toScreen(CGPoint(x: m.x + s.textOffset.x, y: m.y + s.textOffset.y)), anchor: .center)
    }

    func drawShape(_ s: Shape, in ctx: inout GraphicsContext) {
        if s.kind.isPath { drawPathShape(s, in: &ctx); return }
        let r = toScreen(s.rect)
        if s.kind != .text {
            let t = rotationTransform(s, screenRect: r)
            let parts = s.paths(in: r)
            let lineColor = s.line.displayColor
            let style = s.line.strokeStyle(zoom: zoom)
            let showLine = s.line.dash != .none
            if !parts.fill.isEmpty {
                let body = parts.fill.applying(t)
                if let fill = s.fillColor { ctx.fill(body, with: .color(fill)) }
                if showLine { ctx.stroke(body, with: .color(lineColor), style: style) }
            }
            if !parts.stroke.isEmpty && showLine {
                ctx.stroke(parts.stroke.applying(t), with: .color(lineColor), style: style)
            }
        }
        guard editingShapeID != s.id, let label = ctx.resolveSymbol(id: s.id) else { return }
        var textContext = ctx
        textContext.translateBy(x: r.midX, y: r.midY)
        if s.rotation != 0 { textContext.rotate(by: .radians(Double(s.angle))) }
        // Bloc de texte éventuellement déplacé (décalage dans le repère de la forme).
        let off = CGPoint(x: s.textOffset.x * zoom, y: s.textOffset.y * zoom)
        if s.kind.labelPlacement == .below {
            textContext.draw(label, at: CGPoint(x: off.x, y: r.height / 2 + 4 * zoom + off.y), anchor: .top)
        } else {
            textContext.draw(label, at: off, anchor: .center)
        }
    }

    // MARK: - Libellés

    /// Vue du libellé d'une forme : retour à la ligne dans la largeur de la forme
    /// (ou sur deux largeurs sous une icône), police et alignement du style de texte.
    @ViewBuilder
    func labelView(_ s: Shape) -> some View {
        let placeholder = s.text.isEmpty && s.kind == .text
        let content = placeholder ? "Texte" : (s.kind == .dimension ? dimensionText(s) : s.text)
        let ts = s.textStyle
        let r = toScreen(s.rect)
        let text = Text(content)
            .italic(ts.italic)
            .font(ts.font(zoom: zoom))
            .foregroundColor(placeholder ? .gray : ts.color.color)
        if content.isEmpty {
            EmptyView()
        } else if s.kind.isPath {
            text
                .multilineTextAlignment(ts.alignment.textAlignment)
                .padding(.horizontal, 3)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            let below = s.kind.labelPlacement == .below
            let width = s.textBlockWidth != nil ? s.textBlockWidthValue * zoom
                : (below ? max(r.width * 2, 120 * zoom) : max(r.width - 8 * zoom, 20))
            text
                .multilineTextAlignment(ts.alignment.textAlignment)
                .frame(width: width, alignment: ts.alignment.frameAlignment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func drawConnector(_ c: Connector, in ctx: inout GraphicsContext) {
        guard let world = diagram.connectorPoints(c, context: routing), world.count > 1 else { return }
        let pts = world.map { toScreen($0) }
        var path = Path()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        if c.line.dash != .none {
            ctx.stroke(path, with: .color(c.line.displayColor), style: c.line.strokeStyle(zoom: zoom))
        }
        // Flèches orientées selon le premier / dernier segment non nul.
        let start = pts[0], tip = pts[pts.count - 1]
        if let next = pts.dropFirst().first(where: { $0.distance(to: start) > 0.5 }) {
            drawArrow(c.line.beginArrow, tip: start, from: next, style: c.line, in: &ctx)
        }
        if let prev = pts.dropLast().last(where: { $0.distance(to: tip) > 0.5 }) {
            drawArrow(c.line.endArrow, tip: tip, from: prev, style: c.line, in: &ctx)
        }
    }

    /// Pointe de flèche à l'extrémité `tip`, orientée depuis `from` (coordonnées écran).
    func drawArrow(_ type: ArrowHead, tip: CGPoint, from: CGPoint, style l: LineStyle,
                           in ctx: inout GraphicsContext) {
        guard let head = arrowHead(type, tip: tip, from: from, size: l.arrowLength(zoom: zoom)) else { return }
        let shading = GraphicsContext.Shading.color(l.displayColor)
        if head.filled {
            ctx.fill(head.path, with: shading)
        } else {
            ctx.stroke(head.path, with: shading,
                       style: StrokeStyle(lineWidth: max(CGFloat(l.width) * zoom, 0.75),
                                          lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Cotes

    /// Texte d'une cote : mesure automatique (unité et échelle de la page), ou texte saisi.
    func dimensionText(_ s: Shape) -> String {
        guard s.text.isEmpty, let g = s.dimension else { return s.text }
        return diagram.formatLength(g.length)
    }

    /// Angle du texte d'une cote, ramené pour rester lisible (jamais à l'envers).
    static func readableAngle(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        var angle = atan2(b.y - a.y, b.x - a.x)
        if angle > .pi / 2 { angle -= .pi } else if angle <= -.pi / 2 { angle += .pi }
        return angle
    }

    /// Cote : lignes d'attache (avec dépassement), ligne de cote fléchée, mesure au-dessus.
    func drawDimension(_ s: Shape, in ctx: inout GraphicsContext) {
        guard let g = s.dimension else { return }
        let a = toScreen(g.a), b = toScreen(g.b), a2 = toScreen(g.a2), b2 = toScreen(g.b2)
        let shading = GraphicsContext.Shading.color(s.line.displayColor)
        let style = s.line.strokeStyle(zoom: zoom)
        if s.line.dash != .none {
            // Lignes d'attache : petit jeu côté forme, dépassement de 4 pt au-delà de la ligne de cote.
            let len = a.distance(to: a2)
            if len > 0.5 {
                let ux = (a2.x - a.x) / len, uy = (a2.y - a.y) / len
                let gap: CGFloat = 2 * zoom, over: CGFloat = 4 * zoom
                var ext = Path()
                ext.move(to: CGPoint(x: a.x + ux * gap, y: a.y + uy * gap))
                ext.addLine(to: CGPoint(x: a2.x + ux * over, y: a2.y + uy * over))
                ext.move(to: CGPoint(x: b.x + ux * gap, y: b.y + uy * gap))
                ext.addLine(to: CGPoint(x: b2.x + ux * over, y: b2.y + uy * over))
                ctx.stroke(ext, with: shading, style: style)
            }
            var dim = Path()
            dim.move(to: a2)
            dim.addLine(to: b2)
            ctx.stroke(dim, with: shading, style: style)
        }
        drawArrow(s.line.beginArrow, tip: a2, from: b2, style: s.line, in: &ctx)
        drawArrow(s.line.endArrow, tip: b2, from: a2, style: s.line, in: &ctx)

        guard editingShapeID != s.id, let label = ctx.resolveSymbol(id: s.id) else { return }
        var tc = ctx
        tc.translateBy(x: (a2.x + b2.x) / 2, y: (a2.y + b2.y) / 2)
        tc.rotate(by: .radians(Double(Self.readableAngle(a2, b2))))
        tc.draw(label, at: CGPoint(x: s.textOffset.x * zoom, y: (s.textOffset.y - 2) * zoom), anchor: .bottom)
    }

}

/// Vue d'une page pour l'export (PDF, PNG, impression) : fond blanc, sans grille ni sélection.
struct ExportPageView: View {
    let painter: DiagramPainter
    let size: CGSize

    var body: some View {
        Canvas { ctx, _ in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            painter.drawContent(&ctx)
        } symbols: {
            ForEach(painter.labelledShapes) { s in
                painter.labelView(s).tag(s.id)
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .light)
    }
}

/// Géométrie d'une pointe de flèche (coordonnées écran) : tracé et remplissage (sinon trait).
func arrowHead(_ type: ArrowHead, tip: CGPoint, from: CGPoint, size: CGFloat) -> (path: Path, filled: Bool)? {
    guard type != .none else { return nil }
    let len = tip.distance(to: from)
    guard len > 0.01 else { return nil }
    let ux = (tip.x - from.x) / len, uy = (tip.y - from.y) / len
    let half = size * 0.45
    func at(_ back: CGFloat, _ side: CGFloat) -> CGPoint {
        CGPoint(x: tip.x - ux * back - uy * side, y: tip.y - uy * back + ux * side)
    }
    var p = Path()
    switch type {
    case .none:
        return nil
    case .filled:
        p.addLines([tip, at(size, half), at(size, -half)])
        p.closeSubpath()
        return (p, true)
    case .open:
        p.move(to: at(size, half))
        p.addLine(to: tip)
        p.addLine(to: at(size, -half))
        return (p, false)
    case .circle:
        let r = size * 0.32
        let c = at(r, 0)
        return (Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), true)
    case .diamond:
        p.addLines([tip, at(size / 2, half * 0.8), at(size, 0), at(size / 2, -half * 0.8)])
        p.closeSubpath()
        return (p, true)
    }
}
