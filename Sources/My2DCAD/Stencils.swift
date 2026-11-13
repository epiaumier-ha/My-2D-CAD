import SwiftUI

struct StencilItem: Identifiable {
    let kind: ShapeKind
    let name: String
    let size: CGSize
    var defaultText = ""
    /// Style de trait imposé (cotes d'ingénierie ou d'architecture).
    var line: LineStyle?
    /// Variante d'un même type (plusieurs éléments peuvent partager un type de forme).
    var variant = ""

    var id: String { variant.isEmpty ? kind.rawValue : kind.rawValue + "." + variant }
}

struct StencilLibrary: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let items: [StencilItem]
}

enum StencilCatalog {
    /// Préfixe des données glissées : seul un texte qui le porte est accepté par le canevas.
    static let dragPrefix = "my2dcad.stencil:"

    private static func item(_ kind: ShapeKind, _ name: String, _ w: CGFloat, _ h: CGFloat,
                             text: String = "") -> StencilItem {
        StencilItem(kind: kind, name: name, size: CGSize(width: w, height: h), defaultText: text)
    }

    private static func dimension(_ kind: ShapeKind, _ name: String, _ w: CGFloat, _ h: CGFloat,
                                  architectural: Bool) -> StencilItem {
        var line = architectural ? LineStyle.architecturalDimension : LineStyle.dimensionDefault
        // Rayon : une seule flèche, sur le cercle.
        if kind == .radiusDimension { line.beginArrow = .none }
        return StencilItem(kind: kind, name: name + (architectural ? " (architecture)" : " (ingénierie)"),
                           size: CGSize(width: w, height: h), line: line,
                           variant: architectural ? "architecture" : "ingenierie")
    }

    /// Cotation, comme la bibliothèque de Visio : chaque cote existe en style ingénierie (flèches)
    /// et architecture (traits obliques).
    private static let dimensionItems: [StencilItem] = [false, true].flatMap { arch in [
        dimension(.dimensionHorizontal, "Horizontale", 120, 40, architectural: arch),
        dimension(.dimensionVertical, "Verticale", 40, 120, architectural: arch),
        dimension(.dimension, "Alignée", 120, 60, architectural: arch),
        dimension(.angularDimension, "Angulaire", 100, 80, architectural: arch),
        dimension(.radiusDimension, "Rayon", 80, 80, architectural: arch),
        dimension(.diameterDimension, "Diamètre", 80, 80, architectural: arch),
    ] }

    static let libraries: [StencilLibrary] = [
        StencilLibrary(id: "flowchart", name: "Organigramme", symbol: "flowchart", items: [
            item(.rectangle, "Processus", 120, 70),
            item(.diamond, "Décision", 120, 80),
            item(.terminator, "Début / Fin", 120, 50),
            item(.data, "Données", 120, 70),
            item(.document, "Document", 120, 80),
            item(.predefinedProcess, "Sous-processus", 120, 70),
            item(.manualInput, "Saisie manuelle", 120, 70),
            item(.manualOperation, "Opération manuelle", 120, 70),
            item(.preparation, "Préparation", 120, 60),
            item(.database, "Base de données", 80, 90),
            item(.delay, "Délai", 100, 60),
            item(.ellipse, "Connecteur", 40, 40),
            item(.offPageReference, "Renvoi de page", 60, 60),
        ]),
        StencilLibrary(id: "network", name: "Réseau", symbol: "network", items: [
            item(.server, "Serveur", 50, 70, text: "Serveur"),
            item(.workstation, "Ordinateur", 70, 60, text: "Ordinateur"),
            item(.laptop, "Portable", 70, 50, text: "Portable"),
            item(.router, "Routeur", 70, 50, text: "Routeur"),
            item(.networkSwitch, "Commutateur", 90, 40, text: "Switch"),
            item(.accessPoint, "Point d'accès Wi-Fi", 60, 60, text: "Point d'accès"),
            item(.firewall, "Pare-feu", 60, 60, text: "Pare-feu"),
            item(.cloud, "Nuage / Internet", 100, 60, text: "Internet"),
            item(.printer, "Imprimante", 70, 60, text: "Imprimante"),
        ]),
        StencilLibrary(id: "electrical", name: "Électricité", symbol: "bolt", items: [
            item(.resistor, "Résistance", 80, 30),
            item(.capacitor, "Condensateur", 80, 40),
            item(.inductor, "Bobine", 80, 30),
            item(.diode, "Diode", 80, 40),
            item(.battery, "Pile / batterie", 80, 40),
            item(.electricSwitch, "Interrupteur", 80, 40),
            item(.fuse, "Fusible", 80, 30),
            item(.lamp, "Lampe", 80, 40),
            item(.acSource, "Source alternative", 80, 40),
            item(.motor, "Moteur", 80, 40, text: "M"),
            item(.ground, "Terre", 40, 40),
        ]),
        StencilLibrary(id: "dimensions", name: "Cotation", symbol: "ruler", items: dimensionItems),
    ]

    static func item(for kind: ShapeKind) -> StencilItem? {
        for library in libraries {
            if let found = library.items.first(where: { $0.kind == kind }) { return found }
        }
        return nil
    }

    static func dragPayload(_ item: StencilItem) -> String { dragPrefix + item.id }

