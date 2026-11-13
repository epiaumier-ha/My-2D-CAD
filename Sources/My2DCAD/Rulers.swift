import SwiftUI

/// Règles graduées (unité de la page) en haut et à gauche du dessin. Glisser depuis une règle
/// crée un repère ; un repère ramené sur la règle est supprimé.
struct DrawingArea: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        if store.showRulers {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: RulerView.thickness, height: RulerView.thickness)
                        .overlay(Text(store.doc.unit.symbol).font(.system(size: 8)).foregroundStyle(.secondary))
                        .help("Unité : \(store.doc.unit.label) — échelle 1:\(Diagram.format(store.doc.scale, decimals: 0))")
                    RulerView(vertical: false, pointer: store.pointer)
                }
                HStack(spacing: 0) {
                    RulerView(vertical: true, pointer: store.pointer)
                    CanvasView()
                }
            }
            .coordinateSpace(name: RulerView.space)
        } else {
            CanvasView()
        }
    }
}

struct RulerView: View {
    static let thickness: CGFloat = 20
    static let space = "drawingArea"

    /// Règle verticale (à gauche) : elle crée des repères verticaux.
    let vertical: Bool
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var pointer: PointerTracker

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size: size) }
            .frame(width: vertical ? Self.thickness : nil, height: vertical ? nil : Self.thickness)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                    .onChanged { v in
                        let p = store.snap(store.toWorld(canvasPoint(v.location)))
                        store.rulerGuidePreview = GuideLine(vertical: vertical, position: vertical ? p.x : p.y)
                    }
                    .onEnded { v in
                        let c = canvasPoint(v.location)
                        if let g = store.rulerGuidePreview, c.x >= 0, c.y >= 0 { store.addGuide(g) }
                        store.rulerGuidePreview = nil
                    }
            )
            .help(vertical ? "Glissez vers le dessin pour créer un repère vertical"
                           : "Glissez vers le dessin pour créer un repère horizontal")
    }

    /// Point dans le repère du canevas (qui commence après les règles).
    private func canvasPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - Self.thickness, y: p.y - Self.thickness)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .windowBackgroundColor)))
        let d = store.doc
        let worldPerUnit = d.worldLength(forMeasure: 1)
        let pxPerUnit = Double(worldPerUnit * store.zoom)
        guard pxPerUnit.isFinite, pxPerUnit > 0 else { return }

        // Pas principal : 1, 2 ou 5 × 10^k unités, au moins 50 pixels entre deux graduations.
        var step = pow(10, floor(log10(50 / pxPerUnit)))
        for m in [1.0, 2, 5, 10] where pxPerUnit * step * m >= 50 { step *= m; break }
        let subdivisions = pxPerUnit * step / 10 >= 5 ? 10 : (pxPerUnit * step / 5 >= 5 ? 5 : 2)
        let decimals = step >= 1 ? 0 : Int(-floor(log10(step)))

        let length = Double(vertical ? size.height : size.width)
        let offset = Double(vertical ? store.offset.height : store.offset.width)
        let startValue = -offset / pxPerUnit, endValue = (length - offset) / pxPerUnit
        let thick = Double(Self.thickness)

        var ticks = Path()
        var value = floor(startValue / step) * step
        var count = 0
        while value <= endValue && count < 500 {
            for k in 0..<subdivisions {
                let v = value + step * Double(k) / Double(subdivisions)
                let pos = offset + v * pxPerUnit
                guard pos >= 0, pos <= length else { continue }
                let h = k == 0 ? thick : (subdivisions == 10 && k == 5 ? thick * 0.45 : thick * 0.25)
                if vertical {
                    ticks.move(to: CGPoint(x: thick, y: pos)); ticks.addLine(to: CGPoint(x: thick - h, y: pos))
                } else {
                    ticks.move(to: CGPoint(x: pos, y: thick)); ticks.addLine(to: CGPoint(x: pos, y: thick - h))
                }
            }
            let pos = offset + value * pxPerUnit
            let label = Text(Diagram.format(value, decimals: decimals)).font(.system(size: 9)).foregroundColor(.secondary)
            if vertical {
                var tc = ctx
                tc.translateBy(x: 2, y: pos + 2)
                tc.rotate(by: .degrees(-90))
                tc.draw(label, at: .zero, anchor: .bottomTrailing)
            } else {
                ctx.draw(label, at: CGPoint(x: pos + 2, y: 1), anchor: .topLeading)
            }
            value += step
            count += 1
        }
        ctx.stroke(ticks, with: .color(.secondary), lineWidth: 0.5)

        // Bordure côté dessin et position du pointeur.
        var border = Path()
        if vertical {
            border.move(to: CGPoint(x: thick - 0.5, y: 0)); border.addLine(to: CGPoint(x: thick - 0.5, y: length))
        } else {
            border.move(to: CGPoint(x: 0, y: thick - 0.5)); border.addLine(to: CGPoint(x: length, y: thick - 0.5))
        }
        ctx.stroke(border, with: .color(.gray.opacity(0.5)), lineWidth: 1)
        if let w = pointer.world {
            let p = store.toScreen(w)
            var marker = Path()
            if vertical {
                marker.move(to: CGPoint(x: 0, y: p.y)); marker.addLine(to: CGPoint(x: thick, y: p.y))
            } else {
                marker.move(to: CGPoint(x: p.x, y: 0)); marker.addLine(to: CGPoint(x: p.x, y: thick))
            }
            ctx.stroke(marker, with: .color(.red.opacity(0.8)), lineWidth: 1)
        }
    }
}

