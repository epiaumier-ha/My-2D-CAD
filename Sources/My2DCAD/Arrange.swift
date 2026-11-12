import SwiftUI
import AppKit

/// Contenu du presse-papiers : formes + connecteurs reliant deux formes copiées.
struct ClipboardFragment: Codable, Equatable {
    var shapes: [Shape]
    var connectors: [Connector]
}

enum ShapeAlignment: CaseIterable {
    case left, center, right, top, middle, bottom

    var label: String {
        switch self {
        case .left: return "À gauche"
        case .center: return "Au centre"
        case .right: return "À droite"
        case .top: return "En haut"
        case .middle: return "Au milieu"
        case .bottom: return "En bas"
        }
    }

    var symbol: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .center: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .middle: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        }
    }
}

enum DistributionAxis {
    case horizontal, vertical
}

private func roundCoordinate(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }

@MainActor
extension DocumentStore {
    static let pasteboardType = NSPasteboard.PasteboardType("fr.epiaumier.my2dcad.fragment")

    var selectedShapes: [Shape] { doc.shapes.filter { selection.contains($0.id) } }

    private func unionBounds(_ shapes: [Shape]) -> CGRect? {
        guard let first = shapes.first else { return nil }
        return shapes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    // MARK: Copier / coller

    func makeFragment() -> ClipboardFragment? {
        let shapes = selectedShapes
        guard !shapes.isEmpty else { return nil }
        let ids = Set(shapes.map(\.id))
        let connectors = doc.connectors.filter { ids.contains($0.fromShape) && ids.contains($0.toShape) }
        return ClipboardFragment(shapes: shapes, connectors: connectors)
    }

    /// Insère un fragment avec de nouveaux identifiants. Le fragment est validé comme un fichier :
    /// le presse-papiers peut contenir des données venant d'une autre application.
    @discardableResult
    func insertFragment(_ fragment: ClipboardFragment, offset: CGFloat, recordHistory: Bool = true) -> Bool {
        guard !fragment.shapes.isEmpty,
              doc.shapes.count + fragment.shapes.count <= DiagramIO.maxShapes,
              doc.connectors.count + fragment.connectors.count <= DiagramIO.maxConnectors else { return false }

        var idMap: [UUID: UUID] = [:]
        var groupMap: [UUID: UUID] = [:]
        var newShapes: [Shape] = []
        let layerIDs = Set(doc.layers.map(\.id))
        for var s in fragment.shapes {
            let newID = UUID()
            idMap[s.id] = newID
            s.id = newID
            // Les groupes copiés deviennent de nouveaux groupes ; un calque absent de la page
            // (collage depuis une autre page ou un autre document) est remplacé par le calque actif.
            if let g = s.groupID {
                if groupMap[g] == nil { groupMap[g] = UUID() }
                s.groupID = groupMap[g]
            }
            if let l = s.layerID, !layerIDs.contains(l) { s.layerID = doc.activeLayerID }
            s.rect.origin.x += offset
            s.rect.origin.y += offset
            newShapes.append(s)
        }
        let newConnectors = fragment.connectors.compactMap { c -> Connector? in
            guard let a = idMap[c.fromShape], let b = idMap[c.toShape] else { return nil }
            var copy = c   // conserve le style du connecteur
            copy.id = UUID()
            copy.fromShape = a
            copy.toShape = b
            return copy
        }
        do {
            try DiagramIO.validate(Diagram(shapes: newShapes, connectors: newConnectors, layers: doc.layers))
        } catch {
            return false
        }
        if recordHistory {
            perform { d in
                d.shapes.append(contentsOf: newShapes)
                d.connectors.append(contentsOf: newConnectors)
            }
        } else {
            // Dans une transaction en cours (⌥-glisser) : une seule étape d'annulation pour tout le geste.
            var d = doc
            d.shapes.append(contentsOf: newShapes)
            d.connectors.append(contentsOf: newConnectors)
            doc = d
        }
        selection = Set(newShapes.map(\.id))
        return true
    }

    func copySelection() {
        guard let fragment = makeFragment(), let data = try? JSONEncoder().encode(fragment) else {
            NSSound.beep(); return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        pasteCount = 0
    }

    func cutSelection() {
        guard !selectedShapes.isEmpty else { NSSound.beep(); return }
        copySelection()
        deleteSelection()
        pasteCount = -1   // le premier collage après « Couper » reprend la position d'origine
    }

    func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              data.count <= DiagramIO.maxFileSize,
              let fragment = try? JSONDecoder().decode(ClipboardFragment.self, from: data) else {
            NSSound.beep(); return
        }
        pasteCount += 1
        if !insertFragment(fragment, offset: CGFloat(pasteCount) * gridSize) { NSSound.beep() }
    }

    // MARK: Alignement et répartition (sur le rectangle englobant de la sélection)

    func align(_ alignment: ShapeAlignment) {
        let shapes = selectedShapes
        guard shapes.count >= 2, let all = unionBounds(shapes) else { return }
        let ids = selection
        perform { d in
            for i in d.shapes.indices where ids.contains(d.shapes[i].id) {
                let b = d.shapes[i].bounds
                var dx: CGFloat = 0, dy: CGFloat = 0
                switch alignment {
                case .left: dx = all.minX - b.minX
                case .center: dx = all.midX - b.midX
                case .right: dx = all.maxX - b.maxX
                case .top: dy = all.minY - b.minY
                case .middle: dy = all.midY - b.midY
                case .bottom: dy = all.maxY - b.maxY
                }
                d.shapes[i].rect = d.shapes[i].rect.offsetBy(dx: dx, dy: dy)
            }
        }
    }

    /// Espacement égal entre les formes ; les deux formes extrêmes ne bougent pas.
    func distribute(_ axis: DistributionAxis) {
        let shapes = selectedShapes
        guard shapes.count >= 3 else { return }
        let horizontal = axis == .horizontal
        func low(_ r: CGRect) -> CGFloat { horizontal ? r.minX : r.minY }
        func high(_ r: CGRect) -> CGFloat { horizontal ? r.maxX : r.maxY }
        func length(_ r: CGRect) -> CGFloat { horizontal ? r.width : r.height }
        func mid(_ r: CGRect) -> CGFloat { horizontal ? r.midX : r.midY }

        let sorted = shapes.sorted { mid($0.bounds) < mid($1.bounds) }
        let first = sorted[0].bounds, last = sorted[sorted.count - 1].bounds
        let span = high(last) - low(first)
        let total = sorted.reduce(CGFloat(0)) { $0 + length($1.bounds) }
        let gap = (span - total) / CGFloat(sorted.count - 1)

        var deltas: [UUID: CGFloat] = [:]
        var cursor = high(first) + gap
        for s in sorted.dropFirst().dropLast() {
            deltas[s.id] = cursor - low(s.bounds)
            cursor += length(s.bounds) + gap
        }
        perform { d in
            for i in d.shapes.indices {
                guard let delta = deltas[d.shapes[i].id] else { continue }
                d.shapes[i].rect = d.shapes[i].rect.offsetBy(dx: horizontal ? delta : 0,
                                                              dy: horizontal ? 0 : delta)
            }
        }
    }

    // MARK: Rotation

    /// Fait pivoter la sélection d'un bloc autour du centre de son rectangle englobant.
    func rotateSelection(by degrees: Double) {
        let shapes = selectedShapes
        guard degrees.isFinite, let all = unionBounds(shapes) else { return }
        let pivot = CGPoint(x: all.midX, y: all.midY)
        let a = CGFloat(degrees * .pi / 180)
        let ids = selection
        perform { d in
            for i in d.shapes.indices where ids.contains(d.shapes[i].id) {
                if d.shapes[i].kind.isPath {
                    // Traits et courbes : la rotation est appliquée directement aux points.
                    let pts = d.shapes[i].worldPoints.map { $0.rotated(by: a, around: pivot) }
                    d.shapes[i].setWorldPoints(pts.map { CGPoint(x: roundCoordinate($0.x), y: roundCoordinate($0.y)) })
                    continue
                }
                let c = d.shapes[i].center.rotated(by: a, around: pivot)
                let size = d.shapes[i].rect.size
                d.shapes[i].rect.origin = CGPoint(x: roundCoordinate(c.x - size.width / 2),
                                                  y: roundCoordinate(c.y - size.height / 2))
                d.shapes[i].rotation = normalizedAngle(d.shapes[i].rotation + degrees)
            }
        }
    }
}

// MARK: - Ordre de superposition

enum StackingOrder: CaseIterable {
    case front, forward, backward, back

