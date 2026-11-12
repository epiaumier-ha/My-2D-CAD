import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nécessaire pour qu'un exécutable SwiftPM ait un menu et reçoive le clavier.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = DocumentStore.shared
        if store.closeConfirmed { return .terminateNow }
        return store.confirmDiscard() ? .terminateNow : .terminateCancel
    }
}

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var showStencils = true

    var body: some View {
        HStack(spacing: 0) {
            if showStencils {
                StencilPanel().frame(width: 210)
                Divider()
            }
            VStack(spacing: 0) {
                DrawingArea()
                Divider()
                PageBar()
                Divider()
                StatusBar(pointer: store.pointer)
            }
            Divider()
            InspectorView().frame(width: 290)
        }
        .navigationTitle(store.title)
        .background(WindowCloseGuard {
            let ok = DocumentStore.shared.confirmDiscard()
            if ok { DocumentStore.shared.closeConfirmed = true }
            return ok
        })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showStencils.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help("Afficher ou masquer les bibliothèques de formes")
            }
            ToolbarItem(placement: .principal) {
                ToolStrip()
            }
            ToolbarItemGroup {
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Annuler (⌘Z)").disabled(!store.canUndo)
                Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Rétablir (⇧⌘Z)").disabled(!store.canRedo)
                Toggle(isOn: $store.snapEnabled) { Image(systemName: "squareshape.split.2x2.dotted") }
                    .help("Magnétisme de la grille")
                ZoomMenu()
            }
        }
        .onAppear { store.installEventMonitor() }
    }
}

/// Outils groupés façon Visio : Pointeur, Main, Connecteur, Texte, puis un menu « Dessin ».
struct ToolStrip: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        HStack(spacing: 2) {
            toolButton(.select)
            toolButton(.pan)
            Divider().frame(height: 18).padding(.horizontal, 4)
            toolButton(.connector)
            toolButton(.text)
            Divider().frame(height: 18).padding(.horizontal, 4)
            drawingMenu
        }
    }

    private func toolButton(_ t: Tool) -> some View {
        Button { store.tool = t } label: {
            Image(systemName: t.symbol)
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(store.tool == t ? Color.accentColor.opacity(0.25) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(t.labelWithShortcut)
    }

    /// Bouton partagé : un clic reprend le dernier outil de dessin, la flèche ouvre la liste.
    private var drawingMenu: some View {
        let current = store.lastDrawingTool
        return Menu {
            ForEach(Tool.drawingTools) { t in
                Button { store.tool = t } label: { Label(t.labelWithShortcut, systemImage: t.symbol) }
            }
        } label: {
            Image(systemName: current.symbol)
        } primaryAction: {
            store.tool = current
        }
        .frame(width: 52)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(store.tool.isDrawingTool ? Color.accentColor.opacity(0.25) : Color.clear))
        .help("Dessin : \(current.labelWithShortcut) — cliquez sur la flèche pour choisir une autre forme")
    }
}

struct ZoomMenu: View {
    @EnvironmentObject var store: DocumentStore
    private let presets: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 4]

    var body: some View {
        Menu {
            ForEach(presets, id: \.self) { z in
                Button("\(Int(z * 100)) %") { store.setZoom(z) }
            }
            Divider()
            Button("Ajuster à la fenêtre") { store.fitToContent() }
        } label: {
            Text("\(Int((store.zoom * 100).rounded())) %").monospacedDigit()
        }
        .frame(width: 80)
        .help("Zoom")
    }
}

/// Si un champ de texte est en cours d'édition, la commande lui est transmise
/// (copier-coller de texte dans l'inspecteur) ; sinon elle s'applique au dessin.
@MainActor
private func forwardToTextEditor(_ action: Selector) -> Bool {
    guard let editor = NSApp.keyWindow?.firstResponder as? NSText else { return false }
    return NSApp.sendAction(action, to: editor, from: nil)
}

