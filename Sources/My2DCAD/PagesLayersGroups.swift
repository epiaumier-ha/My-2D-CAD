import Foundation

// MARK: - Pages

@MainActor
extension DocumentStore {
    var pageCount: Int { document.pages.count }

    /// Nom libre pour une nouvelle page : « Page N ».
    private func nextPageName() -> String {
        var n = document.pages.count + 1
        let names = Set(document.pages.map(\.name))
        while names.contains("Page \(n)") { n += 1 }
        return "Page \(n)"
    }

    func addPage() {
        guard document.pages.count < CADDocument.maxPages else { return }
        // Comme Visio : la nouvelle page reprend la feuille, la grille, l'unité et l'échelle de la page affichée.
        var page = Diagram(name: nextPageName())
        let current = doc
        page.unit = current.unit
        page.scale = current.scale
        page.precision = current.precision
        page.defaultRouting = current.defaultRouting
        page.pageSetup = current.pageSetup
        page.grid = current.grid
        let index = currentPage + 1
        performDocument { $0.pages.insert(page, at: index) }
        selectPage(index)
    }

    /// Duplique une page (nouveaux identifiants pour la page, ses formes, connecteurs et calques).
    func duplicatePage(_ index: Int) {
        guard document.pages.indices.contains(index), document.pages.count < CADDocument.maxPages else { return }
        let source = document.pages[index]
        let total = document.pages.reduce(0) { $0 + $1.shapes.count }
        guard total + source.shapes.count <= DiagramIO.maxShapes else { return }
        var copy = source
        copy.id = UUID()
        copy.name = String((source.name + " (copie)").prefix(DiagramIO.maxNameLength))
        var layerMap: [UUID: UUID] = [:]
        for i in copy.layers.indices {
            let n = UUID(); layerMap[copy.layers[i].id] = n; copy.layers[i].id = n
        }
        copy.activeLayerID = copy.activeLayerID.flatMap { layerMap[$0] }
        var shapeMap: [UUID: UUID] = [:]
        var groupMap: [UUID: UUID] = [:]
        for i in copy.shapes.indices {
            let n = UUID(); shapeMap[copy.shapes[i].id] = n; copy.shapes[i].id = n
            copy.shapes[i].layerID = copy.shapes[i].layerID.flatMap { layerMap[$0] }
            if let g = copy.shapes[i].groupID {
                if groupMap[g] == nil { groupMap[g] = UUID() }
                copy.shapes[i].groupID = groupMap[g]
            }
        }
        for i in copy.shapes.indices where !copy.shapes[i].glue.isEmpty {
            copy.shapes[i].glue = copy.shapes[i].glue.compactMap { g in
                guard let target = shapeMap[g.shape] else { return nil }
                var copied = g
                copied.shape = target
                return copied
            }
        }
        for i in copy.connectors.indices {
            copy.connectors[i].id = UUID()
            copy.connectors[i].fromShape = shapeMap[copy.connectors[i].fromShape] ?? copy.connectors[i].fromShape
            copy.connectors[i].toShape = shapeMap[copy.connectors[i].toShape] ?? copy.connectors[i].toShape
        }
        performDocument { $0.pages.insert(copy, at: index + 1) }
        selectPage(index + 1)
    }

    /// Supprime une page (la dernière page restante ne peut pas être supprimée).
    func deletePage(_ index: Int) {
        guard document.pages.count > 1, document.pages.indices.contains(index) else { return }
        if editingShapeID != nil { commitTextEditing() }
        selection = []
        let newCurrent = index < currentPage || currentPage == document.pages.count - 1
            ? max(currentPage - 1, 0) : currentPage
        performDocument { $0.pages.remove(at: index) }
        setCurrentPageAfterStructureChange(newCurrent)
    }