// MARK: - Repères et réglages de page

@MainActor
extension DocumentStore {
    func addGuide(_ guide: GuideLine) {
        guard doc.guides.count < Diagram.maxGuides, guide.position.isFinite,
              abs(guide.position) <= DiagramIO.maxCoordinate else { return }
        perform { $0.guides.append(guide) }
    }

    func removeAllGuides() {
        perform { $0.guides.removeAll() }
    }

    /// Réglages de la page affichée (unité, échelle, décimales, routage des nouveaux connecteurs).
    func updatePageSettings(_ change: (inout Diagram) -> Void) {
        let before = doc
        var d = before
        change(&d)
        if !Diagram.scaleRange.contains(d.scale) || !d.scale.isFinite { d.scale = before.scale }
        d.precision = min(max(d.precision, 0), 4)
        if d.scale != before.scale {
            // Comme Visio : changer d'échelle garde les dimensions réelles ; le dessin est
            // agrandi ou réduit sur la feuille (et donc à l'écran) en conséquence.
            d.rescaleDrawing(by: CGFloat(before.scale / d.scale),
                             includingGridSpacing: d.grid.fixedSpacing == before.grid.fixedSpacing)
            guard (try? DiagramIO.validate(d)) != nil else {
                NSSound.beep()   // le dessin deviendrait trop grand ou trop petit : échelle refusée
                return
            }
        }
        let result = d
        perform { $0 = result }
        // Vue encore ajustée sur la page : elle suit le nouveau format de feuille.
        if autoFitPage, result.sheetRect != before.sheetRect { fitPage() }
    }
}

extension Diagram {
    /// Agrandit ou réduit tout le dessin autour de l'origine de la feuille (facteur f) :
    /// formes, traits, cotes, blocs de texte, repères et grille fixe métrique.
    /// La taille des textes et l'épaisseur des traits (grandeurs du papier) ne changent pas.
    mutating func rescaleDrawing(by f: CGFloat, includingGridSpacing: Bool = true) {
        guard f.isFinite, f > 0, abs(f - 1) > 1e-12 else { return }
        for i in shapes.indices {
            var s = shapes[i]
            if s.kind.isPath {
                s.setWorldPoints(s.worldPoints.map { CGPoint(x: $0.x * f, y: $0.y * f) })
            } else {
                s.rect = CGRect(x: s.rect.minX * f, y: s.rect.minY * f,
                                width: s.rect.width * f, height: s.rect.height * f)
            }
            s.textOffset = CGPoint(x: s.textOffset.x * f, y: s.textOffset.y * f)
            if let w = s.textBlockWidth { s.textBlockWidth = w * Double(f) }
            shapes[i] = s
        }
        for i in guides.indices { guides[i].position *= f }
        if includingGridSpacing, grid.measure == .metric {
            grid.fixedSpacing = min(max(grid.fixedSpacing * Double(f), GridSettings.spacingRange.lowerBound),
                                    GridSettings.spacingRange.upperBound)
        }
    }
}
