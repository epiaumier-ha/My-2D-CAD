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

    private var pointerText: String {
        guard let p = pointer.world else { return "X —   Y —" }
        return String(format: "X %.0f   Y %.0f", p.x, p.y)
    }

    private var selectionText: String {
        if let s = store.singleSelectedShape {
            if s.kind.isPath { return s.kind.displayName }
            return String(format: "%@  L %.0f × H %.0f", s.kind.displayName, s.rect.width, s.rect.height)
        }
        let n = store.selection.count
        switch n {
        case 0: return "Aucune sélection"
        case 1: return "Connecteur"
        default: return "\(n) éléments sélectionnés"
        }
    }
}
