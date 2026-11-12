import SwiftUI

// MARK: - Grille (Visio : Création › Mise en page › Grille et règles)
//
// Unité de la grille : métrique par défaut (mm, cm ou m de la page, échelle comprise ; millimètres si la
// page est en pouces ou en points), ou points (points du papier, sans échelle) en option.
//
// Deux modes, comme Visio :
// - variable : l'espacement suit le zoom et tombe toujours sur des valeurs rondes de l'unité de la page
//   (1, 2, 5, 10…), selon la densité choisie (fin, normal, grossier) ;
// - fixe : l'espacement est celui saisi, quel que soit le zoom.
// Le magnétisme s'aligne sur la grille affichée ; une ligne principale toutes les N subdivisions.

enum GridMeasure: String, Codable, CaseIterable, Identifiable {
    case metric, points

    var id: String { rawValue }
    var label: String { self == .metric ? "Métrique" : "Points" }
}

enum GridMode: String, Codable, CaseIterable, Identifiable {
    case variable, fixed

    var id: String { rawValue }
    var label: String { self == .variable ? "Variable" : "Fixe" }
}

enum GridDensity: String, Codable, CaseIterable, Identifiable {
    case fine, normal, coarse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fine: return "Fin"
        case .normal: return "Normal"
        case .coarse: return "Grossier"
        }
    }

    /// Écart minimal à l'écran entre deux lignes, en points.
    var targetPixels: CGFloat {
        switch self {
        case .fine: return 6
        case .normal: return 12
        case .coarse: return 24
        }
    }
}

struct GridSettings: Codable, Equatable {
    var visible = true
    var measure: GridMeasure = .metric
    var mode: GridMode = .variable
    var density: GridDensity = .normal
    /// Espacement du mode fixe, en unités du dessin (points) : 10 mm par défaut.
    var fixedSpacing: Double = 10 / Diagram.millimetresPerWorldUnit
    /// Nombre de subdivisions entre deux lignes principales.
    var subdivisions = 5

    static let spacingRange: ClosedRange<Double> = 0.25...100_000
    static let subdivisionRange: ClosedRange<Int> = 1...20

    enum CodingKeys: String, CodingKey {
        case visible, measure, mode, density, fixedSpacing, subdivisions
    }

    init() {}

    /// Décodage tolérant : réglages ajoutés au fil des versions.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GridSettings()
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        measure = try c.decodeIfPresent(GridMeasure.self, forKey: .measure) ?? d.measure
        mode = try c.decodeIfPresent(GridMode.self, forKey: .mode) ?? d.mode
        density = try c.decodeIfPresent(GridDensity.self, forKey: .density) ?? d.density
        fixedSpacing = try c.decodeIfPresent(Double.self, forKey: .fixedSpacing) ?? d.fixedSpacing
        subdivisions = try c.decodeIfPresent(Int.self, forKey: .subdivisions) ?? d.subdivisions
    }

    var isValid: Bool {
        fixedSpacing.isFinite && Self.spacingRange.contains(fixedSpacing) && Self.subdivisionRange.contains(subdivisions)
    }
}

extension Diagram {
    /// Unité métrique de la grille : celle de la page si elle est métrique, sinon le millimètre.
    var gridMetricUnit: MeasureUnit {
        [.mm, .cm, .m].contains(unit) ? unit : .mm
    }

    /// Symbole de l'unité de la grille.
    var gridUnitSymbol: String { grid.measure == .points ? "pt" : gridMetricUnit.symbol }

    /// Longueur du dessin exprimée dans l'unité de la grille (métrique : échelle comprise ; points : papier).
    func gridMeasure(_ world: CGFloat) -> Double {
        switch grid.measure {
        case .points: return Double(world)
        case .metric: return Double(world) * Diagram.millimetresPerWorldUnit * scale / gridMetricUnit.millimetres
        }
    }

    /// Longueur du dessin correspondant à une valeur dans l'unité de la grille.
    func gridWorldLength(_ value: Double) -> CGFloat {
        switch grid.measure {
        case .points: return CGFloat(value)
        case .metric: return CGFloat(value * gridMetricUnit.millimetres / (Diagram.millimetresPerWorldUnit * scale))
        }
    }