    func renamePage(_ index: Int, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(DiagramIO.maxNameLength))
        guard document.pages.indices.contains(index), !trimmed.isEmpty else { return }
        performDocument { $0.pages[index].name = trimmed }
    }

    /// Déplace une page vers la gauche (-1) ou la droite (+1).
    func movePage(_ index: Int, by delta: Int) {
        let target = index + delta
        guard document.pages.indices.contains(index), document.pages.indices.contains(target) else { return }
        let wasCurrent = index == currentPage
        performDocument { $0.pages.swapAt(index, target) }
        if wasCurrent { setCurrentPageAfterStructureChange(target) }
    }

    func selectNextPage() { selectPage(min(currentPage + 1, document.pages.count - 1)) }
    func selectPreviousPage() { selectPage(max(currentPage - 1, 0)) }
}

// MARK: - Calques

@MainActor
extension DocumentStore {
    func addLayer() {
        guard doc.layers.count < DiagramIO.maxLayers else { return }
        var n = doc.layers.count + 1
        let names = Set(doc.layers.map(\.name))
        while names.contains("Calque \(n)") { n += 1 }
        let layer = Layer(name: "Calque \(n)")
        perform { d in
            d.layers.append(layer)
            d.activeLayerID = layer.id
        }
    }

    /// Supprime un calque : ses formes sont conservées et passent « sans calque ».
    func deleteLayer(_ id: UUID) {
        perform { d in
            d.layers.removeAll { $0.id == id }
            for i in d.shapes.indices where d.shapes[i].layerID == id { d.shapes[i].layerID = nil }
            if d.activeLayerID == id { d.activeLayerID = d.layers.first?.id }
        }
        pruneSelection()
    }

    func updateLayer(_ id: UUID, key: String, _ change: (inout Layer) -> Void) {
        guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
        var layer = doc.layers[i]
        change(&layer)
        layer.name = String(layer.name.prefix(DiagramIO.maxNameLength))
        guard layer != doc.layers[i] else { return }
        perform { $0.layers[i] = layer }
        pruneSelection()
    }

    func setActiveLayer(_ id: UUID?) {
        guard id == nil || doc.layer(id) != nil else { return }
        perform { $0.activeLayerID = id }
    }

    /// Place les formes sélectionnées sur un calque (nil : sans calque).
    func assignSelection(toLayer id: UUID?) {
        guard id == nil || doc.layer(id) != nil else { return }
        editSelection(key: "layer", shapes: { $0.layerID = id })
        pruneSelection()
    }

    /// Calque commun des formes sélectionnées (nil si aucun ou s'ils diffèrent).
    var selectionLayerID: UUID?? {
        let ids = Set(selectedShapes.map(\.layerID))
        return ids.count == 1 ? ids.first : nil
    }
}

// MARK: - Groupes

@MainActor
extension DocumentStore {
    /// Ajoute à un ensemble d'identifiants toutes les formes des groupes concernés.
    func expandedToGroups(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(doc.shapes.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !groups.isEmpty else { return ids }
        let d = doc
        return ids.union(d.shapes.filter { s in
            (s.groupID.map { groups.contains($0) } ?? false) && d.isSelectable(s)
        }.map(\.id))
    }

    var canGroup: Bool { selectedShapes.count >= 2 }

    var canUngroup: Bool { selectedShapes.contains { $0.groupID != nil } }

    /// Grouper (⌘G) : les formes sélectionnées forment un seul groupe (les anciens groupes sont fusionnés).
    func groupSelection() {
        guard canGroup else { return }
        let group = UUID()
        editSelection(key: "group-\(group)", shapes: { $0.groupID = group })
    }

    /// Dissocier (⇧⌘G).
    func ungroupSelection() {
        guard canUngroup else { return }
        editSelection(key: "ungroup-\(UUID())", shapes: { $0.groupID = nil })
    }

    /// Groupes entièrement sélectionnés, avec leur rectangle englobant (pour l'affichage).
    var selectedGroupBounds: [CGRect] {
        let shapes = selectedShapes
        let groups = Dictionary(grouping: shapes.filter { $0.groupID != nil }, by: { $0.groupID! })
        return groups.values.compactMap { members in
            guard members.count > 1, let first = members.first else { return nil }
            return members.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        }
    }
}
