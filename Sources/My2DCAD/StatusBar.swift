import SwiftUI

/// Barre d'état en bas du canevas : outil, position du pointeur, sélection, zoom, magnétisme.
struct StatusBar: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var pointer: PointerTracker

    var body: some View {
        HStack(spacing: 14) {
            Label(store.tool.label, systemImage: store.tool.symbol)
            Divider().frame(height: 12)
            Text(pointerText).monospacedDigit().frame(minWidth: 130, alignment: .leading)
            Divider().frame(height: 12)
            Text(selectionText).lineLimit(1)
            Spacer()
            if store.snapEnabled {
                Label("Grille \(Int(store.gridSize))", systemImage: "squareshape.split.2x2.dotted")
            }
            Text("\(Int((store.zoom * 100).rounded())) %").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    /// Position du pointeur dans l'unité de la page (échelle comprise).
    private var pointerText: String {
        let d = store.doc
        guard let p = pointer.world else { return "X —   Y —   \(d.unit.symbol)" }
        let x = Diagram.format(d.measure(p.x), decimals: d.precision)
        let y = Diagram.format(d.measure(p.y), decimals: d.precision)
        return "X \(x)   Y \(y)   \(d.unit.symbol)"
    }

    private var selectionText: String {
        if let s = store.singleSelectedShape {
            let d = store.doc
            if let g = s.dimension { return "Cote : " + d.formatLength(g.length) }
            if s.kind.isPath { return s.kind.displayName }
            let w = Diagram.format(d.measure(s.rect.width), decimals: d.precision)
            let h = Diagram.format(d.measure(s.rect.height), decimals: d.precision)
            return "\(s.kind.displayName)  L \(w) × H \(h) \(d.unit.symbol)"
        }
        let n = store.selection.count
        switch n {
        case 0: return "Aucune sélection"
        case 1: return "Connecteur"
        default: return "\(n) éléments sélectionnés"
        }
    }
}