    /// Espacement de la grille (unités du dessin) au zoom donné.
    func gridStep(zoom: CGFloat) -> CGFloat {
        switch grid.mode {
        case .fixed:
            return CGFloat(grid.fixedSpacing)
        case .variable:
            // Plus petite valeur ronde (1, 2 ou 5 × 10ⁿ dans l'unité de la grille) assez espacée à l'écran :
            // la grille suit à la fois le zoom et l'échelle du dessin.
            let target = gridMeasure(grid.density.targetPixels / max(zoom, 0.0001))
            guard target.isFinite, target > 0 else { return 20 }
            let decade = pow(10, floor(log10(target)))
            let nice = [1.0, 2, 5, 10].map { $0 * decade }.first { $0 >= target * (1 - 1e-9) } ?? 10 * decade
            let step = gridWorldLength(nice)
            return step.isFinite && step > 0 ? step : 20
        }
    }

    /// Espacement de la grille affichée, dans l'unité de la grille : « 5 mm », « 20 pt ».
    func gridSpacingText(zoom: CGFloat) -> String {
        Diagram.formatCompact(gridMeasure(gridStep(zoom: zoom))) + " " + gridUnitSymbol
    }
}

// MARK: - Réglages de la grille (ruban et volet Page)

struct GridControls: View {
    @EnvironmentObject var store: DocumentStore
    /// Présentation compacte pour le ruban.
    var compact = false

    var body: some View {
        let grid = store.doc.grid
        if compact {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    visibleToggle(grid).toggleStyle(.checkbox)
                    measurePicker(grid).frame(width: 150)
                    modePicker(grid).frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 4) {
                    spacingControl(grid)
                    subdivisionsStepper(grid)
                }
            }
            .controlSize(.small)
        } else {
            visibleToggle(grid)
            measurePicker(grid)
            modePicker(grid)
            spacingControl(grid)
            subdivisionsStepper(grid)
            LabeledContent("Espacement actuel", value: currentSpacing)
        }
    }

    private var currentSpacing: String { store.doc.gridSpacingText(zoom: store.zoom) }

    private func update(_ change: @escaping (inout GridSettings) -> Void) {
        store.updatePageSettings { change(&$0.grid) }
    }

    private func visibleToggle(_ grid: GridSettings) -> some View {
        Toggle("Afficher la grille", isOn: Binding(get: { grid.visible }, set: { v in update { $0.visible = v } }))
    }

    private func measurePicker(_ grid: GridSettings) -> some View {
        Picker("Unité", selection: Binding(get: { grid.measure }, set: { v in update { $0.measure = v } })) {
            ForEach(GridMeasure.allCases) { m in
                Text(m == .metric ? "Métrique (\(store.doc.gridMetricUnit.symbol))" : "Points").tag(m)
            }
        }
        .help("Métrique : millimètres, centimètres ou mètres de la page, échelle comprise. Points : points du papier, sans échelle.")
    }

    private func modePicker(_ grid: GridSettings) -> some View {
        Picker("Espacement", selection: Binding(get: { grid.mode }, set: { v in update { $0.mode = v } })) {
            ForEach(GridMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("Variable : suit le zoom. Fixe : espacement saisi, quel que soit le zoom.")
    }

    @ViewBuilder
    private func spacingControl(_ grid: GridSettings) -> some View {
        if grid.mode == .variable {
            Picker("Densité", selection: Binding(get: { grid.density }, set: { v in update { $0.density = v } })) {
                ForEach(GridDensity.allCases) { Text($0.label).tag($0) }
            }
            .frame(maxWidth: compact ? 150 : .infinity)
        } else {
            let d = store.doc
            LabeledContent("Espacement") {
                HStack(spacing: 4) {
                    TextField("Espacement", value: Binding<Double>(
                        get: { d.gridMeasure(CGFloat(grid.fixedSpacing)) },
                        set: { v in
                            let world = Double(d.gridWorldLength(v))
                            guard world.isFinite, GridSettings.spacingRange.contains(world) else { return }
                            update { $0.fixedSpacing = world }
                        }), format: .number.precision(.fractionLength(0...4)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .frame(width: 70)
                    Text(d.gridUnitSymbol).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func subdivisionsStepper(_ grid: GridSettings) -> some View {
        Stepper("Ligne principale tous les \(grid.subdivisions)",
                value: Binding(get: { grid.subdivisions }, set: { v in update { $0.subdivisions = v } }),
                in: GridSettings.subdivisionRange)
            .help("Nombre d'intervalles entre deux lignes principales")
    }
}
