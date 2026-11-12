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
                Label("Grille " + store.doc.gridSpacingText(zoom: store.zoom),
                      systemImage: "squareshape.split.2x2.dotted")
                    .help("Magnétisme activé : les formes s'alignent sur la grille")
            }
            // Zoom à droite, comme dans Visio : réduire, curseur, agrandir, pourcentage, ajuster.
            Button { store.zoom(by: 0.8) } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).help("Zoom arrière (⌘-)")
            Slider(value: Binding(
                get: { min(max(log2(Double(store.zoom)), -3), 3) },
                set: { store.setZoom(CGFloat(pow(2, $0))) }), in: -3...3)
                .controlSize(.mini)
                .frame(width: 110)
                .help("Zoom")
            Button { store.zoom(by: 1.25) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("Zoom avant (⌘+)")
            ZoomMenu()
            Button { store.fitToContent() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless).help("Ajuster à la fenêtre (⌘9)")
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
            if let s = store.singleSelectedShape, s.kind.isDimension {
                return "Glisser une extrémité sur un coin, un milieu ou un centre pour coller la cote · Poignée ronde : position de la cote"
            }
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
            if s.kind.isDimension { return s.kind.displayName + " : " + d.dimensionMeasure(s) }
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
