import SwiftUI
import AppKit

// MARK: - Volets réductibles et redimensionnables (comme dans Visio)
//
// Chaque volet latéral peut être réduit en une fine bande (un clic la rouvre) et élargi ou rétréci
// en faisant glisser son bord. Largeur et état réduit sont mémorisés d'une session à l'autre.

enum SidePanel: String, CaseIterable {
    case shapes, assistant, format

    var title: String {
        switch self {
        case .shapes: return "Formes"
        case .assistant: return "Assistant"
        case .format: return "Format de la forme"
        }
    }

    var symbol: String {
        switch self {
        case .shapes: return "square.on.circle"
        case .assistant: return "sparkles"
        case .format: return "paintbrush"
        }
    }

    /// Côté de la fenêtre où se trouve le volet.
    var edge: HorizontalEdge { self == .shapes ? .leading : .trailing }

    var widthKey: String { "panel.\(rawValue).width" }
    var collapsedKey: String { "panel.\(rawValue).collapsed" }

    var defaultWidth: Double {
        switch self {
        case .shapes: return 220
        case .assistant: return 320
        case .format: return 290
        }
    }

    var widthRange: ClosedRange<Double> {
        switch self {
        case .shapes: return 170...420
        case .assistant: return 260...600
        case .format: return 250...480
        }
    }

    /// Largeur d'un volet réduit.
    static let collapsedWidth: CGFloat = 30
}

/// Volet latéral : contenu à sa largeur avec une poignée de redimensionnement côté dessin,
/// ou bande étroite quand il est réduit.
struct SidePanelContainer<Content: View>: View {
    let panel: SidePanel
    @ViewBuilder let content: () -> Content
    @AppStorage private var width: Double
    @AppStorage private var collapsed: Bool
    @Environment(\.colorScheme) private var scheme

    init(_ panel: SidePanel, @ViewBuilder content: @escaping () -> Content) {
        self.panel = panel
        self.content = content
        _width = AppStorage(wrappedValue: panel.defaultWidth, panel.widthKey)
        _collapsed = AppStorage(wrappedValue: false, panel.collapsedKey)
    }

    var body: some View {
        HStack(spacing: 0) {
            if panel.edge == .trailing { handle }
            if collapsed {
                CollapsedPanelStrip(panel: panel) { collapsed = false }
            } else {
                content()
                    .frame(width: CGFloat(min(max(width, panel.widthRange.lowerBound), panel.widthRange.upperBound)))
                    .background(VisioTheme.pane(scheme))
            }
            if panel.edge == .leading { handle }
        }
    }

    @ViewBuilder
    private var handle: some View {
        if collapsed {
            Divider()
        } else {
            PanelResizeHandle(width: $width, range: panel.widthRange, growsToTheRight: panel.edge == .leading)
        }
    }
}

/// Bande d'un volet réduit : icône, titre vertical ; un clic rouvre le volet.
struct CollapsedPanelStrip: View {
    let panel: SidePanel
    let expand: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: expand) {
            VStack(spacing: 10) {
                Image(systemName: panel.edge == .leading ? "chevron.right" : "chevron.left")
                    .font(.caption.weight(.semibold))
                Image(systemName: panel.symbol)
                Text(panel.title)
                    .font(.callout.weight(.medium))
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 20, height: 150)
                Spacer()
            }
            .padding(.top, 10)
            .frame(width: SidePanel.collapsedWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(VisioTheme.pane(scheme))
        .help("Développer le volet \(panel.title)")
    }
}

/// Bouton de l'en-tête d'un volet qui le réduit en bande.
struct PanelCollapseButton: View {
    let panel: SidePanel
    @AppStorage private var collapsed: Bool

    init(_ panel: SidePanel) {
        self.panel = panel
        _collapsed = AppStorage(wrappedValue: false, panel.collapsedKey)
    }

    var body: some View {
        Button { collapsed = true } label: {
            Image(systemName: panel.edge == .leading ? "chevron.left" : "chevron.right")
        }
        .buttonStyle(.borderless)
        .help("Réduire le volet")
    }
}

/// Bord d'un volet : faire glisser pour changer sa largeur ; double-clic : largeur par défaut.
struct PanelResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Volet de gauche : glisser vers la droite l'élargit ; volet de droite : l'inverse.
    let growsToTheRight: Bool
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                if startWidth == nil { startWidth = start }
                                let delta = Double(value.translation.width) * (growsToTheRight ? 1 : -1)
                                width = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
                    .help("Glisser pour changer la largeur du volet")
            )
            .onDisappear {
                if hovering { NSCursor.pop(); hovering = false }
            }
    }
}

@MainActor
enum PanelState {
    /// Réduit ou développe tous les volets latéraux affichés.
    static func setAllCollapsed(_ collapsed: Bool) {
        for panel in SidePanel.allCases {
            UserDefaults.standard.set(collapsed, forKey: panel.collapsedKey)
        }
    }

    /// Rend leur largeur par défaut aux volets et les développe.
    static func reset() {
        for panel in SidePanel.allCases {
            UserDefaults.standard.set(panel.defaultWidth, forKey: panel.widthKey)
            UserDefaults.standard.set(false, forKey: panel.collapsedKey)
        }
    }
}