    /// Les données glissées peuvent venir d'une autre application : on n'accepte qu'un identifiant connu.
    static func item(fromDragPayload payload: String) -> StencilItem? {
        guard payload.count <= 100, payload.hasPrefix(dragPrefix) else { return nil }
        let id = String(payload.dropFirst(dragPrefix.count))
        for library in libraries {
            if let found = library.items.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Forme prête à insérer dans le cadre r (une cote reçoit ses points et son style).
    static func makeShape(_ item: StencilItem, in r: CGRect) -> Shape {
        var shape = Shape(kind: item.kind, rect: r, text: item.defaultText)
        if let line = item.line { shape.line = line }
        if item.kind.isDimension {
            shape.fill = RGBA(r: 0.2, g: 0.2, b: 0.2, a: 1)
            shape.setWorldPoints(initialDimensionPoints(kind: item.kind, in: r))
        }
        return shape
    }
}

@MainActor
extension DocumentStore {
    /// Centre de la zone visible, en coordonnées monde.
    var visibleCenter: CGPoint {
        toWorld(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    func insertStencil(_ item: StencilItem, centeredAt center: CGPoint) {
        let limit = DiagramIO.maxCoordinate / 2
        guard doc.shapes.count < DiagramIO.maxShapes,
              center.x.isFinite, center.y.isFinite, abs(center.x) < limit, abs(center.y) < limit else { return }
        let origin = snap(CGPoint(x: center.x - item.size.width / 2, y: center.y - item.size.height / 2))
        var shape = StencilCatalog.makeShape(item, in: CGRect(origin: origin, size: item.size))
        shape.layerID = doc.activeLayerID
        perform { $0.shapes.append(shape) }
        selection = [shape.id]
        tool = .select
    }
}

// MARK: - Panneau des bibliothèques

struct StencilPanel: View {
    @AppStorage(PanelKey.shapes) private var showShapes = true
    @State private var search = ""
    /// Bibliothèques ouvertes : toutes repliées à l'ouverture de l'application, comme dans Visio.
    @State private var open: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Formes").font(.headline)
                Spacer()
                PanelCollapseButton(.shapes)
                Button { showShapes = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Fermer le volet (⌥⌘1 pour le rouvrir)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            TextField("Rechercher des formes", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(StencilCatalog.libraries) { library in
                        let items = filtered(library)
                        if !items.isEmpty {
                            DisclosureGroup(isExpanded: expanded(library.id)) {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 4)], spacing: 4) {
                                    ForEach(items) { StencilTile(item: $0) }
                                }
                                .padding(.vertical, 4)
                            } label: {
                                Label(library.name, systemImage: library.symbol).font(.headline)
                            }
                        }
                    }
                }
                .padding(8)
            }
            Divider()
            Text("Glissez une forme sur le dessin, ou cliquez pour l'ajouter au centre.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func filtered(_ library: StencilLibrary) -> [StencilItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.items }
        return library.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !search.isEmpty || open.contains(id) },
            set: { isOpen in
                if isOpen { open.insert(id) } else { open.remove(id) }
            })
    }
}

private struct StencilTile: View {
    @EnvironmentObject var store: DocumentStore
    let item: StencilItem

    var body: some View {
        VStack(spacing: 3) {
            StencilPreview(item: item).frame(width: 54, height: 40)
            Text(item.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(4)
        .contentShape(Rectangle())
        .help(item.name)
        .onTapGesture {
            store.endTextEditing()
            store.insertStencil(item, centeredAt: store.visibleCenter)
        }
        .draggable(StencilCatalog.dragPayload(item)) {
            StencilPreview(item: item).frame(width: 64, height: 48)
        }
    }
}

/// Miniature d'une forme, à l'échelle et centrée.
struct StencilPreview: View {
    let item: StencilItem

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width / item.size.width, size.height / item.size.height) * 0.9
            let w = item.size.width * scale, h = item.size.height * scale
            let r = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            let line = GraphicsContext.Shading.color(.primary)
            if item.kind.isDimension {
                drawDimension(&ctx, in: r, shading: line)
                return
            }
            let parts = item.kind.paths(in: r)
            if !parts.fill.isEmpty {
                ctx.fill(parts.fill, with: .color(RGBA.defaultFill.color))
                ctx.stroke(parts.fill, with: line, lineWidth: 1)
            }
            if !parts.stroke.isEmpty {
                ctx.stroke(parts.stroke, with: line, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Miniature d'une cote : le vrai tracé (flèches ou traits obliques), avec le cercle coté
    /// pour le rayon et le diamètre.
    private func drawDimension(_ ctx: inout GraphicsContext, in r: CGRect, shading: GraphicsContext.Shading) {
        let shape = StencilCatalog.makeShape(item, in: r.insetBy(dx: 4, dy: 4))
        guard let l = shape.dimensionLayout else { return }
        var path = Path()
        for (a, b) in l.extensionLines {
            path.move(to: a)
            path.addLine(to: b)
        }
        path.addLines(l.line)
        let p = shape.worldPoints
        if shape.kind == .radiusDimension || shape.kind == .diameterDimension, p.count == 2 {
            let rad = p[0].distance(to: p[1])
            ctx.stroke(Path(ellipseIn: CGRect(x: p[0].x - rad, y: p[0].y - rad, width: 2 * rad, height: 2 * rad)),
                       with: .color(.secondary), lineWidth: 0.75)
        }
        ctx.stroke(path, with: shading, lineWidth: 1)
        for (type, end) in [(shape.line.beginArrow, l.begin), (shape.line.endArrow, l.end)] {
            guard let end, let head = arrowHead(type, tip: end.tip, from: end.from, size: 6) else { continue }
            if head.filled { ctx.fill(head.path, with: shading) } else { ctx.stroke(head.path, with: shading, lineWidth: 1.2) }
        }
    }
}
