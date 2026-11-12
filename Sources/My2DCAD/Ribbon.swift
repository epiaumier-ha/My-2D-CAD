import SwiftUI
import AppKit

// MARK: - Apparence façon Visio (clair et sombre)

enum VisioTheme {
    /// Bleu de Visio (bandeau des onglets, onglet actif).
    static let blue = Color(red: 0.224, green: 0.333, blue: 0.639)

    static func band(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.13) : blue
    }

    static func ribbon(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.2) : Color(white: 0.955)
    }

    /// Fond de la zone de dessin, autour de la feuille.
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.24) : Color(white: 0.86)
    }

    static func pane(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.17) : Color(white: 0.965)
    }

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.55, green: 0.67, blue: 1) : blue
    }
}

/// Préférences d'affichage des volets (partagées entre le ruban, les menus et la fenêtre).
enum PanelKey {
    static let shapes = "panel.shapes"
    static let format = "panel.format"
    static let assistant = "assistant.visible"
}

enum RibbonTab: String, CaseIterable, Identifiable {
    case home = "Accueil"
    case insert = "Insertion"
    case design = "Création"
    case view = "Affichage"
    case developer = "Développeur"

    var id: String { rawValue }
}

/// Si un champ de texte est en cours d'édition, la commande lui est transmise
/// (copier-coller de texte dans un volet) ; sinon elle s'applique au dessin.
@MainActor
func forwardToTextEditor(_ action: Selector) -> Bool {
    guard let editor = NSApp.keyWindow?.firstResponder as? NSText else { return false }
    return NSApp.sendAction(action, to: editor, from: nil)
}

@MainActor
extension DocumentStore {
    func cutCommand() { if !forwardToTextEditor(#selector(NSText.cut(_:))) { cutSelection() } }
    func copyCommand() { if !forwardToTextEditor(#selector(NSText.copy(_:))) { copySelection() } }
    func pasteCommand() { if !forwardToTextEditor(#selector(NSText.paste(_:))) { paste() } }
    func selectAllCommand() { if !forwardToTextEditor(#selector(NSText.selectAll(_:))) { selectAll() } }
    func deleteCommand() { if !forwardToTextEditor(#selector(NSText.delete(_:))) { deleteSelection() } }
}

// MARK: - Composants du ruban

/// Bouton du ruban : survol et état actif mis en évidence, comme dans Office.
struct RibbonButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, active: active)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.clear))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.18) }
            if active { return Color.accentColor.opacity(0.22) }
            return hovering && enabled ? Color.primary.opacity(0.09) : .clear
        }
    }
}

/// Grand bouton : icône au-dessus du libellé.
struct RibbonLargeButton: View {
    let title: String
    let symbol: String
    var help = ""
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20)).frame(height: 26)
                Text(title).font(.caption).multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(minWidth: 46)
        }
        .buttonStyle(RibbonButtonStyle(active: active))
        .help(help.isEmpty ? title : help)
    }
}

/// Petit bouton : icône et libellé sur une ligne.
struct RibbonSmallButton: View {
    let title: String
    let symbol: String
    var help = ""
    var active = false
    var showTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).frame(width: 16)
                if showTitle { Text(title).font(.system(size: 11)).lineLimit(1) }
            }
            .frame(height: 16)
        }
        .buttonStyle(RibbonButtonStyle(active: active))
        .help(help.isEmpty ? title : help)
    }
}

/// Menu déroulant du ruban.
struct RibbonMenu<Content: View>: View {
    let title: String
    let symbol: String
    var help = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Label(title, systemImage: symbol).font(.caption)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .frame(height: 22)
        .help(help.isEmpty ? title : help)
    }
}

/// Groupe de commandes, avec son titre en bas et un séparateur à droite.
struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                HStack(alignment: .center, spacing: 6) { content() }
                    .frame(height: 70)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            Divider().padding(.vertical, 6)
        }
    }
}

// MARK: - Ruban

