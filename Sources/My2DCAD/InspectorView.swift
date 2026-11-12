import SwiftUI

/// Volet « Format de la forme », comme dans Visio : sections repliables Remplissage, Trait, Texte,
/// Taille et position. Sans sélection, il présente la page.
struct InspectorView: View {
    @EnvironmentObject var store: DocumentStore
    @AppStorage(PanelKey.format) private var showFormat = true
    /// Sections repliées (par titre).
    @State private var collapsed: Set<String> = ["Bloc de texte"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.selection.isEmpty ? "Page" : "Format de la forme").font(.headline)
                Spacer()
                Button { showFormat = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Fermer le volet (⌥⌘2 pour le rouvrir)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Form {
                if store.selection.isEmpty {
                    shapeTab
                } else {
                    styleTab
                    if !store.selectedShapes.isEmpty { textTab }
                    shapeTab
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    /// Section repliable d'un clic sur son titre.
    private func pane<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let open = !collapsed.contains(title)
        return Section {
            if open { content() }
        } header: {
            Button {
                if open { collapsed.insert(title) } else { collapsed.remove(title) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Text(title)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var selectedConnectors: [Connector] {
        store.doc.connectors.filter { store.selection.contains($0.id) }
    }

    /// État du collage d'une cote : libre, ou nombre d'extrémités collées.
    private func glueDescription(_ s: Shape) -> String {
        let total = s.kind.gluePointIndices.count
        switch s.glue.count {
        case 0: return "Libre"
        case total: return "Collée"
        default: return "Collée (\(s.glue.count) sur \(total))"
        }
    }

    private func placeholder(_ message: String) -> some View {
        Section {
            Text(message).foregroundStyle(.secondary)
        }
    }

    // MARK: - Forme, page, taille et position

    @ViewBuilder
    private var shapeTab: some View {
        if let s = store.singleSelectedShape {
            pane("Forme sélectionnée") {
                LabeledContent("Type", value: s.kind.displayName)
                if s.kind.isDimension {
                    LabeledContent("Mesure", value: store.doc.dimensionMeasure(s))
                    LabeledContent("Collage", value: glueDescription(s))
                    if !s.glue.isEmpty {
                        Button("Décoller la cote") { store.unglueSelection() }
                    }
                    Text("Le texte saisi remplace la mesure ; laissez-le vide pour la mesure automatique. "
                         + "Glissez une extrémité sur un coin, un milieu ou le centre d'une forme pour la coller.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !store.doc.layers.isEmpty { layerSection }
            pane("Taille et position") {
                field("X", value: s.rect.origin.x) { $0.rect.origin.x = $1 }
                field("Y", value: s.rect.origin.y) { $0.rect.origin.y = $1 }
                Text("Valeurs en \(store.doc.unit.label.lowercased()), à l'échelle 1:\(Diagram.format(store.doc.scale, decimals: 0)) de la page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            pane("Connecteur") {
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
            pane("Document") {
                LabeledContent("Formes", value: "\(store.doc.shapes.count)")
                LabeledContent("Connecteurs", value: "\(store.doc.connectors.count)")
            }
            pageSection
            pane("Raccourcis") {
                Text("V sélection · H main · C connecteur · T texte\nR rectangle · E ellipse · D losange · L trait · B courbe · M cote\nÉchap : revenir à la sélection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            pane("Sélection") {
                Text(selectionSummary)
            }
            if !store.selectedShapes.isEmpty && !store.doc.layers.isEmpty { layerSection }
        }
    }

    /// Calque des formes sélectionnées.
    private var layerSection: some View {
        pane("Calque") {
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

    /// Réglages de la page : feuille, unité, échelle, décimales, connecteurs, repères.
    @ViewBuilder
    private var pageSection: some View {
        let d = store.doc
        pane("Feuille") {
            SheetControls()
        }
        pane("Page « \(d.name) »") {
            Picker("Unité", selection: Binding(
                get: { d.unit },
                set: { v in store.updatePageSettings { $0.unit = v; $0.precision = v.defaultPrecision } })) {
                ForEach(MeasureUnit.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Échelle") {
                HStack(spacing: 4) {
                    Text("1 :")
                    TextField("Échelle", value: Binding(
                        get: { d.scale },
                        set: { v in store.updatePageSettings { $0.scale = v } }),
                              format: .number.precision(.fractionLength(0...3)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
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

    // MARK: - Remplissage et trait

    @ViewBuilder
    private var styleTab: some View {
        let fillable = store.selectedShapes.filter(\.supportsFill)
        if let first = fillable.first {
            pane("Remplissage") {
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
            pane("Connecteur") {
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
    }

    private func lineSection(_ style: LineStyle) -> some View {
        pane("Trait") {
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

    // MARK: - Texte

    @ViewBuilder
    private var textTab: some View {
        if let first = store.selectedShapes.first {
            let ts = first.textStyle
            if store.selectedShapes.count == 1 {
                pane("Texte") {
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
            pane("Police") {
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
            if store.selectedShapes.count == 1 { textBlockSection(first) }
        } else {
            placeholder("Sélectionnez une ou plusieurs formes pour mettre leur texte en forme.")
        }
    }

    /// Bloc de texte : position (décalage) et largeur, comme l'« Outil Bloc de texte » de Visio.
    private func textBlockSection(_ s: Shape) -> some View {
        let d = store.doc
        return pane("Bloc de texte") {
            offsetField("Décalage X", value: s.textOffset.x) { $0.textOffset.x = $1 }
            offsetField("Décalage Y", value: s.textOffset.y) { $0.textOffset.y = $1 }
            if s.supportsTextBlockWidth {
                Toggle("Largeur automatique", isOn: Binding(
                    get: { s.textBlockWidth == nil },
                    set: { auto in
                        let current = Double(s.textBlockWidthValue)
                        store.editSelectedShape(key: "textWidthAuto") { $0.textBlockWidth = auto ? nil : current }
                    }))
                if s.textBlockWidth != nil {
                    TextField("Largeur (\(d.unit.symbol))", value: Binding<Double>(
                        get: { d.measure(s.textBlockWidthValue) },
                        set: { v in
                            let world = Double(d.worldLength(forMeasure: v))
                            guard world.isFinite else { return }
                            let clamped = min(max(world, Shape.textBlockWidthRange.lowerBound), Shape.textBlockWidthRange.upperBound)
                            store.editSelectedShape(key: "textWidth") { $0.textBlockWidth = clamped }
                        }), format: .number.precision(.fractionLength(0...max(d.precision, 1))))
                }
            }
            Button("Rétablir la position par défaut") { store.resetTextBlocks() }
                .disabled(!s.hasCustomTextBlock)
            Text("Sur le dessin : poignée jaune pour déplacer le texte (Maj : horizontal ou vertical), poignées vertes pour sa largeur.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func offsetField(_ label: String, value: CGFloat, apply: @escaping (inout Shape, CGFloat) -> Void) -> some View {
        let d = store.doc
        return TextField("\(label) (\(d.unit.symbol))", value: Binding<Double>(
            get: { d.measure(value) },
            set: { v in
                let world = d.worldLength(forMeasure: v)
                guard world.isFinite, abs(world) <= DiagramIO.maxCoordinate / 2 else { return }
                store.editSelectedShape(key: label) { apply(&$0, world) }
            }), format: .number.precision(.fractionLength(0...max(d.precision, 1))))
    }

    // MARK: - Composants

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

    /// Champ numérique dans l'unité de la page (comme les règles et la barre d'état) ;
    /// la valeur est reconvertie en unités du dessin à la saisie.
    private func field(_ label: String, value: CGFloat, minValue: CGFloat = -1_000_000,
                       apply: @escaping (inout Shape, CGFloat) -> Void) -> some View {
        let d = store.doc
        return TextField("\(label) (\(d.unit.symbol))", value: Binding<Double>(
            get: { d.measure(value) },
            set: { newValue in
                guard newValue.isFinite else { return }
                let world = d.worldLength(forMeasure: newValue)
                guard world.isFinite else { return }
                let v = min(max(world, minValue), 1_000_000)
                store.editSelectedShape(key: label) { apply(&$0, v) }
            }),
                  format: .number.precision(.fractionLength(0...max(d.precision, 1))))
    }
}