@main
struct My2DCADApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DocumentStore.shared

    var body: some Scene {
        // Fenêtre unique : le document n'est pas partagé entre plusieurs fenêtres.
        Window("My2DCAD", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1050, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau") { store.newDocument() }.keyboardShortcut("n")
                Button("Ouvrir…") { store.open() }.keyboardShortcut("o")
                Divider()
                Button("Enregistrer") { store.save() }.keyboardShortcut("s")
                Button("Enregistrer sous…") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Exporter en PDF…") { store.exportPDF() }.keyboardShortcut("e", modifiers: [.command, .option])
                Button("Exporter la page en PNG…") { store.exportPNG() }
                    .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                Button("Exporter la page en SVG…") { store.exportSVG() }
                Divider()
                Button("Importer un SVG…") { store.importSVG() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .printItem) {
                Button("Imprimer…") { store.printDocument() }.keyboardShortcut("p")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Annuler") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
                Button("Rétablir") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Couper") {
                    if !forwardToTextEditor(#selector(NSText.cut(_:))) { store.cutSelection() }
                }.keyboardShortcut("x")
                Button("Copier") {
                    if !forwardToTextEditor(#selector(NSText.copy(_:))) { store.copySelection() }
                }.keyboardShortcut("c")
                Button("Coller") {
                    if !forwardToTextEditor(#selector(NSText.paste(_:))) { store.paste() }
                }.keyboardShortcut("v")
                Divider()
                Button("Dupliquer") { store.duplicateSelection() }.keyboardShortcut("d")
                Button("Tout sélectionner") {
                    if !forwardToTextEditor(#selector(NSText.selectAll(_:))) { store.selectAll() }
                }.keyboardShortcut("a")
                Button("Supprimer la sélection") {
                    if !forwardToTextEditor(#selector(NSText.delete(_:))) { store.deleteSelection() }
                }
                .disabled(store.selection.isEmpty)
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandMenu("Disposition") {
                Menu("Aligner") {
                    ForEach(ShapeAlignment.allCases, id: \.self) { a in
                        Button(a.label) { store.align(a) }
                    }
                }
                .disabled(store.selectedShapes.count < 2)
                Menu("Répartir") {
                    Button("Horizontalement") { store.distribute(.horizontal) }
                    Button("Verticalement") { store.distribute(.vertical) }
                }
                .disabled(store.selectedShapes.count < 3)
                Divider()
                Button("Faire pivoter à droite (90°)") { store.rotateSelection(by: 90) }
                    .keyboardShortcut("r", modifiers: .control)
                    .disabled(store.selectedShapes.isEmpty)
                Button("Faire pivoter à gauche (90°)") { store.rotateSelection(by: -90) }
                    .keyboardShortcut("l", modifiers: .control)
                    .disabled(store.selectedShapes.isEmpty)
                Divider()
                Button("Grouper") { store.groupSelection() }
                    .keyboardShortcut("g").disabled(!store.canGroup)
                Button("Dissocier") { store.ungroupSelection() }
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!store.canUngroup)
                Divider()
                Button(StackingOrder.front.label) { store.reorderSelection(.front) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button(StackingOrder.forward.label) { store.reorderSelection(.forward) }
                    .keyboardShortcut("]", modifiers: .command)
                Button(StackingOrder.backward.label) { store.reorderSelection(.backward) }
                    .keyboardShortcut("[", modifiers: .command)
                Button(StackingOrder.back.label) { store.reorderSelection(.back) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Menu("Opérations") {
                    ForEach(ShapeOperation.allCases) { op in
                        Button(op.label) { store.runOperation(op) }.disabled(!store.canApply(op))
                    }
                }
                .disabled(store.selection.isEmpty)
                Divider()
                Button("Inverser le sens du connecteur") { store.reverseSelectedConnectors() }
            }
            CommandMenu("Outils") {
                // ⌘1 à ⌘9 pour les neuf premiers outils ; les suivants n'ont que leur lettre.
                ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, tool in
                    if index < 9 {
                        Button(tool.labelWithShortcut) { store.tool = tool }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    } else {
                        Button(tool.labelWithShortcut) { store.tool = tool }
                    }
                }
            }
            CommandMenu("Affichage") {
                Button("Zoom avant") { store.zoom(by: 1.25) }.keyboardShortcut("+")
                Button("Zoom arrière") { store.zoom(by: 0.8) }.keyboardShortcut("-")
                Button("Zoom 100 %") { store.setZoom(1) }.keyboardShortcut("0")
                Button("Revenir à l'origine") { store.resetView() }
                Button("Ajuster à la fenêtre") { store.fitToContent() }.keyboardShortcut("9")
                Toggle("Magnétisme de la grille", isOn: $store.snapEnabled)
                Toggle("Repères d'alignement dynamiques", isOn: $store.guidesEnabled)
                Toggle("Règles", isOn: $store.showRulers).keyboardShortcut("r", modifiers: [.command, .option])
                Button("Supprimer tous les repères") { store.removeAllGuides() }
                    .disabled(store.doc.guides.isEmpty)
            }
            CommandMenu("Page") {
                Button("Nouvelle page") { store.addPage() }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("Dupliquer la page") { store.duplicatePage(store.currentPage) }
                Button("Supprimer la page") { store.deletePage(store.currentPage) }
                    .disabled(store.pageCount == 1)
                Divider()
                Button("Page précédente") { store.selectPreviousPage() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(store.currentPage == 0)
                Button("Page suivante") { store.selectNextPage() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(store.currentPage == store.pageCount - 1)
                Divider()
                Button("Nouveau calque") { store.addLayer() }
            }
        }
    }
}
