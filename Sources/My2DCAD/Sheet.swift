import SwiftUI

// MARK: - Feuille (taille et orientation de la page imprimée, comme dans Visio)
//
// La feuille occupe le rectangle (0, 0, largeur, hauteur) du dessin, en points (1 pt = 1/72 pouce) :
// c'est la page imprimée et exportée en PDF. L'échelle du dessin (1:N) ne change que les mesures
// affichées, pas la taille de la feuille. On peut dessiner en dehors, mais seule la feuille s'imprime.

enum PaperSize: String, Codable, CaseIterable, Identifiable {
    case a5, a4, a3, a2, custom

    var id: String { rawValue }

    /// Dimensions en millimètres, en portrait (nil : format personnalisé).
    var portraitMillimetres: CGSize? {
        switch self {
        case .a5: return CGSize(width: 148, height: 210)
        case .a4: return CGSize(width: 210, height: 297)
        case .a3: return CGSize(width: 297, height: 420)
        case .a2: return CGSize(width: 420, height: 594)
        case .custom: return nil
        }
    }

    var label: String {
        switch self {
        case .a5: return "A5 (148 × 210 mm)"
        case .a4: return "A4 (210 × 297 mm)"
        case .a3: return "A3 (297 × 420 mm)"
        case .a2: return "A2 (420 × 594 mm)"
        case .custom: return "Personnalisée"
        }
    }
}

enum PageOrientation: String, Codable, CaseIterable, Identifiable {
    case portrait, landscape

    var id: String { rawValue }
    var label: String { self == .portrait ? "Portrait" : "Paysage" }
    var symbol: String { self == .portrait ? "rectangle.portrait" : "rectangle" }
}

struct PageSetup: Codable, Equatable {
    var paper: PaperSize = .a4
    var orientation: PageOrientation = .landscape
    /// Taille personnalisée, en millimètres (utilisée avec le format « Personnalisée »).
    var customWidth: Double = 297
    var customHeight: Double = 210

    /// Côté minimal et maximal d'une feuille, en millimètres.
    static let sideRange: ClosedRange<Double> = 10...5_000

    var isValid: Bool {
        customWidth.isFinite && customHeight.isFinite
            && Self.sideRange.contains(customWidth) && Self.sideRange.contains(customHeight)
    }

    /// Taille de la feuille en millimètres, orientation appliquée.
    var millimetres: CGSize {
        let base = paper.portraitMillimetres ?? CGSize(width: customWidth, height: customHeight)
        let short = min(base.width, base.height), long = max(base.width, base.height)
        return orientation == .portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    /// Taille de la feuille en unités du dessin (points).
    var size: CGSize {
        let mm = millimetres
        let k = 1 / Diagram.millimetresPerWorldUnit
        return CGSize(width: mm.width * k, height: mm.height * k)
    }

    /// Description courte : « A4 paysage », « 500 × 300 mm ».
    var summary: String {
        let mm = millimetres
        if paper == .custom {
            return "\(Diagram.format(mm.width, decimals: 0)) × \(Diagram.format(mm.height, decimals: 0)) mm"
        }
        return paper.rawValue.uppercased() + " " + orientation.label.lowercased()
    }
}

extension Diagram {
    /// Rectangle de la feuille, en coordonnées du dessin.
    var sheetRect: CGRect { CGRect(origin: .zero, size: pageSetup.size) }
}

@MainActor
extension DocumentStore {
    /// Agrandit ou réduit la feuille autour du dessin, avec une marge de 10 mm, comme
    /// « Ajuster au dessin » de Visio : le dessin est déplacé pour commencer à la marge.
    func fitSheetToDrawing() {
        guard let content = DiagramExporter.contentBounds(doc) else { return }
        let margin = 10 / Diagram.millimetresPerWorldUnit
        let dx = margin - content.minX, dy = margin - content.minY
        let mm = Diagram.millimetresPerWorldUnit
        let width = min(max(((content.width + 2 * margin) * mm).rounded(.up), PageSetup.sideRange.lowerBound),
                        PageSetup.sideRange.upperBound)
        let height = min(max(((content.height + 2 * margin) * mm).rounded(.up), PageSetup.sideRange.lowerBound),
                         PageSetup.sideRange.upperBound)
        perform { d in
            for i in d.shapes.indices {
                d.shapes[i].rect.origin.x += dx
                d.shapes[i].rect.origin.y += dy
            }
            for i in d.guides.indices {
                d.guides[i].position += d.guides[i].vertical ? dx : dy
            }
            d.pageSetup.paper = .custom
            d.pageSetup.customWidth = width
            d.pageSetup.customHeight = height
            d.pageSetup.orientation = width >= height ? .landscape : .portrait
        }
        fitToContent()
    }
}

// MARK: - Réglages de la feuille (ruban et volet Page)

/// Format, orientation, taille personnalisée et « Ajuster au dessin ».
struct SheetControls: View {
    @EnvironmentObject var store: DocumentStore
    /// Présentation compacte pour le ruban.
    var compact = false

