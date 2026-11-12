import CoreGraphics

/// Repère d'alignement affiché pendant un déplacement ou un dessin (coordonnées monde).
struct AlignmentGuide: Equatable {
    /// Ligne verticale (alignement en X) ou horizontale (alignement en Y).
    var vertical: Bool
    var position: CGFloat
    var from: CGFloat
    var to: CGFloat
}

/// Résultat de la recherche d'alignement : correction à appliquer sur chaque axe et repères à afficher.
struct AlignmentSnap {
    var dx: CGFloat?
    var dy: CGFloat?
    var guides: [AlignmentGuide] = []
}

/// Cherche un alignement des bords ou du centre de `moving` avec ceux des rectangles `targets`,
/// à moins de `tolerance`. Un point se traite comme un rectangle de taille nulle.
func alignmentSnap(moving: CGRect, targets: [CGRect], tolerance: CGFloat) -> AlignmentSnap {
    func xs(_ r: CGRect) -> [CGFloat] { [r.minX, r.midX, r.maxX] }
    func ys(_ r: CGRect) -> [CGFloat] { [r.minY, r.midY, r.maxY] }

    func best(_ own: [CGFloat], _ others: (CGRect) -> [CGFloat]) -> CGFloat? {
        var result: CGFloat?
        for t in targets {
            for v in others(t) {
                for o in own {
                    let d = v - o
                    if abs(d) <= tolerance && (result == nil || abs(d) < abs(result!)) { result = d }
                }
            }
        }
        return result
    }

    var snap = AlignmentSnap()
    snap.dx = best(xs(moving), xs)
    snap.dy = best(ys(moving), ys)
    let final = moving.offsetBy(dx: snap.dx ?? 0, dy: snap.dy ?? 0)

    // Repères : une ligne par position alignée, étendue à toutes les formes concernées.
    var vertical: [CGFloat: (CGFloat, CGFloat)] = [:]
    var horizontal: [CGFloat: (CGFloat, CGFloat)] = [:]
    for t in targets {
        if snap.dx != nil {
            for v in xs(t) where xs(final).contains(where: { abs($0 - v) < 0.01 }) {
                let lo = min(t.minY, final.minY), hi = max(t.maxY, final.maxY)
                let cur = vertical[v] ?? (lo, hi)
                vertical[v] = (min(cur.0, lo), max(cur.1, hi))
            }
        }
        if snap.dy != nil {
            for v in ys(t) where ys(final).contains(where: { abs($0 - v) < 0.01 }) {
                let lo = min(t.minX, final.minX), hi = max(t.maxX, final.maxX)
                let cur = horizontal[v] ?? (lo, hi)
                horizontal[v] = (min(cur.0, lo), max(cur.1, hi))
            }
        }
    }
    snap.guides = vertical.map { AlignmentGuide(vertical: true, position: $0.key, from: $0.value.0, to: $0.value.1) }
        + horizontal.map { AlignmentGuide(vertical: false, position: $0.key, from: $0.value.0, to: $0.value.1) }
    return snap
}
