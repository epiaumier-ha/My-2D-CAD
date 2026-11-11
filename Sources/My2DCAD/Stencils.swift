import SwiftUI

struct StencilItem: Identifiable {
    let kind: ShapeKind
    let name: String
    let size: CGSize
    var defaultText = ""

    var id: ShapeKind { kind }
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
    ]

    static func item(for kind: ShapeKind) -> StencilItem? {
        for library in libraries {
            if let found = library.items.first(where: { $0.kind == kind }) { return found }
        }
        return nil
    }

    static func dragPayload(_ item: StencilItem) -> String { dragPrefix + item.kind.rawValue }

    /// Les données glissées peuvent venir d'une autre application : on n'accepte qu'un identifiant connu.
    static func item(fromDragPayload payload: String) -> StencilItem? {
        guard payload.count <= 100, payload.hasPrefix(dragPrefix) else { return nil }
        guard let kind = ShapeKind(rawValue: String(payload.dropFirst(dragPrefix.count))) else { return nil }
        return item(for: kind)
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
        let shape = Shape(kind: item.kind, rect: CGRect(origin: origin, size: item.size), text: item.defaultText)
        perform { $0.shapes.append(shape) }
        selection = [shape.id]
        tool = .select
    }
}

// MARK: - Panneau des bibliothèques

struct StencilPanel: View {
    @State private var search = ""
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("Rechercher une forme", text: $search)
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
            get: { !search.isEmpty || !collapsed.contains(id) },
            set: { open in
                if open { collapsed.remove(id) } else { collapsed.insert(id) }
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
        .onTapGesture { store.insertStencil(item, centeredAt: store.visibleCenter) }
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
            let parts = item.kind.paths(in: r)
            let line = GraphicsContext.Shading.color(.primary)
            if !parts.fill.isEmpty {
                ctx.fill(parts.fill, with: .color(RGBA.defaultFill.color))
                ctx.stroke(parts.fill, with: line, lineWidth: 1)
            }
            if !parts.stroke.isEmpty {
                ctx.stroke(parts.stroke, with: line, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