    var label: String {
        switch self {
        case .front: return "Mettre au premier plan"
        case .forward: return "Avancer"
        case .backward: return "Reculer"
        case .back: return "Mettre à l'arrière-plan"
        }
    }

    var symbol: String {
        switch self {
        case .front: return "square.3.layers.3d.top.filled"
        case .forward: return "square.2.layers.3d.top.filled"
        case .backward: return "square.2.layers.3d.bottom.filled"
        case .back: return "square.3.layers.3d.bottom.filled"
        }
    }
}

@MainActor
extension DocumentStore {
    /// Change l'ordre de dessin des formes sélectionnées (l'ordre relatif entre elles est conservé).
    /// Les connecteurs restent toujours sous les formes.
    func reorderSelection(_ order: StackingOrder) {
        let ids = selection
        guard doc.shapes.contains(where: { ids.contains($0.id) }) else { return }
        perform { d in
            switch order {
            case .front:
                let moved = d.shapes.filter { ids.contains($0.id) }
                d.shapes = d.shapes.filter { !ids.contains($0.id) } + moved
            case .back:
                let moved = d.shapes.filter { ids.contains($0.id) }
                d.shapes = moved + d.shapes.filter { !ids.contains($0.id) }
            case .forward:
                // Chaque forme sélectionnée passe au-dessus de sa voisine non sélectionnée.
                var i = d.shapes.count - 2
                while i >= 0 {
                    if ids.contains(d.shapes[i].id) && !ids.contains(d.shapes[i + 1].id) {
                        d.shapes.swapAt(i, i + 1)
                    }
                    i -= 1
                }
            case .backward:
                var i = 1
                while i < d.shapes.count {
                    if ids.contains(d.shapes[i].id) && !ids.contains(d.shapes[i - 1].id) {
                        d.shapes.swapAt(i, i - 1)
                    }
                    i += 1
                }
            }
        }
    }

