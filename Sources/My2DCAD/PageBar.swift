import SwiftUI

/// Onglets des pages en bas du dessin (comme Visio) et accès aux calques de la page.
struct PageBar: View {
    @EnvironmentObject var store: DocumentStore
    @State private var renamingIndex: Int?
    @State private var newName = ""
    @State private var showLayers = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(store.document.pages.enumerated()), id: \.element.id) { index, page in
                        tab(index: index, page: page)
                    }
                }
                .padding(.horizontal, 6)
            }
            Button { store.addPage() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Nouvelle page (⌥⌘N)")
            Divider().frame(height: 16)
            Button { showLayers.toggle() } label: {
                Label(layerSummary, systemImage: "square.3.layers.3d")
            }
            .buttonStyle(.borderless)
            .help("Calques de la page")
            .popover(isPresented: $showLayers, arrowEdge: .top) {
                LayersPanel().environmentObject(store)
            }
            .padding(.trailing, 8)
        }
        .font(.callout)
        .frame(height: 28)
        .background(.bar)
    }

    private var layerSummary: String {
        let n = store.doc.layers.count
        return n == 0 ? "Calques" : (n == 1 ? "1 calque" : "\(n) calques")
    }

    @ViewBuilder
    private func tab(index: Int, page: Diagram) -> some View {
        let current = index == store.currentPage
        Group {
            if renamingIndex == index {
                TextField("Nom", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renamingIndex = nil }
                    .onAppear { renameFocused = true }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(page.name)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(current ? Color.accentColor.opacity(0.25) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startRename(index) }
                    .onTapGesture { store.selectPage(index) }
                    .help("Double-cliquez pour renommer")
            }
        }
        .contextMenu {
            Button("Renommer…") { startRename(index) }
            Button("Dupliquer la page") { store.duplicatePage(index) }
            Divider()
            Button("Déplacer vers la gauche") { store.movePage(index, by: -1) }.disabled(index == 0)
            Button("Déplacer vers la droite") { store.movePage(index, by: 1) }
                .disabled(index == store.pageCount - 1)
            Divider()
            Button("Supprimer la page") { store.deletePage(index) }.disabled(store.pageCount == 1)
        }
    }

    private func startRename(_ index: Int) {
        store.selectPage(index)
        newName = store.document.pages[index].name
        renamingIndex = index
    }

    private func commitRename() {
        guard let index = renamingIndex else { return }
        renamingIndex = nil
        store.renamePage(index, to: newName)
    }
}

/// Calques de la page affichée : nom, calque actif, visibilité, verrouillage, impression.
struct LayersPanel: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calques de « \(store.doc.name) »").font(.headline)
            if store.doc.layers.isEmpty {
                Text("Aucun calque : toutes les formes sont visibles, modifiables et imprimées.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Actif").gridColumnAlignment(.center)
                        Text("Nom")
                        Image(systemName: "eye").help("Visible")
                        Image(systemName: "lock").help("Verrouillé")
                        Image(systemName: "printer").help("Imprimable")
                        Text("")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(store.doc.layers) { layer in
                        row(layer)
                    }
                }
            }
            HStack {
                Button { store.addLayer() } label: { Label("Nouveau calque", systemImage: "plus") }
                Spacer()
                Button("Sans calque actif") { store.setActiveLayer(nil) }
                    .disabled(store.doc.activeLayerID == nil)
            }
            Divider()
            HStack {
                Text("Sélection :").foregroundStyle(.secondary)
                Menu("Placer sur le calque") {
                    Button("Sans calque") { store.assignSelection(toLayer: nil) }
                    ForEach(store.doc.layers) { layer in
                        Button(layer.name) { store.assignSelection(toLayer: layer.id) }
                    }
                }
                .disabled(store.selectedShapes.isEmpty)
            }
            Text("Les nouvelles formes vont sur le calque actif. Un calque masqué ou verrouillé ne peut pas être sélectionné ; un calque non imprimable n'est pas exporté.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 400)
    }

    private func row(_ layer: Layer) -> some View {
        GridRow {
            Button {
                store.setActiveLayer(layer.id)
            } label: {
                Image(systemName: store.doc.activeLayerID == layer.id ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.borderless)
            .help("Calque actif : les nouvelles formes y sont placées")

            TextField("Nom", text: Binding(
                get: { layer.name },
                set: { v in store.updateLayer(layer.id, key: "name") { $0.name = v } }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)

            toggle(layer.visible, on: "eye", off: "eye.slash", help: "Afficher / masquer") {
                store.updateLayer(layer.id, key: "visible") { $0.visible.toggle() }
            }
            toggle(layer.locked, on: "lock.fill", off: "lock.open", help: "Verrouiller / déverrouiller") {
                store.updateLayer(layer.id, key: "locked") { $0.locked.toggle() }
            }
            toggle(layer.printable, on: "printer.fill", off: "printer", help: "Imprimer et exporter, ou non") {
                store.updateLayer(layer.id, key: "printable") { $0.printable.toggle() }
            }
            Button(role: .destructive) { store.deleteLayer(layer.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Supprimer le calque (ses formes sont conservées, sans calque)")
        }
    }

    private func toggle(_ value: Bool, on: String, off: String, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: value ? on : off) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
