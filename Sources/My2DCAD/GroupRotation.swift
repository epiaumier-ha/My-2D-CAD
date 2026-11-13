import SwiftUI

// Rotation des formes groupées et des sélections multiples, comme dans Visio : poignée de rotation
// au-dessus du cadre de la sélection, angle libre (Maj : pas de 15°), champ « Rotation » du volet
// Format, commandes ±90°. Tous les types de formes pivotent ensemble autour du centre du cadre :
// formes (rotation propre + position), traits, courbes et cotes (points), connecteurs (suivent
// leurs formes), cotes collées aux formes du groupe (restent collées).
//
// Un groupe garde son angle (`Shape.groupRotation`, identique pour tous ses membres) : son cadre
// reste orienté après la rotation, et le champ Rotation affiche l'angle du groupe.

/// Cadre orienté d'un ensemble de formes : centre, taille dans le repère du cadre, angle (degrés).
struct RotationFrame: Equatable {
    var center: CGPoint
    var size: CGSize
    var angle: Double

    private var radians: CGFloat { CGFloat(angle * .pi / 180) }

    /// Point du repère du cadre (origine au centre) → monde.
    func toWorld(_ local: CGPoint) -> CGPoint {
        CGPoint(x: center.x + local.x, y: center.y + local.y).rotated(by: radians, around: center)
    }

    /// Coins : haut-gauche, haut-droite, bas-droite, bas-gauche.
    var corners: [CGPoint] {
        let w = size.width / 2, h = size.height / 2
        return [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)].map(toWorld)
    }

    /// Même cadre, aux arrondis près (affichage).
    func isClose(to other: RotationFrame) -> Bool {
        var dAngle = abs(normalizedAngle(angle) - normalizedAngle(other.angle))
        dAngle = min(dAngle, 360 - dAngle)
        return center.distance(to: other.center) < 0.01 && abs(size.width - other.size.width) < 0.01
            && abs(size.height - other.size.height) < 0.01 && dAngle < 0.01
    }

        /// Milieu du bord supérieur, `margin` au-dessus (unités du dessin).
    func topCenter(margin: CGFloat = 0) -> CGPoint {
        toWorld(CGPoint(x: 0, y: -size.height / 2 - margin))
    }

    /// Cadre des formes, orienté selon `angle` (degrés) : le plus petit rectangle orienté qui les contient.
    static func enclosing(_ shapes: [Shape], angle: Double) -> RotationFrame? {
        let points = shapes.flatMap(\.outlinePoints)
        guard !points.isEmpty else { return nil }
        let a = CGFloat(angle * .pi / 180)
        // Points ramenés dans le repère du cadre (rotation inverse autour de l'origine).
        let local = points.map { $0.rotated(by: -a, around: .zero) }
        let xs = local.map(\.x), ys = local.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              [minX, maxX, minY, maxY].allSatisfy(\.isFinite) else { return nil }
        let localCenter = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        return RotationFrame(center: localCenter.rotated(by: a, around: .zero),
                             size: CGSize(width: maxX - minX, height: maxY - minY), angle: angle)
    }
}

extension Shape {
    /// Points qui délimitent la forme dans le monde : coins (rotation comprise) ou points du tracé.
    var outlinePoints: [CGPoint] { kind.isPath ? worldPoints : corners }
}

private func roundedCoordinate(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }

extension Diagram {
    /// Les formes forment-elles exactement un groupe (tous ses membres, rien d'autre) ?
    func isWholeGroup(_ shapes: [Shape]) -> Bool {
        guard shapes.count >= 2, let group = shapes.first?.groupID,
              shapes.allSatisfy({ $0.groupID == group }) else { return false }
        return self.shapes.filter({ $0.groupID == group }).count == shapes.count
    }

    /// Angle d'un ensemble de formes : celui du groupe si elles forment exactement un groupe, sinon 0.
    func rotationAngle(of shapes: [Shape]) -> Double {
        isWholeGroup(shapes) ? shapes[0].groupRotation : 0
    }

