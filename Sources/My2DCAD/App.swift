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
    @Environment(\.colorScheme) private var scheme
    @AppStorage(PanelKey.shapes) private var showShapes = true
    @AppStorage(PanelKey.format) private var showFormat = true
    @AppStorage(PanelKey.assistant) private var showAssistant = false

    var body: some View {
        VStack(spacing: 0) {
            Ribbon()
            // Disposition de Visio : volet Formes à gauche, dessin au centre, volets à droite.
            HStack(spacing: 0) {
                if showShapes {
                    StencilPanel()
                        .frame(width: 220)
                        .background(VisioTheme.pane(scheme))
                    Divider()
                }
                VStack(spacing: 0) {
                    DrawingArea()
                    Divider()
                    PageBar()
                }
                if showAssistant {
                    Divider()
                    AssistantPanel().frame(width: 320)
                }
                if showFormat {
                    Divider()
                    InspectorView()
                        .frame(width: 290)
                        .background(VisioTheme.pane(scheme))
                }
            }
            Divider()
            StatusBar(pointer: store.pointer)
        }
        .navigationTitle(store.title)
        .background(WindowCloseGuard {
            let ok = DocumentStore.shared.confirmDiscard()
            if ok { DocumentStore.shared.closeConfirmed = true }
            return ok
        })
        .onAppear { store.installEventMonitor() }
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Zoom")
    }
}

@main
struct My2DCADApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DocumentStore.shared
    @AppStorage(PanelKey.shapes) private var showShapes = true
    @AppStorage(PanelKey.format) private var showFormat = true
    @AppStorage(PanelKey.assistant) private var showAssistant = false

    var body: some Scene {
        // Fenêtre unique : le document n'est pas partagé entre plusieurs fenêtres.
        Window("My2DCAD", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau") { store.newDocument() }.keyboardShortcut("n")
                Button("Ouvrir…") { store.open() }.keyboardShortcut("o")
                Divider()
                Button("Enregistrer") { store.save() }.keyboardShortcut("s")
                Button("Enregistrer sous…") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Menu("Exporter") {
                    Button("PDF (toutes les pages)…") { store.exportPDF() }.keyboardShortcut("e", modifiers: [.command, .option])
                    Button("PNG (page affichée)…") { store.exportPNG() }
                        .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                    Button("SVG (page affichée)…") { store.exportSVG() }
                }
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
                Button("Couper") { store.cutCommand() }.keyboardShortcut("x")
                Button("Copier") { store.copyCommand() }.keyboardShortcut("c")
                Button("Coller") { store.pasteCommand() }.keyboardShortcut("v")
                Button("Dupliquer") { store.duplicateSelection() }.keyboardShortcut("d")
                    .disabled(store.selection.isEmpty)
                Divider()
                Button("Tout sélectionner") { store.selectAllCommand() }.keyboardShortcut("a")
                Button("Supprimer la sélection") { store.deleteCommand() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(store.selection.isEmpty)
            }
            // Mêmes rubriques que les onglets du ruban : Affichage, Insertion, Forme, Outils, Page.
            CommandMenu("Affichage") {
                Toggle("Volet Formes", isOn: $showShapes).keyboardShortcut("1", modifiers: [.command, .option])
                Toggle("Volet Format de la forme", isOn: $showFormat).keyboardShortcut("2", modifiers: [.command, .option])
                Toggle("Assistant IA", isOn: $showAssistant).keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Toggle("Règles", isOn: $store.showRulers).keyboardShortcut("r", modifiers: [.command, .option])
                Toggle("Grille", isOn: Binding(
                    get: { store.doc.grid.visible },
                    set: { v in store.updatePageSettings { $0.grid.visible = v } }))
                    .keyboardShortcut("g", modifiers: [.command, .option])
                Menu("Espacement de la grille") {
                    ForEach(GridDensity.allCases) { density in
                        Button("Variable – \(density.label.lowercased())") {
                            store.updatePageSettings { $0.grid.mode = .variable; $0.grid.density = density }
                        }
                    }
                    Divider()
                    Button("Fixe (réglage dans l'onglet Affichage)") {
                        store.updatePageSettings { $0.grid.mode = .fixed }
                    }
                    Divider()
                    Picker("Unité de la grille", selection: Binding(
                        get: { store.doc.grid.measure },
                        set: { v in store.updatePageSettings { $0.grid.measure = v } })) {
                        Text("Métrique").tag(GridMeasure.metric)
                        Text("Points").tag(GridMeasure.points)
                    }
                }
                Toggle("Magnétisme de la grille", isOn: $store.snapEnabled)
                Toggle("Repères d'alignement dynamiques", isOn: $store.guidesEnabled)
                Button("Supprimer tous les repères") { store.removeAllGuides() }
                    .disabled(store.doc.guides.isEmpty)
                Divider()
                Button("Zoom avant") { store.zoom(by: 1.25) }.keyboardShortcut("+")
                Button("Zoom arrière") { store.zoom(by: 0.8) }.keyboardShortcut("-")
                Button("Zoom 100 %") { store.setZoom(1) }.keyboardShortcut("0")
                Button("Ajuster à la fenêtre") { store.fitToContent() }.keyboardShortcut("9")
                Button("Revenir à l'origine") { store.resetView() }
            }
            CommandMenu("Insertion") {
                Button("Nouvelle page") { store.addPage() }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("Nouveau calque") { store.addLayer() }
                Divider()
                Button("Zone de texte") { store.tool = .text }
                Button("Connecteur") { store.tool = .connector }
                Menu("Forme") {
                    ForEach(Tool.drawingTools) { tool in
                        Button(tool.label) { store.tool = tool }
                    }
                }
                Menu("Cote") {
                    ForEach(StencilCatalog.libraries.first(where: { $0.id == "dimensions" })?.items ?? []) { item in
                        Button(item.name) { store.insertStencil(item, centeredAt: store.visibleCenter) }
                    }
                }
                Divider()
                Button("Dessin SVG…") { store.importSVG() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Forme") {
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
                Menu("Faire pivoter") {
                    Button("À droite de 90°") { store.rotateSelection(by: 90) }
                        .keyboardShortcut("r", modifiers: .control)
                    Button("À gauche de 90°") { store.rotateSelection(by: -90) }
                        .keyboardShortcut("l", modifiers: .control)
                }
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
                Button("Rétablir le bloc de texte") { store.resetTextBlocks() }
                    .disabled(store.selectedShapes.isEmpty)
                Button("Décoller la cote") { store.unglueSelection() }
                    .disabled(!store.selectionHasGlue)
                Button("Inverser le sens du connecteur") { store.reverseSelectedConnectors() }
                    .disabled(store.selection.isEmpty)
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
            CommandMenu("Page") {
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
            }
        }
        Settings {
            AssistantSettingsView()
        }
    }
}