struct Ribbon: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.colorScheme) private var scheme
    @AppStorage("ribbon.tab") private var tabName = RibbonTab.home.rawValue
    @AppStorage(PanelKey.shapes) private var showShapes = true
    @AppStorage(PanelKey.format) private var showFormat = true
    @AppStorage(PanelKey.assistant) private var showAssistant = false

    private var tab: RibbonTab { RibbonTab(rawValue: tabName) ?? .home }

    var body: some View {
        VStack(spacing: 0) {
            band
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    switch tab {
                    case .home: homeTab
                    case .insert: insertTab
                    case .design: designTab
                    case .view: viewTab
                    case .developer: developerTab
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            }
            .frame(height: 96)
            .background(VisioTheme.ribbon(scheme))
            Divider()
        }
    }

    // MARK: Bandeau : accès rapide, Fichier, onglets, assistant

    private var band: some View {
        HStack(spacing: 2) {
            bandIcon("square.and.arrow.down", help: "Enregistrer (⌘S)") { store.save() }
            bandIcon("arrow.uturn.backward", help: "Annuler (⌘Z)") { store.undo() }
                .disabled(!store.canUndo)
            bandIcon("arrow.uturn.forward", help: "Rétablir (⇧⌘Z)") { store.redo() }
                .disabled(!store.canRedo)
            Menu {
                Button("Nouveau") { store.newDocument() }
                Button("Ouvrir…") { store.open() }
                Divider()
                Button("Enregistrer") { store.save() }
                Button("Enregistrer sous…") { store.saveAs() }
                Divider()
                Button("Exporter en PDF…") { store.exportPDF() }
                Button("Exporter la page en PNG…") { store.exportPNG() }
                Button("Exporter la page en SVG…") { store.exportSVG() }
                Button("Importer un SVG…") { store.importSVG() }
                Divider()
                Button("Imprimer…") { store.printDocument() }
            } label: {
                Text("Fichier").foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10)
            .help("Nouveau, ouvrir, enregistrer, exporter, imprimer")
            ForEach(RibbonTab.allCases) { t in
                Button { tabName = t.rawValue } label: {
                    Text(t.rawValue)
                        .font(.callout)
                        .fontWeight(t == tab ? .semibold : .regular)
                        .foregroundStyle(t == tab ? VisioTheme.accent(scheme) : Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(t == tab ? VisioTheme.ribbon(scheme) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            Button { showAssistant.toggle() } label: {
                Label("Assistant", systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(showAssistant ? 0.28 : 0.12)))
            }
            .buttonStyle(.plain)
            .help("Afficher ou masquer l'assistant IA (⌥⌘I)")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .frame(height: 32, alignment: .bottom)
        .background(VisioTheme.band(scheme))
    }

    private func bandIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(.white).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) { content() }
    }

    private func toolButton(_ t: Tool, title: String? = nil) -> some View {
        RibbonSmallButton(title: title ?? t.label, symbol: t.symbol, help: t.labelWithShortcut,
                          active: store.tool == t) { store.tool = t }
    }

    // MARK: Onglet Accueil

    @ViewBuilder
    private var homeTab: some View {
        RibbonGroup(title: "Presse-papiers") {
            RibbonLargeButton(title: "Coller", symbol: "doc.on.clipboard", help: "Coller (⌘V)") { store.pasteCommand() }
            column {
                RibbonSmallButton(title: "Couper", symbol: "scissors", help: "Couper (⌘X)") { store.cutCommand() }
                RibbonSmallButton(title: "Copier", symbol: "doc.on.doc", help: "Copier (⌘C)") { store.copyCommand() }
                RibbonSmallButton(title: "Dupliquer", symbol: "plus.square.on.square", help: "Dupliquer (⌘D)") {
                    store.duplicateSelection()
                }
            }
            .disabled(store.selection.isEmpty)
        }
        RibbonGroup(title: "Police") { fontGroup }
        RibbonGroup(title: "Outils") {
            column {
                toolButton(.select, title: "Pointeur")
                toolButton(.connector)
                toolButton(.text)
            }
            column {
                drawingMenu
                toolButton(.pan, title: "Main")
                Spacer().frame(height: 22)
            }
        }
        RibbonGroup(title: "Styles de forme") { styleGroup }
        RibbonGroup(title: "Organiser") { arrangeGroup }
        RibbonGroup(title: "Modification") {
            column {
                RibbonSmallButton(title: "Tout sélectionner", symbol: "selection.pin.in.out", help: "Tout sélectionner (⌘A)") {
                    store.selectAllCommand()
                }
                RibbonSmallButton(title: "Supprimer", symbol: "trash", help: "Supprimer la sélection (⌫)") {
                    store.deleteCommand()
                }
                .disabled(store.selection.isEmpty)
                RibbonMenu(title: "Affecter au calque", symbol: "square.3.layers.3d", help: "Placer la sélection sur un calque") {
                    Button("Sans calque") { store.assignSelection(toLayer: nil) }
                    ForEach(store.doc.layers) { l in
                        Button(l.name) { store.assignSelection(toLayer: l.id) }
                    }
                    Divider()
                    Button("Nouveau calque") { store.addLayer() }
                }
            }
        }
    }

    /// Bouton partagé : un clic reprend le dernier outil de dessin, la flèche ouvre la liste.
    private var drawingMenu: some View {
        let current = store.lastDrawingTool
        return Menu {
            ForEach(Tool.drawingTools) { t in
                Button { store.tool = t } label: { Label(t.labelWithShortcut, systemImage: t.symbol) }
            }
        } label: {
            Label(current.label, systemImage: current.symbol).font(.caption)
        } primaryAction: {
            store.tool = current
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .frame(height: 22)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(store.tool.isDrawingTool ? Color.accentColor.opacity(0.22) : Color.clear))
        .help("Dessin : \(current.labelWithShortcut) — la flèche propose les autres formes")
    }

    @ViewBuilder
    private var fontGroup: some View {
        let shapes = store.selectedShapes
        let ts = shapes.first?.textStyle ?? TextStyle()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Taille", selection: Binding(
                    get: { ts.size },
                    set: { v in store.editSelectionTextStyle(key: "size") { $0.size = v } })) {
                    ForEach(sizeChoices(ts.size), id: \.self) { v in
                        Text("\(v, specifier: "%g") pt").tag(v)
                    }
                }
                .labelsHidden()
                .frame(width: 78)
                .help("Taille du texte")
                ColorPicker("Couleur du texte", selection: Binding(
                    get: { ts.color.color },
                    set: { c in
                        let rgba = RGBA(color: c)
                        store.editSelectionTextStyle(key: "color") { $0.color = rgba }
                    }), supportsOpacity: false)
                    .labelsHidden()
                    .help("Couleur du texte")
            }
            HStack(spacing: 1) {
                RibbonSmallButton(title: "Gras", symbol: "bold", active: ts.bold, showTitle: false) {
                    let v = !ts.bold
                    store.editSelectionTextStyle(key: "bold") { $0.bold = v }
                }
                RibbonSmallButton(title: "Italique", symbol: "italic", active: ts.italic, showTitle: false) {
                    let v = !ts.italic
                    store.editSelectionTextStyle(key: "italic") { $0.italic = v }
                }
                Divider().frame(height: 14).padding(.horizontal, 3)
                ForEach(TextAlign.allCases) { a in
                    RibbonSmallButton(title: "Aligner le texte : \(a.label.lowercased())", symbol: a.symbol,
                                      active: ts.alignment == a, showTitle: false) {
                        store.editSelectionTextStyle(key: "alignment") { $0.alignment = a }
                    }
                }
            }
        }
        .disabled(shapes.isEmpty)
    }

    private func sizeChoices(_ current: Double) -> [Double] {
        var list = TextStyle.sizePresets
        if !list.contains(current) { list.append(current); list.sort() }
        return list
    }

    @ViewBuilder
    private var styleGroup: some View {
        let fillable = store.selectedShapes.filter(\.supportsFill)
        let line = store.selectionLineStyle
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ColorPicker("Remplissage", selection: Binding(
                    get: { (fillable.first?.fill ?? .defaultFill).color },
                    set: { c in
                        let rgba = RGBA(color: c)
                        store.editSelection(key: "fill", shapes: {
                            if $0.supportsFill { $0.fill = rgba; $0.noFill = false }
                        })
                    }), supportsOpacity: false)
                    .labelsHidden()
                Text("Remplissage").font(.caption)
                RibbonSmallButton(title: "Aucun remplissage", symbol: "square.slash",
                                  active: fillable.first?.noFill ?? false, showTitle: false) {
                    let v = !(fillable.first?.noFill ?? false)
                    store.editSelection(key: "noFill", shapes: { if $0.supportsFill { $0.noFill = v } })
                }
            }
            .disabled(fillable.isEmpty)
            HStack(spacing: 6) {
                ColorPicker("Trait", selection: Binding(
                    get: { (line?.color ?? RGBA(r: 0.2, g: 0.2, b: 0.2, a: 1)).color },
                    set: { c in
                        let rgba = RGBA(color: c)
                        store.editSelectionLineStyle(key: "color") { $0.color = rgba }
                    }), supportsOpacity: false)
                    .labelsHidden()
                RibbonMenu(title: "Trait", symbol: "lineweight", help: "Épaisseur et motif du trait") {
                    Menu("Épaisseur") {
                        ForEach(LineStyle.widthPresets, id: \.self) { w in
                            Button("\(w, specifier: "%g") pt") {
                                store.editSelectionLineStyle(key: "width") { $0.width = w }
                            }
                        }
                    }
                    Menu("Tirets") {
                        ForEach(DashPattern.allCases) { d in
                            Button(d.label) { store.editSelectionLineStyle(key: "dash") { $0.dash = d } }
                        }
                    }
                    if store.selectionSupportsArrows {
                        Menu("Flèche de début") {
                            ForEach(ArrowHead.allCases) { a in
                                Button(a.label) { store.editSelectionLineStyle(key: "begin") { $0.beginArrow = a } }
                            }
                        }
                        Menu("Flèche de fin") {
                            ForEach(ArrowHead.allCases) { a in
                                Button(a.label) { store.editSelectionLineStyle(key: "end") { $0.endArrow = a } }
                            }
                        }
                    }
                }
            }
            .disabled(line == nil)
        }
    }

    @ViewBuilder
    private var arrangeGroup: some View {
        let count = store.selectedShapes.count
        column {
            RibbonMenu(title: "Aligner", symbol: "align.horizontal.left") {
                ForEach(ShapeAlignment.allCases, id: \.self) { a in
                    Button { store.align(a) } label: { Label(a.label, systemImage: a.symbol) }
                }
            }
            .disabled(count < 2)
            RibbonMenu(title: "Position", symbol: "distribute.horizontal.center", help: "Répartir et faire pivoter") {
                Button("Répartir horizontalement") { store.distribute(.horizontal) }.disabled(count < 3)
                Button("Répartir verticalement") { store.distribute(.vertical) }.disabled(count < 3)
                Divider()
                Button("Faire pivoter à droite de 90°") { store.rotateSelection(by: 90) }
                Button("Faire pivoter à gauche de 90°") { store.rotateSelection(by: -90) }
            }
            .disabled(count == 0)
            RibbonMenu(title: "Grouper", symbol: "square.on.square.dashed") {
                Button("Grouper (⌘G)") { store.groupSelection() }.disabled(!store.canGroup)
                Button("Dissocier (⇧⌘G)") { store.ungroupSelection() }.disabled(!store.canUngroup)
            }
            .disabled(count == 0)
        }
        column {
            RibbonMenu(title: "Premier plan", symbol: StackingOrder.front.symbol) {
                Button(StackingOrder.front.label) { store.reorderSelection(.front) }
                Button(StackingOrder.forward.label) { store.reorderSelection(.forward) }
            }
            RibbonMenu(title: "Arrière-plan", symbol: StackingOrder.back.symbol) {
                Button(StackingOrder.back.label) { store.reorderSelection(.back) }
                Button(StackingOrder.backward.label) { store.reorderSelection(.backward) }
            }
            Spacer().frame(height: 22)
        }
        .disabled(store.selection.isEmpty)
    }

    // MARK: Onglet Insertion

    @ViewBuilder
    private var insertTab: some View {
        RibbonGroup(title: "Pages") {
            RibbonLargeButton(title: "Nouvelle page", symbol: "doc.badge.plus", help: "Nouvelle page (⌥⌘N)") { store.addPage() }
            column {
                RibbonSmallButton(title: "Dupliquer la page", symbol: "doc.on.doc") { store.duplicatePage(store.currentPage) }
                RibbonSmallButton(title: "Supprimer la page", symbol: "trash") { store.deletePage(store.currentPage) }
                    .disabled(store.pageCount == 1)
            }
        }
        RibbonGroup(title: "Illustrations") {
            RibbonLargeButton(title: "Dessin SVG", symbol: "photo", help: "Importer un dessin SVG (⇧⌘I)") { store.importSVG() }
        }
        RibbonGroup(title: "Parties de diagramme") {
            RibbonLargeButton(title: "Connecteur", symbol: Tool.connector.symbol, help: Tool.connector.labelWithShortcut,
                              active: store.tool == .connector) { store.tool = .connector }
            column {
                toolButton(.line)
                toolButton(.curve)
                RibbonMenu(title: "Cote", symbol: "ruler", help: "Insérer une cote au centre de la vue") {
                    Button("Outil Cote (M) : tracer d'un point à l'autre") { store.tool = .dimension }
                    Divider()
                    ForEach(dimensionItems) { item in
                        Button(item.name) { store.insertStencil(item, centeredAt: store.visibleCenter) }
                    }
                }
            }
        }
        RibbonGroup(title: "Formes") {
            column {
                toolButton(.rectangle)
                toolButton(.ellipse)
                toolButton(.diamond)
            }
        }
        RibbonGroup(title: "Texte") {
            RibbonLargeButton(title: "Zone de texte", symbol: "character.textbox", help: Tool.text.labelWithShortcut,
                              active: store.tool == .text) { store.tool = .text }
        }
    }

    private var dimensionItems: [StencilItem] {
        StencilCatalog.libraries.first { $0.id == "dimensions" }?.items ?? []
    }

    // MARK: Onglet Création

    @ViewBuilder
    private var designTab: some View {
        let d = store.doc
        RibbonGroup(title: "Feuille") {
            SheetControls(compact: true)
        }
        RibbonGroup(title: "Mise à l'échelle") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Unité", selection: Binding(
                    get: { d.unit },
                    set: { v in store.updatePageSettings { $0.unit = v; $0.precision = v.defaultPrecision } })) {
                    ForEach(MeasureUnit.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 190)
                HStack(spacing: 4) {
                    Text("Échelle 1 :").font(.caption)
                    TextField("Échelle", value: Binding(
                        get: { d.scale },
                        set: { v in store.updatePageSettings { $0.scale = v } }),
                              format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Stepper("Décimales : \(d.precision)", value: Binding(
                        get: { d.precision },
                        set: { v in store.updatePageSettings { $0.precision = v } }), in: 0...4)
                        .font(.caption)
                        .fixedSize()
                }
            }
            .controlSize(.small)
        }
        RibbonGroup(title: "Connecteurs") {
            Picker("Nouveaux connecteurs", selection: Binding(
                get: { d.defaultRouting },
                set: { v in store.updatePageSettings { $0.defaultRouting = v } })) {
                ForEach(ConnectorRouting.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
            .help("Tracé des nouveaux connecteurs")
        }
        RibbonGroup(title: "Calques") {
            RibbonLargeButton(title: "Nouveau calque", symbol: "square.3.layers.3d") { store.addLayer() }
            Text(d.layers.isEmpty ? "Aucun calque" : "\(d.layers.count) calque(s)\nGestion : barre des pages")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Onglet Affichage

    @ViewBuilder
    private var viewTab: some View {
        RibbonGroup(title: "Afficher") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Règles", isOn: $store.showRulers)
                Toggle("Magnétisme de la grille", isOn: $store.snapEnabled)
                Toggle("Repères dynamiques", isOn: $store.guidesEnabled)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        RibbonGroup(title: "Grille") {
            GridControls(compact: true)
        }
        RibbonGroup(title: "Volets") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Formes", isOn: $showShapes)
                Toggle("Format de la forme", isOn: $showFormat)
                Toggle("Assistant", isOn: $showAssistant)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        RibbonGroup(title: "Zoom") {
            RibbonLargeButton(title: "Ajuster à la fenêtre", symbol: "arrow.up.left.and.arrow.down.right",
                              help: "Ajuster à la fenêtre (⌘9)") { store.fitToContent() }
            column {
                RibbonSmallButton(title: "Zoom avant", symbol: "plus.magnifyingglass", help: "Zoom avant (⌘+)") { store.zoom(by: 1.25) }
                RibbonSmallButton(title: "Zoom arrière", symbol: "minus.magnifyingglass", help: "Zoom arrière (⌘-)") { store.zoom(by: 0.8) }
                RibbonSmallButton(title: "100 %", symbol: "1.magnifyingglass", help: "Zoom 100 % (⌘0)") { store.setZoom(1) }
            }
        }
        RibbonGroup(title: "Repères") {
            column {
                RibbonSmallButton(title: "Supprimer les repères", symbol: "xmark.circle") { store.removeAllGuides() }
                    .disabled(store.doc.guides.isEmpty)
                RibbonSmallButton(title: "Revenir à l'origine", symbol: "scope") { store.resetView() }
            }
        }
    }

    // MARK: Onglet Développeur

    @ViewBuilder
    private var developerTab: some View {
        let d = store.doc
        RibbonGroup(title: "Création de formes — Opérations") {
            ForEach([[ShapeOperation.union, .combine, .fragment], [.intersect, .subtract, .join], [.trim, .fitCurve]],
                    id: \.self) { ops in
                column {
                    ForEach(ops) { op in
                        RibbonSmallButton(title: op.label, symbol: op.symbol, help: op.help) { store.runOperation(op) }
                            .disabled(!store.canApply(op))
                    }
                    if ops.count < 3 { Spacer().frame(height: 22) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                RibbonSmallButton(title: ShapeOperation.offset.label, symbol: ShapeOperation.offset.symbol,
                                  help: ShapeOperation.offset.help) { store.runOperation(.offset) }
                    .disabled(!store.canApply(.offset))
                HStack(spacing: 4) {
                TextField("Distance", value: Binding<Double>(
                    get: { d.measure(store.offsetDistance) },
                    set: { v in
                        let world = d.worldLength(forMeasure: v)
                        guard world.isFinite, world > 0, world <= 10_000 else { return }
                        store.offsetDistance = world
                    }), format: .number.precision(.fractionLength(0...4)))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .help("Distance du décalage")
                Text(d.unit.symbol).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        RibbonGroup(title: "Regroupement") {
            column {
                RibbonSmallButton(title: "Grouper", symbol: "square.on.square.dashed", help: "Grouper (⌘G)") { store.groupSelection() }
                    .disabled(!store.canGroup)
                RibbonSmallButton(title: "Dissocier", symbol: "square.dashed", help: "Dissocier (⇧⌘G)") { store.ungroupSelection() }
                    .disabled(!store.canUngroup)
            }
        }
        RibbonGroup(title: "Comportement") {
            column {
                RibbonSmallButton(title: "Rétablir la position du texte", symbol: "text.badge.xmark") { store.resetTextBlocks() }
                RibbonSmallButton(title: "Décoller la cote", symbol: "link.badge.plus") { store.unglueSelection() }
                    .disabled(!store.selectionHasGlue)
                RibbonSmallButton(title: "Inverser le sens du connecteur", symbol: "arrow.left.arrow.right") {
                    store.reverseSelectedConnectors()
                }
            }
            .disabled(store.selection.isEmpty)
        }
    }
}
