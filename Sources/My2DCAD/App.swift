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
        DocumentStore.shared.confirmDiscard() ? .terminateNow : .terminateCancel
    }
}

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        HStack(spacing: 0) {
            CanvasView()
            Divider()
            InspectorView().frame(width: 250)
        }
        .navigationTitle(store.title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Outil", selection: $store.tool) {
                    ForEach(Tool.allCases) { t in
                        Image(systemName: t.symbol).help(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup {
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Annuler").disabled(!store.canUndo)
                Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Rétablir").disabled(!store.canRedo)
                Toggle(isOn: $store.snapEnabled) { Image(systemName: "squareshape.split.2x2.dotted") }
                    .help("Magnétisme de la grille")
                Button { store.fitToContent() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Ajuster à la fenêtre")
            }
        }
        .onAppear { store.installEventMonitor() }
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
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau") { store.newDocument() }.keyboardShortcut("n")
                Button("Ouvrir…") { store.open() }.keyboardShortcut("o")
                Divider()
                Button("Enregistrer") { store.save() }.keyboardShortcut("s")
                Button("Enregistrer sous…") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
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
                Button("Supprimer la sélection") { store.deleteSelection() }
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
            }
            CommandMenu("Outils") {
                ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, tool in
                    Button(tool.label) { store.tool = tool }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            CommandMenu("Affichage") {
                Button("Zoom avant") { store.zoom(by: 1.25) }.keyboardShortcut("+")
                Button("Zoom arrière") { store.zoom(by: 0.8) }.keyboardShortcut("-")
                Button("Zoom 100 %") { store.resetView() }.keyboardShortcut("0")
                Button("Ajuster à la fenêtre") { store.fitToContent() }.keyboardShortcut("9")
                Toggle("Magnétisme de la grille", isOn: $store.snapEnabled)
            }
        }
    }
}
