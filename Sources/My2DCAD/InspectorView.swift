import SwiftUI

/// Onglets de l'inspecteur, sur le modèle du volet « Format de la forme » de Visio.
enum InspectorTab: String, CaseIterable, Identifiable {
    case shape = "Forme"
    case style = "Style"
    case text = "Texte"
    case arrange = "Organiser"

    var id: String { rawValue }
}

struct InspectorView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var tab: InspectorTab = .shape

    var body: some View {
        VStack(spacing: 0) {
            Picker("Onglet", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            Form {
                switch tab {
                case .shape: shapeTab
                case .style: styleTab
                case .text: textTab
                case .arrange: arrangeTab
                }
            }
            .formStyle(.grouped)
        }
    }

    private var selectedConnectors: [Connector] {
        store.doc.connectors.filter { store.selection.contains($0.id) }
    }

    private func placeholder(_ message: String) -> some View {
        Section {
            Text(message).foregroundStyle(.secondary)
        }
    }

    // MARK: - Onglet Forme

    @ViewBuilder
    private var shapeTab: some View {
        if let s = store.singleSelectedShape {
            Section("Forme") {
                LabeledContent("Type", value: s.kind.displayName)
                if let g = s.dimension {
                    LabeledContent("Mesure", value: store.doc.formatLength(g.length))
                    Text("Le texte saisi remplace la mesure ; laissez-le vide pour la mesure automatique.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Texte", text: Binding(
                    get: { s.text },
                    set: { v in
                        let limited = String(v.prefix(DiagramIO.maxTextLength))
                        store.editSelectedShape(key: "text") { $0.text = limited }
                    }), axis: .vertical)
                    .lineLimit(1...4)
            }
            if !store.doc.layers.isEmpty { layerSection }
            Section("Position et taille") {
                field("X", value: s.rect.origin.x) { $0.rect.origin.x = $1 }
                field("Y", value: s.rect.origin.y) { $0.rect.origin.y = $1 }
                if !s.kind.isPath {
                    field("Largeur", value: s.rect.width, minValue: 1) { $0.rect.size.width = $1 }
                    field("Hauteur", value: s.rect.height, minValue: 1) { $0.rect.size.height = $1 }
                    TextField("Rotation (°)", value: Binding<Double>(
                        get: { s.rotation },
                        set: { v in
                            guard v.isFinite else { return }
                            store.editSelectedShape(key: "rotation") { $0.rotation = normalizedAngle(v) }
                        }),
                              format: .number.precision(.fractionLength(0...1)))
                }
            }
        } else if store.selection.count == 1, let c = selectedConnectors.first {
            Section("Connecteur") {
                LabeledContent("De", value: store.shapeLabel(c.fromShape))
                LabeledContent("Vers", value: store.shapeLabel(c.toShape))
                LabeledContent("Tracé", value: c.routing.label)
                Button("Inverser le sens") { store.reverseSelectedConnectors() }
            }
            Section {
                Text("Glissez une extrémité du connecteur sur une autre forme pour le recoller.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if store.selection.isEmpty {
            Section("Document") {
                LabeledContent("Formes", value: "\(store.doc.shapes.count)")
                LabeledContent("Connecteurs", value: "\(store.doc.connectors.count)")
                LabeledContent("Zoom", value: "\(Int((store.zoom * 100).rounded())) %")
            }
            pageSection
            Section("Raccourcis") {
                Text("V sélection · H main · C connecteur · T texte\nR rectangle · E ellipse · D losange · L trait · B courbe · M cote\nÉchap : revenir à la sélection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Sélection") {
                Text(selectionSummary)
            }
            if !store.selectedShapes.isEmpty && !store.doc.layers.isEmpty { layerSection }
        }
    }

    /// Calque des formes sélectionnées.
    private var layerSection: some View {
        Section("Calque") {
            Picker("Calque", selection: Binding<UUID?>(
                get: { store.selectionLayerID ?? nil },
                set: { store.assignSelection(toLayer: $0) })) {
                Text("Sans calque").tag(UUID?.none)
                ForEach(store.doc.layers) { l in
                    Text(l.name).tag(UUID?.some(l.id))
                }
            }
        }
    }

    /// Réglages de la page : unité, échelle, décimales, connecteurs, repères.
    private var pageSection: some View {
        let d = store.doc
        return Section("Page « \(d.name) »") {
            Picker("Unité", selection: Binding(
                get: { d.unit },
                set: { v in store.updatePageSettings { $0.unit = v } })) {
                ForEach(MeasureUnit.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Échelle") {
                HStack(spacing: 4) {
                    Text("1 :")
                    TextField("Échelle", value: Binding(
                        get: { d.scale },
                        set: { v in store.updatePageSettings { $0.scale = v } }),
                              format: .number.precision(.fractionLength(0...3)))
                        .frame(width: 80)
                }
            }
            Stepper("Décimales : \(d.precision)", value: Binding(
                get: { d.precision },
                set: { v in store.updatePageSettings { $0.precision = v } }), in: 0...4)
            Picker("Nouveaux connecteurs", selection: Binding(
                get: { d.defaultRouting },
                set: { v in store.updatePageSettings { $0.defaultRouting = v } })) {
                ForEach(ConnectorRouting.allCases) { Text($0.label).tag($0) }
            }
            if !d.guides.isEmpty {
                LabeledContent("Repères", value: "\(d.guides.count)")
                Button("Supprimer tous les repères") { store.removeAllGuides() }
            }
        }
    }

    private var selectionSummary: String {
        let shapes = store.selectedShapes.count
        let connectors = selectedConnectors.count
        var parts: [String] = []
        if shapes > 0 { parts.append(shapes == 1 ? "1 forme" : "\(shapes) formes") }
        if connectors > 0 { parts.append(connectors == 1 ? "1 connecteur" : "\(connectors) connecteurs") }
        return parts.joined(separator: " et ") + (shapes + connectors > 1 ? " sélectionnés" : " sélectionné")
    }

    // MARK: - Onglet Style (remplissage et trait)

    @ViewBuilder
    private var styleTab: some View {
        let fillable = store.selectedShapes.filter(\.supportsFill)
        if let first = fillable.first {
            Section("Remplissage") {
                Toggle("Remplir", isOn: Binding(
                    get: { !first.noFill },
                    set: { on in store.editSelection(key: "noFill", shapes: { if $0.supportsFill { $0.noFill = !on } }) }))
                if !first.noFill {
                    ColorPicker("Couleur", selection: Binding(
                        get: { first.fill.color },
                        set: { c in
                            let rgba = RGBA(color: c)
                            store.editSelection(key: "fill", shapes: { if $0.supportsFill { $0.fill = rgba } })
                        }), supportsOpacity: false)
                    percentSlider("Transparence", value: first.fillTransparency) { v in
                        store.editSelection(key: "fillTransparency", shapes: { if $0.supportsFill { $0.fillTransparency = v } })
                    }
                }
            }
        }
        if let c = selectedConnectors.first {
            Section("Connecteur") {
                Picker("Tracé", selection: Binding(
                    get: { c.routing },
                    set: { v in store.editSelection(key: "routing", connectors: { $0.routing = v }) })) {
                    ForEach(ConnectorRouting.allCases) { Text($0.label).tag($0) }
                }
                Text("Orthogonal : contourne les formes. Droit et courbe : vont directement d'une forme à l'autre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let style = store.selectionLineStyle {
            lineSection(style)
        }
        if fillable.isEmpty && store.selectionLineStyle == nil {
            placeholder("Sélectionnez une forme, un trait ou un connecteur pour modifier son style.")
        }
    }

    private func lineSection(_ style: LineStyle) -> some View {
        Section("Trait") {
            ColorPicker("Couleur", selection: Binding(
                get: { style.color.color },
                set: { c in
                    let rgba = RGBA(color: c)
                    store.editSelectionLineStyle(key: "color") { $0.color = rgba }
                }), supportsOpacity: false)

            Picker("Motif", selection: Binding(
                get: { style.dash },
                set: { v in store.editSelectionLineStyle(key: "dash") { $0.dash = v } })) {
                ForEach(DashPattern.allCases) { Text($0.label).tag($0) }
            }

            Picker("Épaisseur", selection: Binding(
                get: { style.width },
                set: { v in store.editSelectionLineStyle(key: "width") { $0.width = v } })) {
                ForEach(choices(LineStyle.widthPresets, current: style.width), id: \.self) { w in
                    Text("\(w, specifier: "%g") pt").tag(w)
                }
            }

            percentSlider("Transparence", value: style.transparency) { v in
                store.editSelectionLineStyle(key: "transparency") { $0.transparency = v }
            }

            Picker("Extrémités", selection: Binding(
                get: { style.cap },
                set: { v in store.editSelectionLineStyle(key: "cap") { $0.cap = v } })) {
                ForEach(LineCapStyle.allCases) { Text($0.label).tag($0) }
            }

            if store.selectionSupportsArrows {
                Picker("Début", selection: Binding(
                    get: { style.beginArrow },
                    set: { v in store.editSelectionLineStyle(key: "begin") { $0.beginArrow = v } })) {
                    ForEach(ArrowHead.allCases) { Text($0.label).tag($0) }
                }
                Picker("Fin", selection: Binding(
                    get: { style.endArrow },
                    set: { v in store.editSelectionLineStyle(key: "end") { $0.endArrow = v } })) {
                    ForEach(ArrowHead.allCases) { Text($0.label).tag($0) }
                }
                Picker("Taille des flèches", selection: Binding(
                    get: { style.arrowSize },
                    set: { v in store.editSelectionLineStyle(key: "arrowSize") { $0.arrowSize = v } })) {
                    ForEach(LineStyle.arrowSizePresets, id: \.0) { size, label in
                        Text(label).tag(size)
                    }
                }
            }
        }
    }

    // MARK: - Onglet Texte

    @ViewBuilder
    private var textTab: some View {
        if let first = store.selectedShapes.first {
            let ts = first.textStyle
            if store.selectedShapes.count == 1 {
                Section("Contenu") {
                    TextField("Texte", text: Binding(
                        get: { first.text },
                        set: { v in
                            let limited = String(v.prefix(DiagramIO.maxTextLength))
                            store.editSelectedShape(key: "text") { $0.text = limited }
                        }), axis: .vertical)
                        .lineLimit(2...6)
                    Text("Double-clic sur la forme, Entrée ou F2 pour écrire directement dessus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Police") {
                Picker("Taille", selection: Binding(
                    get: { ts.size },
                    set: { v in store.editSelectionTextStyle(key: "size") { $0.size = v } })) {
                    ForEach(choices(TextStyle.sizePresets, current: ts.size), id: \.self) { v in
                        Text("\(v, specifier: "%g") pt").tag(v)
                    }
                }
                ColorPicker("Couleur", selection: Binding(
                    get: { ts.color.color },
                    set: { c in
                        let rgba = RGBA(color: c)
                        store.editSelectionTextStyle(key: "color") { $0.color = rgba }
                    }), supportsOpacity: false)
                LabeledContent("Style") {
                    HStack(spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { ts.bold },
                            set: { v in store.editSelectionTextStyle(key: "bold") { $0.bold = v } })) {
                            Image(systemName: "bold")
                        }
                        .help("Gras")
                        Toggle(isOn: Binding(
                            get: { ts.italic },
                            set: { v in store.editSelectionTextStyle(key: "italic") { $0.italic = v } })) {
                            Image(systemName: "italic")
                        }
                        .help("Italique")
                    }
                    .toggleStyle(.button)
                }
                Picker("Alignement", selection: Binding(
                    get: { ts.alignment },
                    set: { v in store.editSelectionTextStyle(key: "alignment") { $0.alignment = v } })) {
                    ForEach(TextAlign.allCases) { a in
                        Image(systemName: a.symbol).help(a.label).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }
        } else {
            placeholder("Sélectionnez une ou plusieurs formes pour mettre leur texte en forme.")
        }
    }

    // MARK: - Onglet Organiser

    @ViewBuilder
    private var arrangeTab: some View {
        let count = store.selectedShapes.count
        if count == 0 {
            placeholder("Sélectionnez des formes pour les aligner, les répartir, les faire pivoter ou changer leur ordre.")
        } else {
            Section("Aligner") {
                HStack(spacing: 2) {
                    ForEach(ShapeAlignment.allCases, id: \.self) { a in
                        iconButton(a.symbol, help: "Aligner \(a.label.lowercased())") { store.align(a) }
                    }
                }
                .disabled(count < 2)
                if count < 2 {
                    Text("Sélectionnez au moins 2 formes.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Répartir") {
                HStack(spacing: 2) {
                    iconButton("distribute.horizontal.center", help: "Répartir horizontalement") {
                        store.distribute(.horizontal)
                    }
                    iconButton("distribute.vertical.center", help: "Répartir verticalement") {
                        store.distribute(.vertical)
                    }
                }
                .disabled(count < 3)
                if count < 3 {
                    Text("Sélectionnez au moins 3 formes.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Pivoter") {
                HStack(spacing: 2) {
                    iconButton("rotate.left", help: "Faire pivoter de 90° à gauche (⌃L)") { store.rotateSelection(by: -90) }
                    iconButton("rotate.right", help: "Faire pivoter de 90° à droite (⌃R)") { store.rotateSelection(by: 90) }
                }
            }
            Section("Groupe") {
                HStack {
                    Button("Grouper") { store.groupSelection() }.disabled(!store.canGroup)
                    Button("Dissocier") { store.ungroupSelection() }.disabled(!store.canUngroup)
                }
                Text("⌘G grouper, ⇧⌘G dissocier. Un clic sur une forme groupée sélectionne tout le groupe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Ordre") {
                HStack(spacing: 2) {
                    ForEach(StackingOrder.allCases, id: \.self) { o in
                        iconButton(o.symbol, help: o.label) { store.reorderSelection(o) }
                    }
                }
            }
        }
    }

    // MARK: - Composants

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func percentSlider(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value }, set: { set(min(max($0, 0), 1)) }), in: 0...1)
                Text("\(Int((value * 100).rounded())) %")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// Valeurs proposées, plus la valeur actuelle si elle n'est pas dans la liste.
    private func choices(_ presets: [Double], current: Double) -> [Double] {
        var list = presets
        if !list.contains(current) { list.append(current); list.sort() }
        return list
    }

    private func field(_ label: String, value: CGFloat, minValue: CGFloat = -1_000_000,
                       apply: @escaping (inout Shape, CGFloat) -> Void) -> some View {
        TextField(label, value: Binding<Double>(
            get: { Double(value) },
            set: { newValue in
                guard newValue.isFinite else { return }
                let v = min(max(CGFloat(newValue), minValue), 1_000_000)
                store.editSelectedShape(key: label) { apply(&$0, v) }
            }),
                  format: .number.precision(.fractionLength(0...1)))
    }
}
