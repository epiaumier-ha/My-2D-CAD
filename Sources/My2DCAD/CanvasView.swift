import SwiftUI
import AppKit

private enum Handle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Position dans le repère local (forme non pivotée).
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    /// Coin opposé, qui reste fixe pendant le redimensionnement.
    func anchor(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.maxX, y: r.maxY)
        case .topRight: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomRight: return CGPoint(x: r.minX, y: r.minY)
        }
    }
}

private enum Interaction {
    case moving(origins: [UUID: CGPoint], start: CGPoint, primary: UUID)
    case resizing(original: Shape, handle: Handle)
    case rotating(original: Shape, startAngle: CGFloat)
    case drawing(kind: ShapeKind, start: CGPoint, current: CGPoint)
    case connecting(from: UUID, port: Int, current: CGPoint)
    case marquee(start: CGPoint, current: CGPoint, additive: Bool)
    case panning(startOffset: CGSize)
}

private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

/// Distance (en pixels écran) entre le haut de la forme et la poignée de rotation.
private let rotationHandleDistance: CGFloat = 28
private let minimumShapeSize: CGFloat = 10

struct CanvasView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var interaction: Interaction?

    private let accent = Color.accentColor

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                render(&ctx, size: size)
            }
            .gesture(dragGesture)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    store.hover = p
                    store.mouseInCanvas = true
                case .ended:
                    store.mouseInCanvas = false
                }
            }
            .onAppear { store.canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in store.canvasSize = newSize }
        }
        .clipped()
    }

    // MARK: - Poignées

    private func handleScreenPoint(_ s: Shape, _ h: Handle) -> CGPoint {
        store.toScreen(s.toWorld(h.point(in: s.rect)))
    }

    private func topCenterScreenPoint(_ s: Shape) -> CGPoint {
        store.toScreen(s.toWorld(CGPoint(x: s.rect.midX, y: s.rect.minY)))
    }

    private func rotationHandleScreenPoint(_ s: Shape) -> CGPoint {
        let local = CGPoint(x: s.rect.midX, y: s.rect.minY - rotationHandleDistance / store.zoom)
        return store.toScreen(s.toWorld(local))
    }

    private func handleHit(_ s: Shape, at screen: CGPoint) -> Handle? {
        Handle.allCases.first { handleScreenPoint(s, $0).distance(to: screen) <= 8 }
    }

    private func shapeIndex(_ id: UUID) -> Int? {
        store.doc.shapes.firstIndex { $0.id == id }
    }

    // MARK: - Gestes

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if interaction == nil { begin(at: v.startLocation) }
                update(v)
            }
            .onEnded { v in
                finish(v)
            }
    }

    private func begin(at screen: CGPoint) {
        let w = store.toWorld(screen)
        store.beginTransaction()

        switch store.tool {
        case .pan:
            interaction = .panning(startOffset: store.offset)

        case .rectangle, .ellipse, .diamond, .text:
            if let kind = store.tool.shapeKind {
                let p = store.snap(w)
                interaction = .drawing(kind: kind, start: p, current: p)
            }

        case .connector:
            if let s = store.hitShape(at: w) {
                interaction = .connecting(from: s.id, port: s.nearestPort(to: w), current: w)
            }

        case .select:
            let additive = NSEvent.modifierFlags.contains(.shift)
            if let s = store.singleSelectedShape {
                if rotationHandleScreenPoint(s).distance(to: screen) <= 9 {
                    let c = s.center
                    interaction = .rotating(original: s, startAngle: atan2(w.y - c.y, w.x - c.x))
                    return
                }
                if let h = handleHit(s, at: screen) {
                    interaction = .resizing(original: s, handle: h)
                    return
                }
            }
            if let s = store.hitShape(at: w) {
                if additive {
                    if store.selection.contains(s.id) { store.selection.remove(s.id) }
                    else { store.selection.insert(s.id) }
                } else if !store.selection.contains(s.id) {
                    store.selection = [s.id]
                }
                if store.selection.contains(s.id) {
                    var origins: [UUID: CGPoint] = [:]
                    for sh in store.doc.shapes where store.selection.contains(sh.id) {
                        origins[sh.id] = sh.rect.origin
                    }
                    interaction = .moving(origins: origins, start: w, primary: s.id)
                }
            } else if let c = store.hitConnector(at: w) {
                if additive { store.selection.insert(c.id) } else { store.selection = [c.id] }
            } else {
                if !additive { store.selection = [] }
                interaction = .marquee(start: w, current: w, additive: additive)
            }
        }
    }

    private func update(_ v: DragGesture.Value) {
        guard let current = interaction else { return }
        let w = store.toWorld(v.location)

        switch current {
        case .moving(let origins, let start, let primary):
            guard let po = origins[primary] else { return }
            let raw = CGPoint(x: po.x + w.x - start.x, y: po.y + w.y - start.y)
            let snapped = store.snap(raw)
            let dx = snapped.x - po.x, dy = snapped.y - po.y
            for i in store.doc.shapes.indices {
                if let o = origins[store.doc.shapes[i].id] {
                    store.doc.shapes[i].rect.origin = CGPoint(x: o.x + dx, y: o.y + dy)
                }
            }

        case .resizing(let original, let handle):
            // Calcul dans le repère local de la forme, le coin opposé restant fixe.
            let pointer = original.rotation == 0 ? store.snap(w) : w
            let a = handle.anchor(in: original.rect)
            let q = original.toLocal(pointer)
            let width = max(abs(q.x - a.x), minimumShapeSize)
            let height = max(abs(q.y - a.y), minimumShapeSize)
            let localRect = CGRect(x: q.x >= a.x ? a.x : a.x - width,
                                   y: q.y >= a.y ? a.y : a.y - height,
                                   width: width, height: height)
            let newCenter = original.toWorld(CGPoint(x: localRect.midX, y: localRect.midY))
            if let i = shapeIndex(original.id) {
                store.doc.shapes[i].rect = CGRect(x: newCenter.x - width / 2, y: newCenter.y - height / 2,
                                                  width: width, height: height)
            }

        case .rotating(let original, let startAngle):
            let c = original.center
            let currentAngle = atan2(w.y - c.y, w.x - c.x)
            var degrees = original.rotation + Double(currentAngle - startAngle) * 180 / .pi
            // Maj : pas de 15°, sinon précision au dixième de degré.
            degrees = NSEvent.modifierFlags.contains(.shift)
                ? (degrees / 15).rounded() * 15
                : (degrees * 10).rounded() / 10
            if let i = shapeIndex(original.id) {
                store.doc.shapes[i].rotation = normalizedAngle(degrees)
            }

        case .drawing(let kind, let start, _):
            interaction = .drawing(kind: kind, start: start, current: store.snap(w))

        case .connecting(let from, let port, _):
            interaction = .connecting(from: from, port: port, current: w)

        case .marquee(let start, _, let additive):
            interaction = .marquee(start: start, current: w, additive: additive)

        case .panning(let startOffset):
            store.offset = CGSize(width: startOffset.width + v.translation.width,
                                  height: startOffset.height + v.translation.height)
        }
    }

    private func finish(_ v: DragGesture.Value) {
        defer {
            interaction = nil
            store.commitTransaction()
        }
        guard let current = interaction else { return }

        switch current {
        case .drawing(let kind, let start, let end):
            var r = rectBetween(start, end)
            if r.width < 8 || r.height < 8 {
                // Simple clic : forme de taille par défaut centrée sur le point.
                let w: CGFloat = 120
                let h: CGFloat = kind == .text ? 30 : 70
                let o = store.snap(CGPoint(x: start.x - w / 2, y: start.y - h / 2))
                r = CGRect(x: o.x, y: o.y, width: w, height: h)
            }
            store.insertShape(kind: kind, rect: r)
            store.tool = .select

        case .connecting(let from, let port, let end):
            if let target = store.hitShape(at: end), target.id != from {
                let c = Connector(fromShape: from, fromPort: port,
                                  toShape: target.id, toPort: target.nearestPort(to: end))
                let duplicate = store.doc.connectors.contains {
                    $0.fromShape == c.fromShape && $0.fromPort == c.fromPort &&
                    $0.toShape == c.toShape && $0.toPort == c.toPort
                }
                if !duplicate && store.doc.connectors.count < DiagramIO.maxConnectors {
                    store.doc.connectors.append(c)
                    store.selection = [c.id]
                }
            }

        case .marquee(let start, let end, let additive):
            let rect = rectBetween(start, end)
            let hit = Set(store.doc.shapes.filter { $0.bounds.intersects(rect) }.map(\.id))
            store.selection = additive ? store.selection.union(hit) : hit

        default:
            break
        }
    }

    // MARK: - Rendu

    private func render(_ ctx: inout GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))
        drawGrid(&ctx, size: size)

        for c in store.doc.connectors { drawConnector(c, in: &ctx) }
        for s in store.doc.shapes { drawShape(s, in: &ctx) }

        if store.tool == .connector {
            for s in store.doc.shapes {
                for p in 0..<Port.count {
                    let pt = store.toScreen(s.portPoint(p))
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)),
                             with: .color(.green))
                }
            }
        }

        drawSelection(&ctx)
        drawInteractionPreview(&ctx)
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        var step = store.gridSize * store.zoom
        var factor: CGFloat = 1
        while step < 8 { step *= 5; factor *= 5 }
        let world = store.gridSize * factor
        let topLeft = store.toWorld(.zero)
        let bottomRight = store.toWorld(CGPoint(x: size.width, y: size.height))
        guard bottomRight.x - topLeft.x < 100_000, bottomRight.y - topLeft.y < 100_000 else { return }

        var minor = Path()
        var major = Path()
        var gx = (topLeft.x / world).rounded(.down) * world
        var index = Int((topLeft.x / world).rounded(.down))
        while gx <= bottomRight.x {
            let x = store.toScreen(CGPoint(x: gx, y: 0)).x
            if index % 5 == 0 { major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: size.height)) }
            else { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height)) }
            gx += world; index += 1
        }
        var gy = (topLeft.y / world).rounded(.down) * world
        index = Int((topLeft.y / world).rounded(.down))
        while gy <= bottomRight.y {
            let y = store.toScreen(CGPoint(x: 0, y: gy)).y
            if index % 5 == 0 { major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: size.width, y: y)) }
            else { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y)) }
            gy += world; index += 1
        }
        ctx.stroke(minor, with: .color(.gray.opacity(0.12)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(.gray.opacity(0.28)), lineWidth: 0.5)
    }

    private func shapePath(_ kind: ShapeKind, _ r: CGRect) -> Path {
        switch kind {
        case .rectangle, .text:
            return Path(r)
        case .ellipse:
            return Path(ellipseIn: r)
        case .diamond:
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
            return p
        }
    }

    /// Rotation autour du centre du rectangle écran (le zoom est uniforme, l'angle est conservé).
    private func rotationTransform(_ s: Shape, screenRect r: CGRect) -> CGAffineTransform {
        guard s.rotation != 0 else { return .identity }
        return CGAffineTransform(translationX: r.midX, y: r.midY)
            .rotated(by: s.angle)
            .translatedBy(x: -r.midX, y: -r.midY)
    }

    private func drawShape(_ s: Shape, in ctx: inout GraphicsContext) {
        let r = store.toScreen(s.rect)
        if s.kind != .text {
            let p = shapePath(s.kind, r).applying(rotationTransform(s, screenRect: r))
            ctx.fill(p, with: .color(s.fill.color))
            ctx.stroke(p, with: .color(Color(white: 0.25)), lineWidth: 1.5)
        }
        let placeholder = s.text.isEmpty && s.kind == .text
        let label = placeholder ? "Texte" : s.text
        if !label.isEmpty {
            let t = Text(label)
                .font(.system(size: 14 * store.zoom))
                .foregroundColor(placeholder ? .gray : .black)
            var textContext = ctx
            textContext.translateBy(x: r.midX, y: r.midY)
            if s.rotation != 0 { textContext.rotate(by: .radians(Double(s.angle))) }
            textContext.draw(t, at: .zero, anchor: .center)
        }
    }

    private func drawConnector(_ c: Connector, in ctx: inout GraphicsContext) {
        guard let world = store.doc.connectorPoints(c), world.count > 1 else { return }
        let pts = world.map { store.toScreen($0) }
        var path = Path()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        let selected = store.selection.contains(c.id)
        let color: Color = selected ? accent : Color(white: 0.3)
        ctx.stroke(path, with: .color(color), lineWidth: selected ? 2.5 : 1.5)

        // Pointe de flèche orientée selon le dernier segment non nul.
        let tip = pts[pts.count - 1]
        guard let prev = pts.dropLast().last(where: { $0.distance(to: tip) > 0.5 }) else { return }
        let len = tip.distance(to: prev)
        let ux = (tip.x - prev.x) / len, uy = (tip.y - prev.y) / len
        let base = CGPoint(x: tip.x - ux * 10, y: tip.y - uy * 10)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x - uy * 5, y: base.y + ux * 5))
        head.addLine(to: CGPoint(x: base.x + uy * 5, y: base.y - ux * 5))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }

    private func drawSelection(_ ctx: inout GraphicsContext) {
        for s in store.selectedShapes {
            let r = store.toScreen(s.rect)
            let outline = Path(r.insetBy(dx: -3, dy: -3)).applying(rotationTransform(s, screenRect: r))
            ctx.stroke(outline, with: .color(accent), lineWidth: 1.5)
        }
        guard let s = store.singleSelectedShape else { return }

        // Poignée de rotation, reliée au milieu du bord supérieur.
        let top = topCenterScreenPoint(s)
        let knob = rotationHandleScreenPoint(s)
        var stem = Path()
        stem.move(to: top)
        stem.addLine(to: knob)
        ctx.stroke(stem, with: .color(accent), lineWidth: 1)
        let knobRect = CGRect(x: knob.x - 5, y: knob.y - 5, width: 10, height: 10)
        ctx.fill(Path(ellipseIn: knobRect), with: .color(.white))
        ctx.stroke(Path(ellipseIn: knobRect), with: .color(accent), lineWidth: 1.5)

        // Poignées de redimensionnement.
        for h in Handle.allCases {
            let p = handleScreenPoint(s, h)
            let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.fill(Path(box), with: .color(.white))
            ctx.stroke(Path(box), with: .color(accent), lineWidth: 1.5)
        }

        if case .rotating = interaction {
            let label = Text("\(s.rotation, specifier: "%.1f")°").font(.system(size: 11)).foregroundColor(accent)
            ctx.draw(label, at: CGPoint(x: knob.x + 14, y: knob.y), anchor: .leading)
        }
    }

    private func drawInteractionPreview(_ ctx: inout GraphicsContext) {
        guard let interaction else { return }
        let dashed = StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        switch interaction {
        case .drawing(let kind, let start, let end):
            let r = store.toScreen(rectBetween(start, end))
            ctx.stroke(shapePath(kind, r), with: .color(accent), style: dashed)

        case .connecting(let from, let port, let end):
            guard let s = store.doc.shape(from) else { return }
            var p = Path()
            p.move(to: store.toScreen(s.portPoint(port)))
            p.addLine(to: store.toScreen(end))
            ctx.stroke(p, with: .color(accent), style: dashed)
            if let target = store.hitShape(at: end), target.id != from {
                let r = store.toScreen(target.rect)
                let outline = Path(r.insetBy(dx: -3, dy: -3)).applying(rotationTransform(target, screenRect: r))
                ctx.stroke(outline, with: .color(.green), lineWidth: 2)
            }

        case .marquee(let start, let end, _):
            let r = store.toScreen(rectBetween(start, end))
            ctx.fill(Path(r), with: .color(accent.opacity(0.1)))
            ctx.stroke(Path(r), with: .color(accent), style: dashed)

        default:
            break
        }
    }
}
