import SwiftUI

/// Onglets du volet « Format de la forme », comme les icônes du volet de Visio.
enum FormatTab: String, CaseIterable, Identifiable {
    case fillLine, text, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fillLine: return "Remplissage et trait"
        case .text: return "Texte"
        case .size: return "Taille et propriétés"
        }
    }

    var shortTitle: String {
        switch self {
        case .fillLine: return "Remplissage"
        case .text: return "Texte"
        case .size: return "Taille"
        }
    }

    var symbol: String {
        switch self {
        case .fillLine: return "paintbrush"
        case .text: return "textformat"
        case .size: return "square.resize"
        }
    }
}

/// Volet « Format de la forme », comme dans Visio : trois onglets (Remplissage et trait, Texte,
/// Taille et propriétés) aux sections repliables. Sans sélection, il présente la page.
struct InspectorView: View {
    @EnvironmentObject var store: DocumentStore
    @AppStorage(PanelKey.format) private var showFormat = true
    /// Onglet affiché quand une forme est sélectionnée (mémorisé).
    @AppStorage("format.tab") private var tabName = FormatTab.fillLine.rawValue
    /// Sections repliées (par titre).
    @State private var collapsed: Set<String> = ["Bloc de texte"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.selection.isEmpty ? "Page" : "Format de la forme").font(.headline)
                Spacer()
                PanelCollapseButton(.format)
                Button { showFormat = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Fermer le volet (⌥⌘2 pour le rouvrir)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if !store.selection.isEmpty {
                Picker("Onglet", selection: $tabName) {
                    ForEach(FormatTab.allCases) { t in
                        Label(t.shortTitle, systemImage: t.symbol).help(t.title).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            Form {
                if store.selection.isEmpty {
                    shapeTab
                } else {
                    switch FormatTab(rawValue: tabName) ?? .fillLine {
                    case .fillLine: styleTab
                    case .text: textTab
                    case .size: shapeTab
                    }
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
            // Ordre de Visio : taille et position, rotation, puis propriétés.
            pane("Taille et position") {
                field("X", value: s.rect.origin.x) { $0.rect.origin.x = $1 }
                field("Y", value: s.rect.origin.y) { $0.rect.origin.y = $1 }
                if !s.kind.isPath {
                    field("Largeur", value: s.rect.width, minValue: 1) { $0.rect.size.width = $1 }
                    field("Hauteur", value: s.rect.height, minValue: 1) { $0.rect.size.height = $1 }
                } else if s.kind == .line, let length = s.pathLength {
                    // Le début du trait reste en place ; la fin suit la direction du trait.
                    field("Longueur", value: length, minValue: 0.01) { $0.setLineLength($1) }
                } else if let length = s.pathLength {
                    LabeledContent("Longueur") {
                        Text("\(Diagram.format(store.doc.measure(length), decimals: store.doc.precision)) \(store.doc.unit.symbol)")
                            .monospacedDigit()
                    }
                }
            }
            if let target = store.selectionRotationTarget { rotationSection(target, single: s) }
            if !store.doc.layers.isEmpty { layerSection }
            pane("Informations sur la forme") {
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
        } else if store.selection.count == 1, let c = selectedConnectors.first {
            pane("Connecteur") {
                LabeledContent("De", value: store.shapeLabel(c.fromShape))
                LabeledContent("Vers", value: store.shapeLabel(c.toShape))
                LabeledContent("Tracé", value: c.routing.label)
                Button("Inverser le sens du connecteur") { store.reverseSelectedConnectors() }
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
            pane("Image d'arrière-plan") {
                BackgroundImageInspector()
            }
            pane("Raccourcis") {
                Text(Tool.allCases.map { "\(String($0.shortcut).uppercased()) \($0.label.lowercased())" }.joined(separator: " · ")
                     + "\nÉchap : revenir au pointeur · Espace maintenu : déplacer la vue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            pane("Sélection") {
                Text(selectionSummary)
            }
            if let target = store.selectionRotationTarget, target.frame != nil { rotationSection(target, single: nil) }
            if !store.selectedShapes.isEmpty && !store.doc.layers.isEmpty { layerSection }
        }
    }

    /// Rotation de la sélection : rotation d'une forme, angle d'un trait (direction du premier au
    /// dernier point), angle d'un groupe, ou rotation d'une sélection multiple (angle de départ 0) ;
    /// point de rotation (centre par défaut, déplaçable à la souris).
    private func rotationSection(_ target: RotationTarget, single: Shape?) -> some View {
        let title: String
        if let single {
            title = single.kind.isPath ? "Angle (°)" : "Rotation (°)"
        } else {
            title = target.isGroup ? "Rotation du groupe (°)" : "Faire pivoter de (°)"
        }
        return pane("Rotation") {
            NumericField(title: title, value: target.angle, fractionDigits: 1, context: store.selection) { v in
                store.setSelectionRotation(v)
            }
            HStack {
                Button { store.rotateSelection(by: -90) } label: { Label("90° à gauche", systemImage: "rotate.left") }
                Button { store.rotateSelection(by: 90) } label: { Label("90° à droite", systemImage: "rotate.right") }
            }
            LabeledContent("Point de rotation") {
                HStack(spacing: 6) {
                    Text(target.hasCustomPivot ? "Personnalisé" : "Centre")
                        .foregroundStyle(target.hasCustomPivot ? Color.orange : Color.secondary)
                    Button("Centre") { store.setRotationPin(nil) }
                        .disabled(!target.hasCustomPivot)
                        .help("Ramener le point de rotation au centre")
                }
            }
            Text("Poignée ronde : rotation (Maj : pas de 15°). Glissez le point ⊕ pour changer le point de rotation ; il s'accroche aux coins, milieux et centres des formes.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        pane("Grille") {
            GridControls()
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
                    NumericField(title: "Échelle", value: d.scale, fractionDigits: 4, context: d.id,
                                 isValid: { Diagram.scaleRange.contains($0) }) { v in
                        store.updatePageSettings { $0.scale = v }
                    }
                        .labelsHidden()
                        .help("Échelle du dessin 1:N — tapez N puis Entrée (1:100 : 1 cm sur la feuille = 1 m réel)")
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
        if fillable.isEmpty && selectedConnectors.isEmpty && store.selectionLineStyle == nil {
            placeholder("Pas de remplissage ni de trait pour cette sélection (zone de texte).")
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
                    NumericField(title: "Largeur (\(d.unit.symbol))", value: Double(d.measure(s.textBlockWidthValue)),
                                 fractionDigits: max(d.precision, 1), context: s.id,
                                 isValid: { Double(d.worldLength(forMeasure: $0)).isFinite }) { v in
                        let world = Double(d.worldLength(forMeasure: v))
                        let clamped = min(max(world, Shape.textBlockWidthRange.lowerBound), Shape.textBlockWidthRange.upperBound)
                        store.editSelectedShape(key: "textWidth") { $0.textBlockWidth = clamped }
                    }
                }
            }
            Button("Rétablir la position du texte") { store.resetTextBlocks() }
                .disabled(!s.hasCustomTextBlock)
            Text("Sur le dessin : poignée jaune pour déplacer le texte (Maj : horizontal ou vertical), poignées vertes pour sa largeur.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func offsetField(_ label: String, value: CGFloat, apply: @escaping (inout Shape, CGFloat) -> Void) -> some View {
        let d = store.doc
        return NumericField(title: "\(label) (\(d.unit.symbol))", value: Double(d.measure(value)),
                            fractionDigits: max(d.precision, 1), context: store.selection,
                            isValid: { v in
                                let world = d.worldLength(forMeasure: v)
                                return world.isFinite && abs(world) <= DiagramIO.maxCoordinate / 2
                            }) { v in
            store.editSelectedShape(key: label) { apply(&$0, d.worldLength(forMeasure: v)) }
        }
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
        return NumericField(title: "\(label) (\(d.unit.symbol))", value: Double(d.measure(value)),
                            fractionDigits: max(d.precision, 1), context: store.selection,
                            isValid: { d.worldLength(forMeasure: $0).isFinite }) { newValue in
            let v = min(max(d.worldLength(forMeasure: newValue), minValue), 1_000_000)
            store.editSelectedShape(key: label) { apply(&$0, v) }
        }
    }
}
