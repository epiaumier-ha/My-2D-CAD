import SwiftUI
import AppKit

private enum Handle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

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
    case resizing(id: UUID, handle: Handle, original: CGRect)
    case drawing(kind: ShapeKind, start: CGPoint, current: CGPoint)
    case connecting(from: UUID, port: Int, current: CGPoint)
    case marquee(start: CGPoint, current: CGPoint, additive: Bool)
    case panning(startOffset: CGSize)
}

private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

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

    private func handleHit(_ shape: Shape, at screen: CGPoint) -> Handle? {
        let r = store.toScreen(shape.rect)
        return Handle.allCases.first { $0.point(in: r).distance(to: screen) <= 8 }
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
            if let s = store.singleSelectedShape, let h = handleHit(s, at: screen) {
                interaction = .resizing(id: s.id, handle: h, original: s.rect)
                return
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

        case .resizing(let id, let handle, let original):
            let a = handle.anchor(in: original)
            let p = store.snap(w)
            let r = CGRect(x: min(a.x, p.x), y: min(a.y, p.y),
                           width: max(abs(p.x - a.x), 10), height: max(abs(p.y - a.y), 10))
            if let i = store.doc.shapes.firstIndex(where: { $0.id == id }) {
                store.doc.shapes[i].rect = r
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
            let hit = Set(store.doc.shapes.filter { $0.rect.intersects(rect) }.map(\.id))
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

    private func drawShape(_ s: Shape, in ctx: inout GraphicsContext) {
        let r = store.toScreen(s.rect)
        if s.kind != .text {
            let p = shapePath(s.kind, r)
            ctx.fill(p, with: .color(s.fill.color))
            ctx.stroke(p, with: .color(Color(white: 0.25)), lineWidth: 1.5)
        }
        let placeholder = s.text.isEmpty && s.kind == .text
        let label = placeholder ? "Texte" : s.text
        if !label.isEmpty {
            let t = Text(label)
                .font(.system(size: 14 * store.zoom))
                .foregroundColor(placeholder ? .gray : .black)
            ctx.draw(t, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
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
        let selectedShapes = store.doc.shapes.filter { store.selection.contains($0.id) }
        for s in selectedShapes {
            let r = store.toScreen(s.rect).insetBy(dx: -3, dy: -3)
            ctx.stroke(Path(r), with: .color(accent), lineWidth: 1.5)
        }
        if let s = store.singleSelectedShape {
            let r = store.toScreen(s.rect)
            for h in Handle.allCases {
                let p = h.point(in: r)
                let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                ctx.fill(Path(box), with: .color(.white))
                ctx.stroke(Path(box), with: .color(accent), lineWidth: 1.5)
            }
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
                let r = store.toScreen(target.rect).insetBy(dx: -3, dy: -3)
                ctx.stroke(Path(r), with: .color(.green), lineWidth: 2)
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