    /// Inverse le sens des connecteurs sélectionnés (la flèche change d'extrémité).
    func reverseSelectedConnectors() {
        let ids = selection
        perform { d in
            for i in d.connectors.indices where ids.contains(d.connectors[i].id) {
                let c = d.connectors[i]
                d.connectors[i].fromShape = c.toShape
                d.connectors[i].fromPort = c.toPort
                d.connectors[i].toShape = c.fromShape
                d.connectors[i].toPort = c.fromPort
            }
        }
    }

    /// Recolle une extrémité d'un connecteur sur une autre forme (glisser de sa poignée).
    /// Modification directe : à appeler dans une transaction (beginTransaction / commitTransaction).
    @discardableResult
    func reconnect(connector id: UUID, start: Bool, to shape: UUID, port: Int) -> Bool {
        guard let i = doc.connectors.firstIndex(where: { $0.id == id }),
              let target = doc.shape(shape), !target.kind.isPath,
              (0..<Port.count).contains(port) else { return false }
        let c = doc.connectors[i]
        guard (start ? c.toShape : c.fromShape) != shape else { return false }   // pas de boucle sur une forme
        if start {
            doc.connectors[i].fromShape = shape
            doc.connectors[i].fromPort = port
        } else {
            doc.connectors[i].toShape = shape
            doc.connectors[i].toPort = port
        }
        return true
    }

    /// Nom court d'une forme pour l'inspecteur : son texte, sinon son type.
    func shapeLabel(_ id: UUID) -> String {
        guard let s = doc.shape(id) else { return "—" }
        let text = s.text.split(separator: "\n").first.map(String.init) ?? ""
        return text.isEmpty ? s.kind.displayName : text
    }
}

// MARK: - Sélection par rectangle et duplication par glisser

@MainActor
extension DocumentStore {
    /// Sélection par rectangle : formes qui le touchent (groupes complets) et connecteurs entièrement dedans.
    func selectInRect(_ rect: CGRect, additive: Bool) {
        let d = doc
        var hit = expandedToGroups(Set(d.shapes.filter { d.isSelectable($0) && $0.bounds.intersects(rect) }.map(\.id)))
        let context = RoutingContext(d)
        for c in d.connectors where d.isVisible(c) {
            if let pts = d.connectorPoints(c, context: context), !pts.isEmpty, pts.allSatisfy({ rect.contains($0) }) {
                hit.insert(c.id)
            }
        }
        selection = additive ? selection.union(hit) : hit
    }

    /// ⌥-glisser : duplique la sélection sur place (dans la transaction du geste) et retourne
    /// l'identifiant de la copie de `primary`, pour déplacer les copies.
    func duplicateForDrag(primary: UUID) -> UUID? {
        let originals = selectedShapes
        guard let index = originals.firstIndex(where: { $0.id == primary }),
              let fragment = makeFragment(),
              insertFragment(fragment, offset: 0, recordHistory: false) else { return nil }
        let copies = doc.shapes.suffix(originals.count)
        return copies[copies.startIndex + index].id
    }
}