    /// Fait pivoter les formes `ids` de `degrees` autour de `pivot` : position et rotation propre des
    /// formes, points des traits, courbes et cotes, angle des groupes.
    mutating func rotateShapes(_ ids: Set<UUID>, by degrees: Double, around pivot: CGPoint) {
        guard degrees.isFinite, degrees != 0, pivot.x.isFinite, pivot.y.isFinite else { return }
        let a = CGFloat(degrees * .pi / 180)
        for i in shapes.indices where ids.contains(shapes[i].id) {
            var s = shapes[i]
            if s.kind.isPath {
                let pts = s.worldPoints.map { $0.rotated(by: a, around: pivot) }
                s.setWorldPoints(pts.map { CGPoint(x: roundedCoordinate($0.x), y: roundedCoordinate($0.y)) })
            } else {
                let c = s.center.rotated(by: a, around: pivot)
                let size = s.rect.size
                s.rect.origin = CGPoint(x: roundedCoordinate(c.x - size.width / 2),
                                        y: roundedCoordinate(c.y - size.height / 2))
                s.rotation = normalizedAngle(s.rotation + degrees)
            }
            if s.groupID != nil { s.groupRotation = normalizedAngle(s.groupRotation + degrees) }
            shapes[i] = s
        }
    }
}

@MainActor
extension DocumentStore {
    /// Cadre de rotation de la sélection quand elle compte plusieurs formes (groupe ou sélection
    /// multiple) ; une forme seule a sa propre poignée.
    var selectionRotationFrame: RotationFrame? {
        let shapes = selectedShapes
        guard shapes.count >= 2 else { return nil }
        return RotationFrame.enclosing(shapes, angle: doc.rotationAngle(of: shapes))
    }

    /// Cadres orientés des groupes entièrement sélectionnés (affichage en pointillés).
    var selectedGroupFrames: [RotationFrame] {
        let groups = Dictionary(grouping: selectedShapes.filter { $0.groupID != nil }, by: { $0.groupID! })
        return groups.values.compactMap { members in
            guard members.count > 1 else { return nil }
            return RotationFrame.enclosing(members, angle: doc.rotationAngle(of: members))
        }
    }

    /// Fait pivoter la sélection d'un bloc autour du centre de son cadre (commandes ±90°, assistant).
    func rotateSelection(by degrees: Double) {
        guard degrees.isFinite else { return }
        let shapes = selectedShapes
        guard !shapes.isEmpty else { return }
        let pivot: CGPoint
        if let frame = selectionRotationFrame {
            pivot = frame.center
        } else {
            let b = shapes[0].bounds
            pivot = CGPoint(x: b.midX, y: b.midY)
        }
        let ids = Set(shapes.map(\.id))
        perform { $0.rotateShapes(ids, by: degrees, around: pivot) }
    }

    /// Donne l'angle `degrees` à la sélection (champ Rotation du volet) : pour un groupe, l'angle
    /// du groupe ; pour une sélection multiple, l'angle de départ est 0.
    func setSelectionRotation(_ degrees: Double) {
        guard degrees.isFinite, let frame = selectionRotationFrame else { return }
        var delta = (normalizedAngle(degrees) - frame.angle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        guard abs(delta) > 1e-9 else { return }
        let ids = Set(selectedShapes.map(\.id))
        let pivot = frame.center
        perform { $0.rotateShapes(ids, by: delta, around: pivot) }
    }

    /// Rotation en cours à la poignée : les formes d'origine pivotées de `degrees` (sans historique,
    /// à l'intérieur d'une transaction).
    func applyLiveRotation(originals: [Shape], by degrees: Double, around pivot: CGPoint) {
        var d = doc
        let byID = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
        for i in d.shapes.indices {
            if let o = byID[d.shapes[i].id] { d.shapes[i] = o }
        }
        d.rotateShapes(Set(byID.keys), by: degrees, around: pivot)
        if d != doc { doc = d }
    }
}
