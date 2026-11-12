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
    case moving(origins: [UUID: CGPoint], start: CGPoint, primary: UUID, bounds: CGRect)
    case resizing(original: Shape, handle: Handle)
    case editingPoint(id: UUID, index: Int)
    case reconnecting(id: UUID, start: Bool, current: CGPoint)
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
    @State private var gestureActive = false
    /// Dernier clic sur une forme, pour détecter le double-clic.
    @State private var lastClick: (id: UUID, time: TimeInterval)?
    @FocusState private var editorFocused: Bool
    /// Repères d'alignement affichés pendant le geste en cours.
    @State private var guides: [AlignmentGuide] = []
    /// Rectangles des autres formes, cibles des repères (calculés au début du geste).
    @State private var guideTargets: [CGRect] = []

    /// Moteur de dessin de la page affichée.
    private var painter: DiagramPainter {
        DiagramPainter(diagram: store.doc, zoom: store.zoom, offset: store.offset, editingShapeID: store.editingShapeID)
    }

    private let accent = Color.accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack {
            Canvas { ctx, size in
                render(&ctx, size: size)
            } symbols: {
                // Libellés des formes : vues SwiftUI (police, alignement, retour à la ligne)
                // dessinées par le canevas dans l'ordre des formes.
                ForEach(painter.drawnShapes) { s in
                    painter.labelView(s).tag(s.id)
                }
            }
            .gesture(dragGesture)
            .contextMenu { canvasContextMenu }
            .dropDestination(for: String.self) { items, location in
                guard let payload = items.first,
                      let item = StencilCatalog.item(fromDragPayload: payload) else { return false }
                store.insertStencil(item, centeredAt: store.toWorld(location))
                return true
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    store.hover = p
                    store.mouseInCanvas = true
                    store.pointer.world = store.toWorld(p)
                    cursor(for: store.tool).set()
                case .ended:
                    store.mouseInCanvas = false
                    store.pointer.world = nil
                    NSCursor.arrow.set()
                }
            }
            .onAppear { store.canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in store.canvasSize = newSize }

            textEditorOverlay
            }
        }
        .clipped()
    }

    // MARK: - Éditeur de texte sur place

    /// Champ de saisie posé sur la forme : Entrée valide, ⌥Entrée passe à la ligne, Échap annule.
    @ViewBuilder
    private var textEditorOverlay: some View {
        if let id = store.editingShapeID, let s = store.doc.shape(id) {
            let r = store.toScreen(s.rect)
            let below = s.kind.labelPlacement == .below
            let width = below ? max(r.width * 2, 140) : max(r.width - 8, 100)
            let center = s.kind.isPath
                ? store.toScreen(s.pathMidpoint)
                : (below ? CGPoint(x: r.midX, y: r.maxY + 16 * store.zoom) : CGPoint(x: r.midX, y: r.midY))
            let ts = s.textStyle
            TextField("Texte", text: $store.editingText, axis: .vertical)
                .textFieldStyle(.plain)
                .multilineTextAlignment(ts.alignment.textAlignment)
                .font(.system(size: max(CGFloat(ts.size) * store.zoom, 9), weight: ts.bold ? .bold : .regular))
                .italic(ts.italic)
                .foregroundColor(.black)
                .lineLimit(1...12)
                .padding(4)
                .frame(width: width)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent, lineWidth: 1.5))
                .position(center)
                .focused($editorFocused)
                .onSubmit { store.commitTextEditing() }
                .onExitCommand { store.cancelTextEditing() }
                .onAppear { editorFocused = true }
                .onChange(of: editorFocused) { _, focused in
                    if !focused { store.commitTextEditing() }
                }
                .id(id)
        }
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
                // begin() une seule fois par geste, même si aucune interaction n'a démarré.
                if !gestureActive {
                    gestureActive = true
                    begin(at: v.startLocation)
                }
                update(v)
            }
            .onEnded { v in
                gestureActive = false
                finish(v)
            }
    }

    private func begin(at screen: CGPoint) {
        // Un clic dans le dessin valide le texte en cours et rend le clavier au dessin.
        if store.editingShapeID != nil { store.commitTextEditing() }
        store.endTextEditing()
        let w = store.toWorld(screen)
        store.beginTransaction()
        prepareGuideTargets()

        switch store.tool {
        case .pan:
            NSCursor.closedHand.set()
            interaction = .panning(startOffset: store.offset)

        case .rectangle, .ellipse, .diamond, .text, .line, .curve:
            if let kind = store.tool.shapeKind {
                let p = snapPoint(w)
                interaction = .drawing(kind: kind, start: p, current: p)
            }

        case .connector:
            if let s = store.hitShape(at: w, includePaths: false) {
                interaction = .connecting(from: s.id, port: s.nearestPort(to: w), current: w)
            }

        case .select:
            let additive = NSEvent.modifierFlags.contains(.shift)
            if store.selection.count == 1, let id = store.selection.first,
               let c = store.doc.connectors.first(where: { $0.id == id }),
               let pts = store.doc.connectorPoints(c), let first = pts.first, let last = pts.last {
                // Connecteur sélectionné : ses extrémités se déplacent vers une autre forme.
                if store.toScreen(first).distance(to: screen) <= 8 {
                    interaction = .reconnecting(id: id, start: true, current: w)
                    return
                }
                if store.toScreen(last).distance(to: screen) <= 8 {
                    interaction = .reconnecting(id: id, start: false, current: w)
                    return
                }
            }
            if let s = store.singleSelectedShape, s.kind.isPath {
                // Trait / courbe : poignées des extrémités et du point de contrôle.
                if let index = s.worldPoints.firstIndex(where: { store.toScreen($0).distance(to: screen) <= 8 }) {
                    interaction = .editingPoint(id: s.id, index: index)
                    return
                }
            } else if let s = store.singleSelectedShape {
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
                let now = ProcessInfo.processInfo.systemUptime
                if !additive, let last = lastClick, last.id == s.id, now - last.time <= NSEvent.doubleClickInterval {
                    lastClick = nil
                    store.startTextEditing(s.id)
                    return
                }
                lastClick = (s.id, now)
                // Une forme groupée entraîne tout son groupe.
                let unit = store.expandedToGroups([s.id])
                if additive {
                    if store.selection.contains(s.id) { store.selection.subtract(unit) }
                    else { store.selection.formUnion(unit) }
                } else if !store.selection.contains(s.id) {
                    store.selection = unit
                }
                if store.selection.contains(s.id) {
                    var origins: [UUID: CGPoint] = [:]
                    var bounds: CGRect?
                    for sh in store.doc.shapes where store.selection.contains(sh.id) {
                        origins[sh.id] = sh.rect.origin
                        bounds = bounds.map { $0.union(sh.bounds) } ?? sh.bounds
                    }
                    // Les formes déplacées ne servent pas de repère.
                    let moving = Set(origins.keys)
                    guideTargets = store.doc.shapes
                        .filter { !moving.contains($0.id) && store.doc.isVisible($0) }
                        .prefix(3000).map(\.bounds)
                    interaction = .moving(origins: origins, start: w, primary: s.id, bounds: bounds ?? s.bounds)
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
        case .moving(let origins, let start, let primary, let bounds):
            guard let po = origins[primary] else { return }
            let rawDx = w.x - start.x, rawDy = w.y - start.y
            let snapped = store.snap(CGPoint(x: po.x + rawDx, y: po.y + rawDy))
            var dx = snapped.x - po.x, dy = snapped.y - po.y
            // Repères dynamiques : l'alignement sur une autre forme l'emporte sur la grille.
            guides = []
            if store.guidesEnabled {
                let a = alignmentSnap(moving: bounds.offsetBy(dx: rawDx, dy: rawDy), targets: guideTargets,
                                      tolerance: 6 / store.zoom)
                if let gx = a.dx { dx = rawDx + gx }
                if let gy = a.dy { dy = rawDy + gy }
                guides = a.guides
            }
            for i in store.doc.shapes.indices {
                if let o = origins[store.doc.shapes[i].id] {
                    store.doc.shapes[i].rect.origin = CGPoint(x: o.x + dx, y: o.y + dy)
                }
            }

        case .resizing(let original, let handle):
            // Calcul dans le repère local de la forme, le coin opposé restant fixe.
            let pointer = original.rotation == 0 ? snapPoint(w) : w
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

        case .editingPoint(let id, let index):
            guard let i = shapeIndex(id) else { return }
            var pts = store.doc.shapes[i].worldPoints
            guard pts.indices.contains(index) else { return }
            let isControl = store.doc.shapes[i].kind == .curve && index == 1
            pts[index] = isControl ? w : snapPoint(w)
            store.doc.shapes[i].setWorldPoints(pts)

        case .drawing(let kind, let start, _):
            var end = snapPoint(w)
            if kind == .line && NSEvent.modifierFlags.contains(.shift) {
                // Maj : trait contraint à un multiple de 45°.
                let dx = end.x - start.x, dy = end.y - start.y
                let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                let len = hypot(dx, dy)
                end = CGPoint(x: start.x + cos(angle) * len, y: start.y + sin(angle) * len)
            }
            interaction = .drawing(kind: kind, start: start, current: end)

        case .connecting(let from, let port, _):
            interaction = .connecting(from: from, port: port, current: w)

        case .reconnecting(let id, let start, _):
            interaction = .reconnecting(id: id, start: start, current: w)

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
            guides = []
            store.commitTransaction()
        }
        guard let current = interaction else { return }

        switch current {
        case .drawing(let kind, let start, let end) where kind.isPath:
            // Un simple clic (sans glisser) ne crée rien.
            if start.distance(to: end) * store.zoom >= 5 {
                store.insertPath(kind: kind, from: start, to: end)
            }
            // L'outil reste actif (comme Visio) : Échap ou V pour revenir à la sélection.

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
            if kind == .text, let id = store.selection.first { store.startTextEditing(id) }

        case .connecting(let from, let port, let end):
            if let target = store.hitShape(at: end, includePaths: false), target.id != from {
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

        case .reconnecting(let id, let start, let end):
            if let target = store.hitShape(at: end, includePaths: false) {
                store.reconnect(connector: id, start: start, to: target.id, port: target.nearestPort(to: end))
            }

        case .marquee(let start, let end, let additive):
            let rect = rectBetween(start, end)
            let d = store.doc
            let hit = store.expandedToGroups(Set(d.shapes.filter {
                d.isSelectable($0) && $0.bounds.intersects(rect)
            }.map(\.id)))
            store.selection = additive ? store.selection.union(hit) : hit

        default:
            break
        }
    }

    // MARK: - Rendu

    private func render(_ ctx: inout GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))
        drawGrid(&ctx, size: size)

        painter.drawContent(&ctx)

        if store.tool == .connector {
            for s in store.doc.shapes where !s.kind.isPath && store.doc.isSelectable(s) {
                for p in 0..<Port.count {
                    let pt = store.toScreen(s.portPoint(p))
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)),
                             with: .color(.green))
                }
            }
        }

        drawSelection(&ctx)
        drawGuides(&ctx)
        drawInteractionPreview(&ctx)
    }

    // MARK: - Repères d'alignement

    /// Cibles par défaut (dessin, redimensionnement) : toutes les formes visibles sauf la sélection.
    private func prepareGuideTargets() {
        let sel = store.selection
        guideTargets = store.doc.shapes
            .filter { !sel.contains($0.id) && store.doc.isVisible($0) }
            .prefix(3000).map(\.bounds)
        guides = []
    }

    /// Point aligné : grille, puis repères dynamiques s'ils sont proches (ils l'emportent).
    private func snapPoint(_ w: CGPoint) -> CGPoint {
        var p = store.snap(w)
        guides = []
        guard store.guidesEnabled else { return p }
        let a = alignmentSnap(moving: CGRect(origin: w, size: .zero), targets: guideTargets, tolerance: 6 / store.zoom)
        if let dx = a.dx { p.x = w.x + dx }
        if let dy = a.dy { p.y = w.y + dy }
        guides = a.guides
        return p
    }

    private func drawGuides(_ ctx: inout GraphicsContext) {
        guard !guides.isEmpty else { return }
        let color = Color(red: 0.93, green: 0.2, blue: 0.55)
        var path = Path()
        for g in guides {
            let extra: CGFloat = 12 / store.zoom
            if g.vertical {
                path.move(to: store.toScreen(CGPoint(x: g.position, y: g.from - extra)))
                path.addLine(to: store.toScreen(CGPoint(x: g.position, y: g.to + extra)))
            } else {
                path.move(to: store.toScreen(CGPoint(x: g.from - extra, y: g.position)))
                path.addLine(to: store.toScreen(CGPoint(x: g.to + extra, y: g.position)))
            }
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
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
        kind.paths(in: r).outline
    }

    // MARK: - Menu contextuel et curseurs

    @ViewBuilder
    private var canvasContextMenu: some View {
        Button("Couper") { store.cutSelection() }
        Button("Copier") { store.copySelection() }
        Button("Coller") { store.paste() }
        Button("Dupliquer") { store.duplicateSelection() }
        Button("Supprimer") { store.deleteSelection() }
        Divider()
        Button("Modifier le texte") {
            if store.selection.count == 1, let id = store.selection.first, store.doc.shape(id) != nil {
                store.startTextEditing(id)
            }
        }
        Divider()
        ForEach(StackingOrder.allCases, id: \.self) { order in
            Button(order.label) { store.reorderSelection(order) }
        }
        Divider()
        Button("Faire pivoter à droite (90°)") { store.rotateSelection(by: 90) }
        Button("Inverser le sens du connecteur") { store.reverseSelectedConnectors() }
    }

    private func cursor(for tool: Tool) -> NSCursor {
        switch tool {
        case .select: return .arrow
        case .pan: return .openHand
        case .text: return .iBeam
        case .rectangle, .ellipse, .diamond, .line, .curve, .connector: return .crosshair
        }
    }

    private func drawSelection(_ ctx: inout GraphicsContext) {
        // Connecteurs sélectionnés : surlignage.
        for c in store.doc.connectors where store.selection.contains(c.id) {
            guard let pts = store.doc.connectorPoints(c), pts.count > 1 else { continue }
            var path = Path()
            path.move(to: store.toScreen(pts[0]))
            for p in pts.dropFirst() { path.addLine(to: store.toScreen(p)) }
            ctx.stroke(path, with: .color(accent.opacity(0.35)),
                       style: StrokeStyle(lineWidth: max(CGFloat(c.line.width) * store.zoom, 1) + 6, lineCap: .round))
        }
        // Groupes sélectionnés : cadre en pointillés autour de l'ensemble.
        for b in store.selectedGroupBounds {
            let r = store.toScreen(b).insetBy(dx: -7, dy: -7)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(accent),
                       style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        }
        for s in store.selectedShapes {
            if s.kind.isPath {
                ctx.stroke(painter.screenPath(kind: s.kind, points: s.worldPoints),
                           with: .color(accent.opacity(0.35)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                continue
            }
            let r = store.toScreen(s.rect)
            let outline = Path(r.insetBy(dx: -3, dy: -3)).applying(painter.rotationTransform(s, screenRect: r))
            ctx.stroke(outline, with: .color(accent), lineWidth: 1.5)
        }
        if store.selection.count == 1, let id = store.selection.first,
           let c = store.doc.connectors.first(where: { $0.id == id }),
           let pts = store.doc.connectorPoints(c), let first = pts.first, let last = pts.last {
            for p in [first, last].map({ store.toScreen($0) }) {
                let box = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                ctx.fill(Path(box), with: .color(.white))
                ctx.stroke(Path(box), with: .color(accent), lineWidth: 1.5)
            }
        }
        guard let s = store.singleSelectedShape else { return }

        if s.kind.isPath {
            let pts = s.worldPoints.map { store.toScreen($0) }
            if s.kind == .curve, pts.count == 3 {
                // Lignes de construction vers le point de contrôle.
                var guide = Path()
                guide.move(to: pts[0]); guide.addLine(to: pts[1]); guide.addLine(to: pts[2])
                ctx.stroke(guide, with: .color(accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            for (i, p) in pts.enumerated() {
                let box = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                let handle = (s.kind == .curve && i == 1) ? Path(ellipseIn: box) : Path(box)
                ctx.fill(handle, with: .color(.white))
                ctx.stroke(handle, with: .color(accent), lineWidth: 1.5)
            }
            return
        }

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
        case .drawing(let kind, let start, let end) where kind.isPath:
            let pts = DocumentStore.initialPathPoints(kind: kind, from: start, to: end)
            ctx.stroke(painter.screenPath(kind: kind, points: pts), with: .color(accent), style: dashed)

        case .drawing(let kind, let start, let end):
            let r = store.toScreen(rectBetween(start, end))
            ctx.stroke(shapePath(kind, r), with: .color(accent), style: dashed)

        case .connecting(let from, let port, let end):
            guard let s = store.doc.shape(from) else { return }
            var p = Path()
            p.move(to: store.toScreen(s.portPoint(port)))
            p.addLine(to: store.toScreen(end))
            ctx.stroke(p, with: .color(accent), style: dashed)
            if let target = store.hitShape(at: end, includePaths: false), target.id != from {
                let r = store.toScreen(target.rect)
                let outline = Path(r.insetBy(dx: -3, dy: -3)).applying(painter.rotationTransform(target, screenRect: r))
                ctx.stroke(outline, with: .color(.green), lineWidth: 2)
            }

        case .reconnecting(let id, let start, let end):
            guard let c = store.doc.connectors.first(where: { $0.id == id }),
                  let pts = store.doc.connectorPoints(c), let first = pts.first, let last = pts.last else { return }
            var p = Path()
            p.move(to: store.toScreen(start ? last : first))
            p.addLine(to: store.toScreen(end))
            ctx.stroke(p, with: .color(accent), style: dashed)
            if let target = store.hitShape(at: end, includePaths: false) {
                let r = store.toScreen(target.rect)
                let outline = Path(r.insetBy(dx: -3, dy: -3)).applying(painter.rotationTransform(target, screenRect: r))
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
