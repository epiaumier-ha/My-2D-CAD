import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case select, pan, rectangle, ellipse, diamond, text, line, curve, dimension, connector

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Sélection"
        case .pan: return "Main (déplacer la vue)"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .diamond: return "Losange"
        case .text: return "Texte"
        case .line: return "Trait"
        case .curve: return "Courbe"
        case .dimension: return "Cote"
        case .connector: return "Connecteur"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pan: return "hand.raised"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .diamond: return "diamond"
        case .text: return "textformat"
        case .line: return "line.diagonal"
        case .curve: return "scribble"
        case .dimension: return "ruler"
        case .connector: return "arrow.up.right"
        }
    }

    /// Raccourci à une lettre (sans modificateur), comme dans les logiciels de dessin.
    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .pan: return "h"
        case .rectangle: return "r"
        case .ellipse: return "e"
        case .diamond: return "d"
        case .text: return "t"
        case .line: return "l"
        case .curve: return "b"
        case .dimension: return "m"
        case .connector: return "c"
        }
    }

    /// Libellé avec son raccourci, pour les infobulles et les menus.
    var labelWithShortcut: String { "\(label) (\(String(shortcut).uppercased()))" }

    /// Outils regroupés dans le menu « Dessin » de la barre d'outils.
    static let drawingTools: [Tool] = [.rectangle, .ellipse, .diamond, .line, .curve, .dimension]

    var isDrawingTool: Bool { Tool.drawingTools.contains(self) }

    var shapeKind: ShapeKind? {
        switch self {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .diamond: return .diamond
        case .text: return .text
        case .line: return .line
        case .curve: return .curve
        case .dimension: return .dimension
        default: return nil
        }
    }
}

/// Position du pointeur en coordonnées monde, observée uniquement par la barre d'état.
@MainActor
final class PointerTracker: ObservableObject {
    @Published var world: CGPoint?
}

private struct EventBox: @unchecked Sendable {
    let event: NSEvent?
}

@MainActor
final class DocumentStore: ObservableObject {
    static let shared = DocumentStore()

    // Document (pages) et sélection
    @Published var document = CADDocument()
    /// Index de la page affichée.
    @Published private(set) var currentPage = 0

    /// Page affichée : toutes les opérations d'édition portent sur elle.
    var doc: Diagram {
        get { document.pages[currentPage] }
        set { document.pages[currentPage] = newValue }
    }
    @Published var selection: Set<UUID> = []
    @Published var tool: Tool = .select {
        didSet { if tool.isDrawingTool { lastDrawingTool = tool } }
    }
    /// Dernier outil de dessin utilisé (affiché sur le bouton « Dessin »).
    @Published private(set) var lastDrawingTool: Tool = .rectangle

    // Édition du texte d'une forme sur le canevas
    @Published var editingShapeID: UUID?
    @Published var editingText = ""

    // Vue : écran = monde * zoom + offset
    @Published var zoom: CGFloat = 1
    @Published var offset = CGSize(width: 40, height: 40)
    @Published var snapEnabled = true
    /// Repères d'alignement dynamiques pendant le déplacement et le dessin.
    @Published var guidesEnabled = true
    /// Règles graduées au bord du dessin.
    @Published var showRulers = true
    /// Repère en cours de création depuis une règle (aperçu, pas encore dans le document).
    @Published var rulerGuidePreview: GuideLine?
    let gridSize: CGFloat = 20

    // Fichier
    @Published var fileURL: URL?
    @Published var isDirty = false

    /// État enregistré dans l'historique : tout le document (pages comprises) et la page affichée.
    struct HistoryEntry: Equatable {
        var document: CADDocument
        var page: Int
    }

    // Historique (instantanés complets ; les pages non modifiées partagent leur mémoire)
    @Published private(set) var undoStack: [HistoryEntry] = []
    @Published private(set) var redoStack: [HistoryEntry] = []
    private let maxUndo = 100
    private var transactionStart: HistoryEntry?
    private var coalesceKey: String?

    // État non publié
    var canvasSize = CGSize(width: 800, height: 600)
    var hover: CGPoint?
    var mouseInCanvas = false
    /// Nombre de collages successifs depuis la dernière copie (décalage en escalier).
    var pasteCount = 0
    private var monitor: Any?
    /// Position du pointeur pour la barre d'état (objet séparé : le canevas n'est pas redessiné).
    let pointer = PointerTracker()
    /// L'utilisateur a déjà confirmé la fermeture (évite une seconde question en quittant).
    var closeConfirmed = false

