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
            Spacer(minLength: 8)
            Text(hint).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
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

    /// Aide contextuelle selon l'outil (raccourcis utiles).
    private var hint: String {
        switch store.tool {
        case .select:
            return "Double-clic : texte · ⌥-glisser : dupliquer · Maj : ajouter à la sélection · Espace : déplacer la vue"
        case .pan: return "Glisser pour déplacer la vue · V : sélection"
        case .text: return "Clic ou glisser pour créer un texte · Échap : sélection"
        case .connector: return "Glisser d'une forme à une autre · Échap : sélection"
        case .line, .dimension: return "Glisser pour tracer · Maj : 45° · Échap : sélection"
        case .curve: return "Glisser, puis régler la courbure avec la poignée ronde · Échap : sélection"
        case .rectangle, .ellipse, .diamond: return "Clic : taille par défaut · Glisser : taille libre · Échap : sélection"
        }
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
