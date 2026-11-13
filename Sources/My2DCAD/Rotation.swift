import SwiftUI

// Rotation de toutes les formes, comme dans Visio : poignée ronde, angle libre (Maj : pas de 15°),
// champ « Rotation » / « Angle » du volet Format, commandes ±90°.
//
// - Forme seule : formes classiques (rotation propre), traits, courbes et cotes (points pivotés).
//   Angle d'un trait, d'une courbe ou d'une cote : direction du premier au dernier point.
// - Groupe ou sélection multiple : toutes les formes pivotent ensemble ; les connecteurs suivent,
//   les cotes collées aux formes de l'ensemble le restent. Un groupe garde son angle
//   (`Shape.groupRotation`) : son cadre reste orienté.
//
// Point de rotation (l'« axe » de Visio) : centre de la forme ou du cadre par défaut ; il se déplace
// à la souris (accrochage aux coins, milieux et centres des formes, puis à la grille) et il est
// mémorisé par forme (`Shape.pin`) et par groupe (`Shape.groupPin`), en coordonnées relatives :
// il suit la forme quand elle bouge. Pour une sélection multiple, il vaut pour la sélection en cours.

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

    /// Monde → repère du cadre (origine au centre).
    func toLocal(_ world: CGPoint) -> CGPoint {
        let p = world.rotated(by: -radians, around: center)
        return CGPoint(x: p.x - center.x, y: p.y - center.y)
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

    /// Point de rotation : position relative dans le cadre (0…1, nil = centre) → monde.
    func point(forPin pin: CGPoint?) -> CGPoint {
        guard let pin else { return center }
        return toWorld(CGPoint(x: (pin.x - 0.5) * size.width, y: (pin.y - 0.5) * size.height))
    }

    /// Position relative d'un point du monde dans le cadre (nil si le cadre est dégénéré).
    func pin(for world: CGPoint) -> CGPoint? {
        guard size.width > 1e-9, size.height > 1e-9 else { return nil }
        let l = toLocal(world)
        return Shape.clampedPin(CGPoint(x: l.x / size.width + 0.5, y: l.y / size.height + 0.5))
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
    /// Limite des positions relatives du point de rotation (il peut sortir de la forme, sans excès).
    static let pinRange: ClosedRange<CGFloat> = -10...11

    static func clampedPin(_ p: CGPoint) -> CGPoint? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return CGPoint(x: min(max(p.x, pinRange.lowerBound), pinRange.upperBound),
                       y: min(max(p.y, pinRange.lowerBound), pinRange.upperBound))
    }

    /// Points qui délimitent la forme dans le monde : coins (rotation comprise) ou points du tracé.
    var outlinePoints: [CGPoint] { kind.isPath ? worldPoints : corners }

    /// Angle affiché (degrés, sens horaire à l'écran) : rotation propre d'une forme ; direction
    /// du premier au dernier point d'un trait, d'une courbe ou d'une cote.
    var displayAngle: Double {
        guard kind.isPath else { return rotation }
        let p = worldPoints
        guard let a = p.first, let b = p.last, a.distance(to: b) > 1e-9 else { return 0 }
        return normalizedAngle(Double(atan2(b.y - a.y, b.x - a.x)) * 180 / .pi)
    }

    /// Centre de la forme : point de rotation par défaut.
    var rotationCenter: CGPoint {
        guard kind.isPath else { return center }
        let p = worldPoints
        let xs = p.map(\.x), ys = p.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return center }
        return CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    /// Repère d'un tracé : premier point, direction vers le dernier point et perpendiculaire.
    private var chordFrame: (origin: CGPoint, along: CGVector, across: CGVector)? {
        let p = worldPoints
        guard let a = p.first, let b = p.last, a.distance(to: b) > 1e-9 else { return nil }
        let d = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        return (a, d, CGVector(dx: -d.dy, dy: d.dx))
    }

    /// Point de rotation dans le monde : centre par défaut, ou point choisi (`pin`, relatif à la forme).
    var pivotPoint: CGPoint {
        guard let pin else { return rotationCenter }
        if kind.isPath {
            guard let f = chordFrame else { return rotationCenter }
            return CGPoint(x: f.origin.x + f.along.dx * pin.x + f.across.dx * pin.y,
                           y: f.origin.y + f.along.dy * pin.x + f.across.dy * pin.y)
        }
        return toWorld(CGPoint(x: rect.minX + pin.x * rect.width, y: rect.minY + pin.y * rect.height))
    }

    /// Position relative (`pin`) d'un point du monde : rectangle de la forme (0…1), ou, pour un tracé,
    /// repère premier point → dernier point. nil si la forme est dégénérée.
    func pin(for world: CGPoint) -> CGPoint? {
        if kind.isPath {
            guard let f = chordFrame else { return nil }
            let q = CGVector(dx: world.x - f.origin.x, dy: world.y - f.origin.y)
            let len2 = f.along.dx * f.along.dx + f.along.dy * f.along.dy
            return Shape.clampedPin(CGPoint(x: (q.dx * f.along.dx + q.dy * f.along.dy) / len2,
                                            y: (q.dx * f.across.dx + q.dy * f.across.dy) / len2))
        }
        guard rect.width > 1e-9, rect.height > 1e-9 else { return nil }
        let l = toLocal(world)
        return Shape.clampedPin(CGPoint(x: (l.x - rect.minX) / rect.width, y: (l.y - rect.minY) / rect.height))
    }
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
    /// formes, points des traits, courbes et cotes, angle des groupes. Les points de rotation choisis,
    /// relatifs aux formes, pivotent avec elles.
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

/// Point de rotation d'une sélection multiple (hors groupe) : valable pour cette sélection seulement.
struct SelectionPin: Equatable {
    var ids: Set<UUID>
    var point: CGPoint
}

/// Ce qui pivote : formes, angle affiché, point de rotation, cadre (groupe ou sélection multiple).
struct RotationTarget {
    var ids: Set<UUID>
    var angle: Double
    var pivot: CGPoint
    /// Point de rotation par défaut : centre de la forme ou du cadre.
    var center: CGPoint
    /// Cadre d'un groupe ou d'une sélection multiple (nil pour une forme seule).
    var frame: RotationFrame?
    var isGroup: Bool
    /// Point de rotation choisi (nil : centre).
    var hasCustomPivot: Bool
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

    /// Formes sélectionnées, angle et point de rotation (nil sans forme sélectionnée).
    var selectionRotationTarget: RotationTarget? {
        let shapes = selectedShapes
        if shapes.count == 1 {
            let s = shapes[0]
            return RotationTarget(ids: [s.id], angle: s.displayAngle, pivot: s.pivotPoint, center: s.rotationCenter,
                                  frame: nil, isGroup: false, hasCustomPivot: s.pin != nil)
        }
        guard shapes.count >= 2,
              let frame = RotationFrame.enclosing(shapes, angle: doc.rotationAngle(of: shapes)) else { return nil }
        let ids = Set(shapes.map(\.id))
        if doc.isWholeGroup(shapes) {
            let pin = shapes[0].groupPin
            return RotationTarget(ids: ids, angle: frame.angle, pivot: frame.point(forPin: pin), center: frame.center,
                                  frame: frame, isGroup: true, hasCustomPivot: pin != nil)
        }
        let pin = selectionPin?.ids == selection ? selectionPin?.point : nil
        return RotationTarget(ids: ids, angle: frame.angle, pivot: pin ?? frame.center, center: frame.center,
                              frame: frame, isGroup: false, hasCustomPivot: pin != nil)
    }

    /// Fait pivoter la sélection d'un bloc autour de son point de rotation (commandes ±90°, assistant).
    func rotateSelection(by degrees: Double) {
        guard degrees.isFinite, let target = selectionRotationTarget else { return }
        perform { $0.rotateShapes(target.ids, by: degrees, around: target.pivot) }
    }

    /// Donne l'angle `degrees` à la sélection (champs Rotation / Angle du volet) : rotation d'une
    /// forme, direction d'un trait, angle d'un groupe ; une sélection multiple part de 0.
    func setSelectionRotation(_ degrees: Double) {
        guard degrees.isFinite, let target = selectionRotationTarget else { return }
        var delta = (normalizedAngle(degrees) - normalizedAngle(target.angle)).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        guard abs(delta) > 1e-9 else { return }
        perform { $0.rotateShapes(target.ids, by: delta, around: target.pivot) }
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

    /// Place le point de rotation de la sélection (nil : centre). Sans historique : à utiliser dans une
    /// transaction (glisser) ; `setRotationPin` pour une commande.
    func applyRotationPin(_ world: CGPoint?) {
        let shapes = selectedShapes
        if shapes.count == 1 {
            let s = shapes[0]
            let pin = world.flatMap { s.pin(for: $0) }
            if let i = doc.shapes.firstIndex(where: { $0.id == s.id }), doc.shapes[i].pin != pin {
                doc.shapes[i].pin = pin
            }
            return
        }
        guard shapes.count >= 2 else { return }
        if doc.isWholeGroup(shapes) {
            guard let frame = RotationFrame.enclosing(shapes, angle: doc.rotationAngle(of: shapes)) else { return }
            let pin = world.flatMap { frame.pin(for: $0) }
            let ids = Set(shapes.map(\.id))
            var d = doc
            for i in d.shapes.indices where ids.contains(d.shapes[i].id) { d.shapes[i].groupPin = pin }
            if d != doc { doc = d }
        } else {
            selectionPin = world.map { SelectionPin(ids: selection, point: $0) }
        }
    }

    /// Place le point de rotation de la sélection (nil : retour au centre), avec historique.
    func setRotationPin(_ world: CGPoint?) {
        beginTransaction()
        applyRotationPin(world)
        commitTransaction()
    }
}