    var body: some View {
        let setup = store.doc.pageSetup
        if compact {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    paperPicker(setup).frame(width: 170)
                    orientationPicker(setup).frame(width: 170)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if setup.paper == .custom { customFields(setup) }
                    Button("Ajuster au dessin") { store.fitSheetToDrawing() }
                        .help("Adapte la feuille au dessin, avec une marge de 10 mm")
                        .disabled(store.doc.shapes.isEmpty)
                }
            }
            .controlSize(.small)
        } else {
            paperPicker(setup)
            orientationPicker(setup)
            if setup.paper == .custom { customFields(setup) }
            Button("Ajuster au dessin") { store.fitSheetToDrawing() }
                .help("Adapte la feuille au dessin, avec une marge de 10 mm")
                .disabled(store.doc.shapes.isEmpty)
        }
    }

    private func paperPicker(_ setup: PageSetup) -> some View {
        Picker("Format", selection: Binding(
            get: { setup.paper },
            set: { v in
                // Passer en personnalisé garde la taille actuelle comme point de départ.
                let current = setup.millimetres
                store.updatePageSettings {
                    if v == .custom && $0.pageSetup.paper != .custom {
                        $0.pageSetup.customWidth = current.width
                        $0.pageSetup.customHeight = current.height
                    }
                    $0.pageSetup.paper = v
                }
            })) {
            ForEach(PaperSize.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden(compact)
    }

    private func orientationPicker(_ setup: PageSetup) -> some View {
        Picker("Orientation", selection: Binding(
            get: { setup.orientation },
            set: { v in store.updatePageSettings { $0.pageSetup.orientation = v } })) {
            ForEach(PageOrientation.allCases) { o in
                Label(o.label, systemImage: o.symbol).tag(o)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden(compact)
    }

    @ViewBuilder
    private func customFields(_ setup: PageSetup) -> some View {
        let w = Double(setup.millimetres.width), h = Double(setup.millimetres.height)
        HStack(spacing: 4) {
            sideField("Largeur", value: w) { d, v in
                d.pageSetup.customWidth = v
                d.pageSetup.customHeight = h
                d.pageSetup.orientation = v >= h ? .landscape : .portrait
            }
            Text("×")
            sideField("Hauteur", value: h) { d, v in
                d.pageSetup.customWidth = w
                d.pageSetup.customHeight = v
                d.pageSetup.orientation = w >= v ? .landscape : .portrait
            }
            Text("mm").foregroundStyle(.secondary)
        }
    }

    private func sideField(_ title: String, value: Double,
                           apply: @escaping (inout Diagram, Double) -> Void) -> some View {
        TextField(title, value: Binding<Double>(
            get: { value },
            set: { v in
                guard v.isFinite, PageSetup.sideRange.contains(v) else { return }
                store.updatePageSettings { apply(&$0, v) }
            }), format: .number.precision(.fractionLength(0...1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .frame(width: 64)
            .help("\(title) de la feuille, en millimètres (\(Int(PageSetup.sideRange.lowerBound)) à \(Int(PageSetup.sideRange.upperBound)))")
    }
}

private extension View {
    @ViewBuilder
    func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}