    static let fileType = UTType(filenameExtension: "cad2d", conformingTo: .json) ?? .json

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var title: String {
        (fileURL?.lastPathComponent ?? "Sans titre") + (isDirty ? " — modifié" : "")
    }

    var singleSelectedShape: Shape? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return doc.shape(id)
    }

    // MARK: Coordonnées

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height)
    }

    func toScreen(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x * zoom + offset.width, y: r.origin.y * zoom + offset.height,
               width: r.width * zoom, height: r.height * zoom)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom)
    }

    func snap(_ p: CGPoint) -> CGPoint {
        guard snapEnabled else { return p }
        return CGPoint(x: (p.x / gridSize).rounded() * gridSize,
                       y: (p.y / gridSize).rounded() * gridSize)
    }

    // MARK: Historique

    private func snapshot() -> HistoryEntry { HistoryEntry(document: document, page: currentPage) }

    private func push(_ snapshot: HistoryEntry) {
        undoStack.append(snapshot)
        if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
        redoStack.removeAll()
        isDirty = true
        coalesceKey = nil
    }

    /// Modification atomique avec entrée d'historique.
    func perform(_ change: (inout Diagram) -> Void) {
        let before = snapshot()
        change(&doc)
        if before.document != document { push(before) }
    }

    /// Modification du document entier (pages), avec entrée d'historique.
    func performDocument(_ change: (inout CADDocument) -> Void) {
        let before = snapshot()
        var updated = document
        change(&updated)
        guard updated != document, !updated.pages.isEmpty else { return }
        push(before)
        document = updated
        currentPage = min(currentPage, document.pages.count - 1)
    }

    /// Pour les gestes continus (déplacer, redimensionner, dessiner) : une seule entrée d'historique.
    func beginTransaction() { transactionStart = snapshot() }

    func commitTransaction() {
        if let start = transactionStart, start.document != document { push(start) }
        transactionStart = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        editingShapeID = nil
        redoStack.append(snapshot())
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        editingShapeID = nil
        undoStack.append(snapshot())
        restore(next)
    }

    private func restore(_ entry: HistoryEntry) {
        document = entry.document
        currentPage = min(max(entry.page, 0), document.pages.count - 1)
        isDirty = true
        coalesceKey = nil
        pruneSelection()
    }

    /// Retire de la sélection ce qui n'existe plus ou n'est plus sélectionnable (calque masqué ou verrouillé).
    func pruneSelection() {
        let d = doc
        let shapes = Set(d.shapes.filter { d.isSelectable($0) }.map(\.id))
        let connectors = Set(d.connectors.filter { d.isVisible($0) }.map(\.id))
        selection = selection.intersection(shapes.union(connectors))
    }

    /// Après une suppression ou un déplacement de page (l'historique est déjà enregistré).
    func setCurrentPageAfterStructureChange(_ index: Int) {
        currentPage = min(max(index, 0), document.pages.count - 1)
    }

    /// Affiche une autre page (pas d'entrée d'historique).
    func selectPage(_ index: Int) {
        guard document.pages.indices.contains(index), index != currentPage else { return }
        if editingShapeID != nil { commitTextEditing() }
        selection = []
        currentPage = index
    }

    // MARK: Édition

    /// Ajout direct (à utiliser à l'intérieur d'une transaction).
    func insertShape(kind: ShapeKind, rect: CGRect) {
        guard doc.shapes.count < DiagramIO.maxShapes else { return }
        var s = Shape(kind: kind, rect: rect)
        s.layerID = doc.activeLayerID
        doc.shapes.append(s)
        selection = [s.id]
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        perform { $0.removeItems(ids) }
        selection = []
    }

    /// Duplique les formes sélectionnées et les connecteurs qui les relient.
    func duplicateSelection() {
        guard let fragment = makeFragment() else { return }
        insertFragment(fragment, offset: gridSize)
    }

    /// Tout sélectionner, sauf les formes des calques masqués ou verrouillés.
    func selectAll() {
        let d = doc
        selection = Set(d.shapes.filter { d.isSelectable($0) }.map(\.id))
            .union(d.connectors.filter { d.isVisible($0) }.map(\.id))
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        let ids = selection
        perform { d in
            for i in d.shapes.indices where ids.contains(d.shapes[i].id) {
                d.shapes[i].rect.origin.x += dx
                d.shapes[i].rect.origin.y += dy
            }
        }
    }

    /// Modification de la forme sélectionnée depuis l'inspecteur ; les frappes successives
    /// sur un même champ sont regroupées en une seule entrée d'historique.
    func editSelectedShape(key: String, _ change: (inout Shape) -> Void) {
        guard selection.count == 1, let id = selection.first,
              let i = doc.shapes.firstIndex(where: { $0.id == id }) else { return }
        var s = doc.shapes[i]
        change(&s)
        guard s != doc.shapes[i] else { return }
        let k = "\(key)-\(id)"
        if coalesceKey != k {
            push(snapshot())
            coalesceKey = k
        }
        doc.shapes[i] = s
    }

    /// Modification groupée de la sélection depuis l'inspecteur : les réglages successifs d'un même
    /// champ (curseur, saisie) sont regroupés en une seule entrée d'historique.
    func editSelection(key: String, shapes: ((inout Shape) -> Void)? = nil,
                       connectors: ((inout Connector) -> Void)? = nil) {
        let ids = selection
        guard !ids.isEmpty else { return }
        var updated = doc
        if let shapes {
            for i in updated.shapes.indices where ids.contains(updated.shapes[i].id) { shapes(&updated.shapes[i]) }
        }
        if let connectors {
            for i in updated.connectors.indices where ids.contains(updated.connectors[i].id) {
                connectors(&updated.connectors[i])
            }
        }
        guard updated != doc else { return }
        let k = "\(key)-" + ids.map(\.uuidString).sorted().joined(separator: ",")
        if coalesceKey != k {
            push(snapshot())
            coalesceKey = k
        }
        doc = updated
    }

    /// Applique une modification de trait à toute la sélection (formes et connecteurs).
    func editSelectionLineStyle(key: String, _ change: @escaping (inout LineStyle) -> Void) {
        editSelection(key: "line-\(key)",
                      shapes: { if $0.kind != .text { change(&$0.line) } },
                      connectors: { change(&$0.line) })
    }

    /// Applique une modification de mise en forme du texte à toutes les formes sélectionnées.
    func editSelectionTextStyle(key: String, _ change: @escaping (inout TextStyle) -> Void) {
        editSelection(key: "text-\(key)", shapes: { change(&$0.textStyle) })
    }

    /// Termine l'édition d'un champ de texte (recherche, inspecteur) et rend le clavier au dessin.
    /// La valeur en cours de saisie est validée avant de perdre le focus.
    func endTextEditing() {
        guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: Hit-testing

    /// Forme sous le point. Les traits et courbes se saisissent à quelques pixels près ;
    /// `includePaths: false` les ignore (ils n'ont pas de points de connexion).
    func hitShape(at world: CGPoint, includePaths: Bool = true) -> Shape? {
        let tolerance = 6 / zoom
        let d = doc
        return d.shapes.last { s in
            guard d.isSelectable(s) else { return false }
            if s.kind.isPath { return includePaths && s.distanceToPath(world) <= tolerance }
            return s.contains(world)
        }
    }

    func hitConnector(at world: CGPoint) -> Connector? {
        let tolerance = 6 / zoom
        let d = doc
        return d.connectors.last { c in
            guard d.isVisible(c), let pts = d.connectorPoints(c), pts.count > 1 else { return false }
            for i in 0..<(pts.count - 1)
            where distanceFromPoint(world, toSegment: pts[i], pts[i + 1]) <= tolerance {
                return true
            }
            return false
        }
    }

    // MARK: Vue

    func zoom(by factor: CGFloat, around p: CGPoint? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let center = p ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let newZoom = min(max(zoom * factor, 0.1), 8)
        let ratio = newZoom / zoom
        offset = CGSize(width: center.x - (center.x - offset.width) * ratio,
                        height: center.y - (center.y - offset.height) * ratio)
        zoom = newZoom
    }

    /// Zoom à une valeur donnée (1 = 100 %), autour du centre de la vue.
    func setZoom(_ value: CGFloat) {
        guard value.isFinite, value > 0 else { return }
        zoom(by: value / zoom)
    }

    func resetView() {
        zoom = 1
        offset = CGSize(width: 40, height: 40)
    }

    func fitToContent() {
        let visible = doc.shapes.filter { doc.isVisible($0) }
        guard let first = visible.first else { resetView(); return }
        let bounds = visible.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let pad: CGFloat = 40
        let availW = max(canvasSize.width - 2 * pad, 50)
        let availH = max(canvasSize.height - 2 * pad, 50)
        let z = min(min(availW / max(bounds.width, 1), availH / max(bounds.height, 1)), 2)
        zoom = max(z, 0.1)
        offset = CGSize(width: canvasSize.width / 2 - bounds.midX * zoom,
                        height: canvasSize.height / 2 - bounds.midY * zoom)
    }

    // MARK: Fichiers

    func newDocument() {
        guard confirmDiscard() else { return }
        reset(with: CADDocument(), url: nil)
    }

    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            reset(with: try DiagramIO.load(from: url), url: url)
            fitToContent()
        } catch {
            showError("Impossible d'ouvrir le fichier", error)
        }
    }

    func save() {
        if let url = fileURL { _ = write(to: url) } else { saveAs() }
    }

    func saveAs() {
        _ = runSaveAs()
    }

    private func runSaveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Sans titre.cad2d"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        do {
            try DiagramIO.save(document, to: url)
            fileURL = url
            isDirty = false
            return true
        } catch {
            showError("Impossible d'enregistrer le fichier", error)
            return false
        }
    }

    private func reset(with newDocument: CADDocument, url: URL?) {
        editingShapeID = nil
        currentPage = 0
        document = newDocument
        selection = []
        undoStack = []
        redoStack = []
        coalesceKey = nil
        transactionStart = nil
        fileURL = url
        isDirty = false
        tool = .select
        if url == nil { resetView() }
    }

    /// Retourne true si on peut poursuivre (rien à sauver, enregistré, ou abandon accepté).
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Enregistrer les modifications de « \(fileURL?.lastPathComponent ?? "Sans titre") » ?"
        alert.informativeText = "Vos modifications seront perdues si vous ne les enregistrez pas."
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Ne pas enregistrer")
        alert.addButton(withTitle: "Annuler")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = fileURL { return write(to: url) }
            return runSaveAs()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: Événements clavier / molette / pincement

    func installEventMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Le moniteur local est toujours appelé sur le thread principal ; NSEvent n'est pas
            // Sendable, on le fait donc passer dans une boîte explicitement non vérifiée.
            let box = EventBox(event: event)
            return MainActor.assumeIsolated { EventBox(event: self.handle(box.event!)) }.event
        }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        // Dialogues (ouvrir, enregistrer, alertes) et panneaux (nuancier) : on ne touche à rien.
        if NSApp.modalWindow != nil || e.window is NSPanel { return e }
        switch e.type {
        case .rightMouseDown:
            // Clic droit : la forme sous le pointeur est sélectionnée avant l'ouverture du menu contextuel.
            guard mouseInCanvas, let p = hover, editingShapeID == nil else { return e }
            let w = toWorld(p)
            if let s = hitShape(at: w) {
                if !selection.contains(s.id) { selection = [s.id] }
            } else if let c = hitConnector(at: w) {
                if !selection.contains(c.id) { selection = [c.id] }
            } else {
                selection = []
            }
            return e
        case .magnify:
            guard mouseInCanvas else { return e }
            zoom(by: 1 + e.magnification, around: hover)
            return nil
        case .scrollWheel:
            guard mouseInCanvas else { return e }
            // Molette classique : deltas en lignes, bien plus petits que ceux du trackpad.
            let scale: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            let dx = e.scrollingDeltaX * scale, dy = e.scrollingDeltaY * scale
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                zoom(by: CGFloat(exp(Double(dy) * 0.01)), around: hover)
            } else {
                offset = CGSize(width: offset.width + dx, height: offset.height + dy)
            }
            return nil
        case .keyDown:
            if NSApp.keyWindow?.firstResponder is NSText { return e }
            if !e.modifierFlags.intersection([.command, .control]).isEmpty { return e }
            let step = e.modifierFlags.contains(.option) ? 1 : gridSize
            switch e.keyCode {
            case 51, 117:
                guard !selection.isEmpty else { return e }
                deleteSelection(); return nil
            case 53:
                // Échap : quitte l'outil en cours, puis désélectionne.
                if tool != .select { tool = .select } else { selection = [] }
                return nil
            case 36, 76, 120:
                // Entrée, Entrée du pavé numérique ou F2 : éditer le texte de la forme sélectionnée.
                guard selection.count == 1, let id = selection.first, doc.shape(id) != nil else { return e }
                startTextEditing(id); return nil
            case 123, 124, 125, 126:
                guard !selection.isEmpty else { return e }
                let dx: CGFloat = e.keyCode == 123 ? -step : (e.keyCode == 124 ? step : 0)
                let dy: CGFloat = e.keyCode == 126 ? -step : (e.keyCode == 125 ? step : 0)
                nudgeSelection(dx: dx, dy: dy); return nil
            default:
                // Raccourcis d'outils à une lettre (V, H, C, T, R, E, D, L, B).
                if e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                   let ch = e.charactersIgnoringModifiers?.lowercased().first,
                   let t = Tool.allCases.first(where: { $0.shortcut == ch }) {
                    tool = t
                    return nil
                }
                return e
            }
        default:
            return e
        }
    }
}
