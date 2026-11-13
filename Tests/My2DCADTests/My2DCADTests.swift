import XCTest
import struct SwiftUI.Path
import PDFKit
@testable import My2DCAD

final class GeometryTests: XCTestCase {
    func testEllipseAndDiamondHitTest() {
        let e = Shape(kind: .ellipse, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(e.contains(CGPoint(x: 50, y: 50)))
        XCTAssertFalse(e.contains(CGPoint(x: 2, y: 2)))   // coin hors de l'ellipse
        let d = Shape(kind: .diamond, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(d.contains(CGPoint(x: 50, y: 50)))
        XCTAssertFalse(d.contains(CGPoint(x: 5, y: 5)))
    }

    func testNearestPort() {
        let s = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(s.nearestPort(to: CGPoint(x: 120, y: 25)), 1)
        XCTAssertEqual(s.nearestPort(to: CGPoint(x: -20, y: 25)), 3)
        XCTAssertEqual(s.nearestPort(to: CGPoint(x: 50, y: -20)), 0)
        XCTAssertEqual(s.nearestPort(to: CGPoint(x: 50, y: 80)), 2)
    }

    func testRouteIsOrthogonal() {
        for pa in 0..<Port.count {
            for pb in 0..<Port.count {
                let pts = routeConnector(from: CGPoint(x: 10, y: 20), portA: pa,
                                         to: CGPoint(x: 200, y: 90), portB: pb)
                for i in 0..<(pts.count - 1) {
                    XCTAssertTrue(pts[i].x == pts[i + 1].x || pts[i].y == pts[i + 1].y)
                }
            }
        }
    }
}

final class PersistenceTests: XCTestCase {
    private func sample() -> Diagram {
        let a = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50), text: "A")
        let b = Shape(kind: .ellipse, rect: CGRect(x: 200, y: 0, width: 100, height: 50), text: "B")
        let c = Connector(fromShape: a.id, fromPort: 1, toShape: b.id, toPort: 3)
        return Diagram(shapes: [a, b], connectors: [c])
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        let d = sample()
        try DiagramIO.save(d, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url).pages, [d])
    }

    func testRejectsOrphanConnector() {
        var d = sample()
        d.connectors[0].toShape = UUID()
        XCTAssertThrowsError(try DiagramIO.validate(d))
    }

    func testRejectsInvalidPortAndRect() {
        var d = sample()
        d.connectors[0].fromPort = 9
        XCTAssertThrowsError(try DiagramIO.validate(d))
        var e = sample()
        e.shapes[0].rect.size.width = .infinity
        XCTAssertThrowsError(try DiagramIO.validate(e))
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func testUndoRedo() {
        let store = DocumentStore()
        store.perform { $0.shapes.append(Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10))) }
        XCTAssertEqual(store.doc.shapes.count, 1)
        store.undo()
        XCTAssertEqual(store.doc.shapes.count, 0)
        store.redo()
        XCTAssertEqual(store.doc.shapes.count, 1)
    }

    func testDeleteShapeRemovesItsConnectors() {
        let store = DocumentStore()
        let a = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = Shape(kind: .rectangle, rect: CGRect(x: 50, y: 0, width: 10, height: 10))
        store.perform {
            $0.shapes = [a, b]
            $0.connectors = [Connector(fromShape: a.id, fromPort: 1, toShape: b.id, toPort: 3)]
        }
        store.selection = [a.id]
        store.deleteSelection()
        XCTAssertEqual(store.doc.shapes.count, 1)
        XCTAssertTrue(store.doc.connectors.isEmpty)
    }
}

final class RotationTests: XCTestCase {
    /// Rectangle 100×20 pivoté de 90° autour de son centre (50, 10).
    private let rotated = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 20), rotation: 90)

    func testHitTestFollowsRotation() {
        XCTAssertTrue(rotated.contains(CGPoint(x: 50, y: 50)))
        XCTAssertFalse(rotated.contains(CGPoint(x: 90, y: 10)))   // dans le rectangle non pivoté seulement
    }

    func testBoundsAndPortsFollowRotation() {
        XCTAssertEqual(rotated.bounds.width, 20, accuracy: 1e-9)
        XCTAssertEqual(rotated.bounds.height, 100, accuracy: 1e-9)
        let right = rotated.portPoint(1)          // le point « droite » passe en bas
        XCTAssertEqual(right.x, 50, accuracy: 1e-9)
        XCTAssertEqual(right.y, 60, accuracy: 1e-9)
        let dir = rotated.portDirection(1)
        XCTAssertEqual(dir.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(dir.dy, 1, accuracy: 1e-9)
    }

    func testNormalizedAngle() {
        XCTAssertEqual(normalizedAngle(-90), 270)
        XCTAssertEqual(normalizedAngle(360), 0)
        XCTAssertEqual(normalizedAngle(725), 5)
    }

    func testDecodesFileWithoutRotation() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"rectangle","rect":[[0,0],[10,10]],"text":"","fill":{"r":1,"g":1,"b":1,"a":1}}
        """
        let s = try JSONDecoder().decode(Shape.self, from: Data(json.utf8))
        XCTAssertEqual(s.rotation, 0)
    }
}

@MainActor
final class ArrangeTests: XCTestCase {
    private func storeWith(_ rects: [CGRect]) -> DocumentStore {
        let store = DocumentStore()
        let shapes = rects.map { Shape(kind: .rectangle, rect: $0) }
        store.perform { $0.shapes = shapes }
        store.selection = Set(shapes.map(\.id))
        return store
    }

    func testAlignLeft() {
        let store = storeWith([CGRect(x: 10, y: 0, width: 50, height: 20),
                               CGRect(x: 80, y: 40, width: 30, height: 20)])
        store.align(.left)
        XCTAssertTrue(store.doc.shapes.allSatisfy { $0.rect.minX == 10 })
        store.undo()
        XCTAssertEqual(store.doc.shapes[1].rect.minX, 80)
    }

    func testDistributeHorizontally() {
        let store = storeWith([CGRect(x: 0, y: 0, width: 20, height: 20),
                               CGRect(x: 30, y: 0, width: 20, height: 20),
                               CGRect(x: 180, y: 0, width: 20, height: 20)])
        store.distribute(.horizontal)
        // Espace total 200, formes 60 → deux écarts de 70 : la forme du milieu va en x = 90.
        XCTAssertEqual(store.doc.shapes[1].rect.minX, 90, accuracy: 1e-9)
        XCTAssertEqual(store.doc.shapes[0].rect.minX, 0)
        XCTAssertEqual(store.doc.shapes[2].rect.minX, 180)
    }

    func testRotateSelectionKeepsSizeAndPivot() {
        let store = storeWith([CGRect(x: 0, y: 0, width: 100, height: 20)])
        store.rotateSelection(by: 90)
        let s = store.doc.shapes[0]
        XCTAssertEqual(s.rotation, 90)
        XCTAssertEqual(s.rect.size, CGSize(width: 100, height: 20))
        XCTAssertEqual(s.center.x, 50, accuracy: 1e-6)
        XCTAssertEqual(s.center.y, 10, accuracy: 1e-6)
    }

    func testFragmentPasteRemapsIDsAndConnectors() {
        let store = storeWith([CGRect(x: 0, y: 0, width: 20, height: 20),
                               CGRect(x: 100, y: 0, width: 20, height: 20)])
        let a = store.doc.shapes[0].id, b = store.doc.shapes[1].id
        store.perform { $0.connectors = [Connector(fromShape: a, fromPort: 1, toShape: b, toPort: 3)] }
        let fragment = store.makeFragment()!
        XCTAssertEqual(fragment.connectors.count, 1)

        XCTAssertTrue(store.insertFragment(fragment, offset: 20))
        XCTAssertEqual(store.doc.shapes.count, 4)
        XCTAssertEqual(store.doc.connectors.count, 2)
        XCTAssertEqual(Set(store.doc.shapes.map(\.id)).count, 4)
        let pasted = store.doc.connectors[1]
        XCTAssertTrue(store.selection.contains(pasted.fromShape) && store.selection.contains(pasted.toShape))
        XCTAssertEqual(store.doc.shape(pasted.fromShape)?.rect.minX, 20)
    }

    func testInvalidFragmentIsRejected() {
        let store = DocumentStore()
        var bad = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        bad.rotation = .nan
        XCTAssertFalse(store.insertFragment(ClipboardFragment(shapes: [bad], connectors: []), offset: 0))
        XCTAssertTrue(store.doc.shapes.isEmpty)
    }
}

final class StencilTests: XCTestCase {
    func testEveryKindDrawsInsideItsRect() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 60)
        for kind in ShapeKind.allCases {
            let parts = kind.paths(in: r)
            XCTAssertFalse(parts.outline.isEmpty, "\(kind) n'a pas de tracé")
            // boundingBoxOfPath : enveloppe exacte, sans les points de contrôle des courbes.
            let b = parts.fill.cgPath.boundingBoxOfPath.union(parts.stroke.cgPath.boundingBoxOfPath)
            XCTAssertTrue(r.insetBy(dx: -1, dy: -1).contains(b), "\(kind) déborde de son cadre : \(b)")
        }
    }

    func testCatalogIsConsistent() {
        let items = StencilCatalog.libraries.flatMap(\.items)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "élément présent deux fois")
        // Hors cotation (variantes ingénierie / architecture), un type n'apparaît qu'une fois.
        let plain = items.filter { !$0.kind.isDimension }
        XCTAssertEqual(Set(plain.map(\.kind)).count, plain.count, "type présent dans deux bibliothèques")
        for item in items {
            XCTAssertGreaterThan(item.size.width, 0)
            XCTAssertGreaterThan(item.size.height, 0)
        }
        // Tous les types sauf « texte » sont proposés dans une bibliothèque.
        for kind in ShapeKind.allCases where kind != .text && kind != .freeform && !kind.isPath {
            XCTAssertNotNil(StencilCatalog.item(for: kind), "\(kind) absent des bibliothèques")
        }
    }

    func testDragPayloadValidation() {
        let item = StencilCatalog.item(for: .server)!
        XCTAssertEqual(StencilCatalog.item(fromDragPayload: StencilCatalog.dragPayload(item))?.kind, .server)
        XCTAssertNil(StencilCatalog.item(fromDragPayload: "server"))
        XCTAssertNil(StencilCatalog.item(fromDragPayload: StencilCatalog.dragPrefix + "inconnu"))
        XCTAssertNil(StencilCatalog.item(fromDragPayload: "Un texte glissé depuis une autre application"))
    }

    @MainActor
    func testInsertStencilIsUndoable() {
        let store = DocumentStore()
        store.insertStencil(StencilCatalog.item(for: .resistor)!, centeredAt: CGPoint(x: 100, y: 100))
        XCTAssertEqual(store.doc.shapes.first?.kind, .resistor)
        XCTAssertEqual(store.selection, [store.doc.shapes[0].id])
        store.undo()
        XCTAssertTrue(store.doc.shapes.isEmpty)
    }

    func testStencilShapesSurviveSaveAndLoad() throws {
        let shapes = StencilCatalog.libraries.flatMap(\.items).map {
            StencilCatalog.makeShape($0, in: CGRect(origin: .zero, size: $0.size))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stencils-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        let d = Diagram(shapes: shapes)
        try DiagramIO.save(d, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url).pages, [d])
    }
}

@MainActor
final class TextEditingTests: XCTestCase {
    private func storeWithShape() -> (DocumentStore, UUID) {
        let store = DocumentStore()
        let s = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50), text: "Avant")
        store.perform { $0.shapes = [s] }
        return (store, s.id)
    }

    func testCommitIsOneUndoStep() {
        let (store, id) = storeWithShape()
        store.startTextEditing(id)
        XCTAssertEqual(store.editingText, "Avant")
        store.editingText = "Après\nsur deux lignes"
        store.commitTextEditing()
        XCTAssertNil(store.editingShapeID)
        XCTAssertEqual(store.doc.shape(id)?.text, "Après\nsur deux lignes")
        store.undo()
        XCTAssertEqual(store.doc.shape(id)?.text, "Avant")
    }

    func testCancelKeepsText() {
        let (store, id) = storeWithShape()
        store.startTextEditing(id)
        store.editingText = "Abandonné"
        store.cancelTextEditing()
        store.commitTextEditing()   // sans effet : l'éditeur est fermé
        XCTAssertEqual(store.doc.shape(id)?.text, "Avant")
    }

    func testTextIsTruncatedToLimit() {
        let (store, id) = storeWithShape()
        store.startTextEditing(id)
        store.editingText = String(repeating: "x", count: DiagramIO.maxTextLength + 50)
        store.commitTextEditing()
        XCTAssertEqual(store.doc.shape(id)?.text.count, DiagramIO.maxTextLength)
    }

    func testUndoClosesEditor() {
        let (store, id) = storeWithShape()
        store.startTextEditing(id)
        store.undo()
        XCTAssertNil(store.editingShapeID)
    }
}

@MainActor
final class PathTests: XCTestCase {
    private func storeWithPath(_ kind: ShapeKind, _ a: CGPoint, _ b: CGPoint) -> (DocumentStore, UUID) {
        let store = DocumentStore()
        store.beginTransaction()
        store.insertPath(kind: kind, from: a, to: b)
        store.commitTransaction()
        return (store, store.doc.shapes[0].id)
    }

    func testLineKeepsItsEndpoints() {
        let (store, id) = storeWithPath(.line, CGPoint(x: 100, y: 50), CGPoint(x: 20, y: 90))
        let s = store.doc.shape(id)!
        XCTAssertEqual(s.worldPoints, [CGPoint(x: 100, y: 50), CGPoint(x: 20, y: 90)])
        XCTAssertEqual(s.rect, CGRect(x: 20, y: 50, width: 80, height: 40))
        store.undo()
        XCTAssertTrue(store.doc.shapes.isEmpty)
    }

    func testHorizontalLineHasValidRect() throws {
        let (store, _) = storeWithPath(.line, CGPoint(x: 0, y: 10), CGPoint(x: 100, y: 10))
        XCTAssertGreaterThan(store.doc.shapes[0].rect.height, 0)
        XCTAssertNoThrow(try DiagramIO.validate(store.doc))
    }

    func testHitTestOnLineAndCurve() {
        let (store, id) = storeWithPath(.line, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100))
        XCTAssertEqual(store.hitShape(at: CGPoint(x: 52, y: 50))?.id, id)
        XCTAssertNil(store.hitShape(at: CGPoint(x: 80, y: 20)))
        XCTAssertNil(store.hitShape(at: CGPoint(x: 52, y: 50), includePaths: false))

        let (curveStore, curveID) = storeWithPath(.curve, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        let mid = curveStore.doc.shape(curveID)!.pathMidpoint
        XCTAssertEqual(curveStore.hitShape(at: mid)?.id, curveID)
        XCTAssertNotEqual(mid.y, 0, "la courbe par défaut doit être bombée")
    }

    func testMovingAndRotatingKeepShape() {
        let (store, id) = storeWithPath(.line, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        store.selection = [id]
        store.nudgeSelection(dx: 20, dy: 20)
        XCTAssertEqual(store.doc.shape(id)!.worldPoints, [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 20)])
        store.rotateSelection(by: 90)
        let p = store.doc.shape(id)!.worldPoints
        XCTAssertEqual(store.doc.shape(id)!.rotation, 0)
        // Le trait horizontal devient vertical, de même longueur, autour du centre de la sélection.
        XCTAssertEqual(p[0].x, p[1].x, accuracy: 1e-3)
        XCTAssertEqual(p[1].y - p[0].y, 100, accuracy: 1e-3)
        XCTAssertEqual(p[0].x, 70, accuracy: 1)
    }

    func testPathsSurviveSaveAndCopy() throws {
        let (store, _) = storeWithPath(.curve, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("path-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramIO.save(store.doc, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url).pages, [store.doc])

        store.selection = [store.doc.shapes[0].id]
        XCTAssertTrue(store.insertFragment(store.makeFragment()!, offset: 20))
        XCTAssertEqual(store.doc.shapes.count, 2)
        XCTAssertEqual(store.doc.shapes[1].worldPoints[0], CGPoint(x: 20, y: 20))
    }

    func testValidationRejectsBadPoints() {
        var s = Shape(kind: .line, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        s.points = [CGPoint(x: 0, y: 0)]
        XCTAssertThrowsError(try DiagramIO.validate(Diagram(shapes: [s])))
        s.points = [CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.nan, y: 0)]
        XCTAssertThrowsError(try DiagramIO.validate(Diagram(shapes: [s])))
    }
}

@MainActor
final class LineStyleTests: XCTestCase {
    func testOldFilesGetDefaultStyles() throws {
        let a = UUID(), b = UUID()
        let json = """
        {"version":1,"shapes":[
          {"id":"\(a.uuidString)","kind":"rectangle","rect":[[0,0],[10,10]],"text":"","fill":{"r":1,"g":1,"b":1,"a":1}},
          {"id":"\(b.uuidString)","kind":"line","rect":[[0,0],[10,10]],"text":"","fill":{"r":1,"g":0,"b":0,"a":1},
           "points":[[0,0],[10,10]]}],
         "connectors":[{"id":"\(UUID().uuidString)","fromShape":"\(a.uuidString)","fromPort":1,
                        "toShape":"\(b.uuidString)","toPort":3}]}
        """
        let d = try JSONDecoder().decode(Diagram.self, from: Data(json.utf8))
        XCTAssertNoThrow(try DiagramIO.validate(d))
        XCTAssertEqual(d.shapes[0].line, LineStyle())
        XCTAssertEqual(d.shapes[1].line.color, RGBA(r: 1, g: 0, b: 0, a: 1), "couleur d'un ancien trait reprise de « fill »")
        XCTAssertEqual(d.connectors[0].line.endArrow, .filled)
    }

    func testStyleAppliesToWholeSelectionInOneUndo() {
        let store = DocumentStore()
        let s1 = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let s2 = Shape(kind: .ellipse, rect: CGRect(x: 50, y: 0, width: 10, height: 10))
        let c = Connector(fromShape: s1.id, fromPort: 1, toShape: s2.id, toPort: 3)
        store.perform { $0.shapes = [s1, s2]; $0.connectors = [c] }
        store.selection = [s1.id, s2.id, c.id]
        XCTAssertTrue(store.selectionSupportsArrows)

        store.editSelectionLineStyle(key: "width") { $0.width = 3 }
        store.editSelectionLineStyle(key: "width") { $0.width = 4.5 }   // même réglage : regroupé
        XCTAssertTrue(store.doc.shapes.allSatisfy { $0.line.width == 4.5 })
        XCTAssertEqual(store.doc.connectors[0].line.width, 4.5)
        store.undo()
        XCTAssertTrue(store.doc.shapes.allSatisfy { $0.line.width == 1.5 })
        XCTAssertEqual(store.doc.connectors[0].line.width, LineStyle.connectorDefault.width)
    }

    func testPastedConnectorKeepsStyle() {
        let store = DocumentStore()
        let s1 = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let s2 = Shape(kind: .rectangle, rect: CGRect(x: 50, y: 0, width: 10, height: 10))
        var c = Connector(fromShape: s1.id, fromPort: 1, toShape: s2.id, toPort: 3)
        c.line.dash = .dot
        c.line.beginArrow = .circle
        store.perform { $0.shapes = [s1, s2]; $0.connectors = [c] }
        store.selection = [s1.id, s2.id]
        XCTAssertTrue(store.insertFragment(store.makeFragment()!, offset: 20))
        XCTAssertEqual(store.doc.connectors[1].line, c.line)
        XCTAssertNotEqual(store.doc.connectors[1].id, c.id)
    }

    func testValidationRejectsBadStyle() {
        var s = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        s.line.width = .infinity
        XCTAssertThrowsError(try DiagramIO.validate(Diagram(shapes: [s])))
        s.line.width = 2
        s.line.transparency = 1.5
        XCTAssertThrowsError(try DiagramIO.validate(Diagram(shapes: [s])))
    }

    func testDashPatternScalesWithWidthAndZoom() {
        var l = LineStyle()
        l.width = 2
        l.dash = .dash
        XCTAssertEqual(l.strokeStyle(zoom: 2).dash, [16, 12])
        XCTAssertEqual(l.strokeStyle(zoom: 2).lineWidth, 4)
        l.dash = .solid
        XCTAssertTrue(l.strokeStyle(zoom: 1).dash.isEmpty)
    }
}

@MainActor
final class RevisionTests: XCTestCase {
    private func storeWith(_ n: Int) -> (DocumentStore, [UUID]) {
        let store = DocumentStore()
        let shapes = (0..<n).map { Shape(kind: .rectangle, rect: CGRect(x: CGFloat($0) * 50, y: 0, width: 40, height: 40)) }
        store.perform { $0.shapes = shapes }
        return (store, shapes.map(\.id))
    }

    func testStackingOrder() {
        let (store, ids) = storeWith(4)   // ordre : 0 1 2 3
        store.selection = [ids[1]]
        store.reorderSelection(.front)
        XCTAssertEqual(store.doc.shapes.map(\.id), [ids[0], ids[2], ids[3], ids[1]])
        store.reorderSelection(.back)
        XCTAssertEqual(store.doc.shapes.map(\.id), [ids[1], ids[0], ids[2], ids[3]])
        store.reorderSelection(.forward)
        XCTAssertEqual(store.doc.shapes.map(\.id), [ids[0], ids[1], ids[2], ids[3]])
        store.selection = [ids[1], ids[2]]
        store.reorderSelection(.backward)
        XCTAssertEqual(store.doc.shapes.map(\.id), [ids[1], ids[2], ids[0], ids[3]])
        store.undo()
        XCTAssertEqual(store.doc.shapes.map(\.id), [ids[0], ids[1], ids[2], ids[3]])
    }

    func testReverseAndReconnect() {
        let (store, ids) = storeWith(3)
        let c = Connector(fromShape: ids[0], fromPort: 1, toShape: ids[1], toPort: 3)
        store.perform { $0.connectors = [c] }
        store.selection = [c.id]
        store.reverseSelectedConnectors()
        XCTAssertEqual(store.doc.connectors[0].fromShape, ids[1])
        XCTAssertEqual(store.doc.connectors[0].toShape, ids[0])

        store.beginTransaction()
        XCTAssertTrue(store.reconnect(connector: c.id, start: false, to: ids[2], port: 2))
        XCTAssertFalse(store.reconnect(connector: c.id, start: false, to: ids[1], port: 0), "boucle refusée")
        store.commitTransaction()
        XCTAssertEqual(store.doc.connectors[0].toShape, ids[2])
        XCTAssertEqual(store.doc.connectors[0].toPort, 2)
        store.undo()
        XCTAssertEqual(store.doc.connectors[0].toShape, ids[0])
    }

    func testTextAndFillStyleOnSelection() {
        let (store, ids) = storeWith(2)
        store.selection = Set(ids)
        store.editSelectionTextStyle(key: "size") { $0.size = 24 }
        store.editSelectionTextStyle(key: "bold") { $0.bold = true }
        store.editSelection(key: "noFill", shapes: { $0.noFill = true })
        XCTAssertTrue(store.doc.shapes.allSatisfy { $0.textStyle.size == 24 && $0.textStyle.bold && $0.noFill })
        XCTAssertNil(store.doc.shapes[0].fillColor)
        store.undo()   // annule seulement « noFill »
        XCTAssertTrue(store.doc.shapes.allSatisfy { !$0.noFill && $0.textStyle.bold })
    }

    func testNewAttributesSurviveSaveAndValidation() throws {
        var s = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 10, height: 10), text: "A")
        s.textStyle = TextStyle(size: 20, color: RGBA(r: 1, g: 0, b: 0, a: 1), bold: true, italic: true, alignment: .right)
        s.fillTransparency = 0.4
        let d = Diagram(shapes: [s])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rev-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramIO.save(d, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url).pages, [d])

        var bad = s
        bad.textStyle.size = 0
        XCTAssertThrowsError(try DiagramIO.validate(Diagram(shapes: [bad])))
        bad = s
        bad.fillTransparency = 2
        XCTAssertThrowsError(try DiagramIO.validate(Diagram(shapes: [bad])))
    }

    func testToolShortcutsAreUnique() {
        XCTAssertEqual(Set(Tool.allCases.map(\.shortcut)).count, Tool.allCases.count)
        let store = DocumentStore()
        store.tool = .ellipse
        store.tool = .select
        XCTAssertEqual(store.lastDrawingTool, .ellipse)
    }
}

@MainActor
final class PagesLayersGroupsTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat = 0) -> Shape {
        Shape(kind: .rectangle, rect: CGRect(x: x, y: y, width: 40, height: 40))
    }

    func testPagesAreIndependentAndUndoable() {
        let store = DocumentStore()
        store.perform { $0.shapes = [self.rect(0)] }
        store.addPage()
        XCTAssertEqual(store.pageCount, 2)
        XCTAssertEqual(store.currentPage, 1)
        XCTAssertTrue(store.doc.shapes.isEmpty, "nouvelle page vide")
        XCTAssertEqual(store.doc.name, "Page 2")
        store.renamePage(1, to: "  Réseau  ")
        XCTAssertEqual(store.doc.name, "Réseau")
        store.selectPage(0)
        XCTAssertEqual(store.doc.shapes.count, 1)
        store.deletePage(1)
        XCTAssertEqual(store.pageCount, 1)
        store.undo()
        XCTAssertEqual(store.pageCount, 2)
        XCTAssertEqual(store.document.pages[1].name, "Réseau")
        store.deletePage(0)
        store.deletePage(0)   // la dernière page ne peut pas être supprimée
        XCTAssertEqual(store.pageCount, 1)
    }

    func testDuplicatePageGetsNewIdentifiers() {
        let store = DocumentStore()
        var a = rect(0), b = rect(100)
        let g = UUID()
        a.groupID = g; b.groupID = g
        store.perform { $0.shapes = [a, b]; $0.connectors = [Connector(fromShape: a.id, fromPort: 1, toShape: b.id, toPort: 3)] }
        store.addLayer()
        store.duplicatePage(0)
        let copy = store.document.pages[1]
        XCTAssertNotEqual(copy.id, store.document.pages[0].id)
        XCTAssertTrue(Set(copy.shapes.map(\.id)).isDisjoint(with: [a.id, b.id]))
        XCTAssertEqual(Set(copy.shapes.compactMap(\.groupID)).count, 1)
        XCTAssertNotEqual(copy.shapes[0].groupID, g)
        XCTAssertEqual(copy.connectors[0].fromShape, copy.shapes[0].id)
        XCTAssertNotEqual(copy.layers[0].id, store.document.pages[0].layers[0].id)
        XCTAssertNoThrow(try DiagramIO.validate(store.document))
    }

    func testLayersVisibilityLockAndPrint() {
        let store = DocumentStore()
        store.addLayer()
        let layer = store.doc.activeLayerID!
        store.beginTransaction()
        store.insertShape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 40, height: 40))
        store.commitTransaction()
        let id = store.doc.shapes[0].id
        XCTAssertEqual(store.doc.shapes[0].layerID, layer, "nouvelle forme sur le calque actif")
        XCTAssertEqual(store.hitShape(at: CGPoint(x: 20, y: 20))?.id, id)

        store.selection = [id]
        store.updateLayer(layer, key: "locked") { $0.locked = true }
        XCTAssertNil(store.hitShape(at: CGPoint(x: 20, y: 20)), "calque verrouillé : non sélectionnable")
        XCTAssertTrue(store.selection.isEmpty)
        store.updateLayer(layer, key: "locked") { $0.locked = false }

        store.updateLayer(layer, key: "visible") { $0.visible = false }
        store.selectAll()
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertFalse(store.doc.isPrintable(store.doc.shapes[0]))
        store.updateLayer(layer, key: "visible") { $0.visible = true }
        store.updateLayer(layer, key: "printable") { $0.printable = false }
        XCTAssertNil(DiagramExporter.contentBounds(store.doc), "calque non imprimable : rien à exporter")

        store.deleteLayer(layer)
        XCTAssertEqual(store.doc.shapes.count, 1, "les formes du calque supprimé sont conservées")
        XCTAssertNil(store.doc.shapes[0].layerID)
    }

    func testGroupSelectionAndPaste() {
        let store = DocumentStore()
        let a = rect(0), b = rect(100), c = rect(200)
        store.perform { $0.shapes = [a, b, c] }
        store.selection = [a.id, b.id]
        store.groupSelection()
        XCTAssertEqual(store.expandedToGroups([a.id]), [a.id, b.id])
        XCTAssertEqual(store.selectedGroupBounds.count, 1)

        XCTAssertTrue(store.insertFragment(store.makeFragment()!, offset: 20))
        let pasted = store.doc.shapes.suffix(2)
        XCTAssertEqual(Set(pasted.compactMap(\.groupID)).count, 1)
        XCTAssertNotEqual(pasted.first?.groupID, store.doc.shapes[0].groupID, "le collage forme un nouveau groupe")

        store.selection = [a.id, b.id]
        store.ungroupSelection()
        XCTAssertNil(store.doc.shape(a.id)?.groupID)
        XCTAssertEqual(store.expandedToGroups([a.id]), [a.id])
    }

    func testAlignmentSnap() {
        let target = CGRect(x: 100, y: 100, width: 50, height: 50)
        // Bord gauche à 3 unités du bord gauche de la cible ; centre (118) et bord droit (133)
        // trop loin des autres repères (125, 150) : un seul alignement possible.
        let snap = alignmentSnap(moving: CGRect(x: 103, y: 300, width: 30, height: 20),
                                 targets: [target], tolerance: 6)
        XCTAssertEqual(snap.dx, -3)
        XCTAssertNil(snap.dy)
        XCTAssertEqual(snap.guides.count, 1)
        XCTAssertEqual(snap.guides[0].position, 100)
        XCTAssertTrue(snap.guides[0].vertical)

        let centre = alignmentSnap(moving: CGRect(origin: CGPoint(x: 400, y: 127), size: .zero),
                                   targets: [target], tolerance: 6)
        XCTAssertEqual(centre.dy, -2)
        // Deux alignements possibles : le plus proche l'emporte (bord droit 123 → centre 125).
        XCTAssertEqual(alignmentSnap(moving: CGRect(x: 103, y: 300, width: 20, height: 20),
                                     targets: [target], tolerance: 6).dx, 2)
        XCTAssertNil(alignmentSnap(moving: CGRect(x: 500, y: 500, width: 10, height: 10),
                                   targets: [target], tolerance: 6).dx)
    }

    func testFileFormatV1AndV2() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = rect(0)
        let v1 = """
        {"version":1,"shapes":[{"id":"\(a.id.uuidString)","kind":"rectangle","rect":[[0,0],[40,40]]}],"connectors":[]}
        """
        try Data(v1.utf8).write(to: url)
        let doc = try DiagramIO.load(from: url)
        XCTAssertEqual(doc.pages.count, 1)
        XCTAssertEqual(doc.pages[0].shapes.first?.id, a.id)

        var two = CADDocument(pages: [Diagram(name: "A"), Diagram(name: "B")])
        two.pages[1].shapes = [a]
        try DiagramIO.save(two, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url), two)

        two.pages[1].shapes[0].layerID = UUID()
        XCTAssertThrowsError(try DiagramIO.validate(two), "calque inconnu refusé")
        two.pages[1].shapes[0].layerID = nil
        two.pages[1].id = two.pages[0].id
        XCTAssertThrowsError(try DiagramIO.validate(two), "pages en double refusées")
    }

    func testExportProducesFiles() throws {
        let store = DocumentStore()
        store.perform { $0.shapes = [self.rect(0), self.rect(100, 60)] }
        store.addPage()
        let png = try DiagramExporter.pngData(store.document.pages[0])
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "signature PNG")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramExporter.writePDF(store.document, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
        let size = (DiagramExporter.contentBounds(store.document.pages[0])?.size)!
        XCTAssertEqual(size, CGSize(width: 140, height: 100))
    }
}

@MainActor
final class CADFeaturesTests: XCTestCase {
    func testUnitsAndScale() {
        var d = Diagram()
        XCTAssertEqual(d.measure(72), 25.4, accuracy: 1e-9, "72 pt = 25,4 mm")
        XCTAssertEqual(d.formatLength(72), "25,4 mm")
        d.scale = 100
        d.unit = .m
        d.precision = 2
        XCTAssertEqual(d.formatLength(72), "2,54 m", "échelle 1:100")
        XCTAssertEqual(d.worldLength(forMeasure: 2.54), 72, accuracy: 1e-6)
    }

    func testDimensionGeometryAndEditing() {
        let store = DocumentStore()
        store.beginTransaction()
        store.insertPath(kind: .dimension, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 144, y: 0))
        store.commitTransaction()
        let s = store.doc.shapes[0]
        let g = s.dimension!
        XCTAssertEqual(g.length, 144, accuracy: 1e-9)
        XCTAssertEqual(g.offset, 24, accuracy: 1e-9)
        XCTAssertEqual(g.a2.y, -24, accuracy: 1e-9, "ligne de cote au-dessus")
        XCTAssertEqual(store.doc.formatLength(g.length), "50,8 mm")
        let moved = s.dimensionPoints(moving: 1, to: CGPoint(x: 72, y: 0))
        XCTAssertEqual(dimensionGeometry(moved[0], moved[1], moved[2]).offset, 24, accuracy: 1e-9, "le décalage est conservé")
        XCTAssertNotNil(store.hitShape(at: CGPoint(x: 70, y: -24)))
        XCTAssertNoThrow(try DiagramIO.validate(store.doc))
    }

    func testOrthogonalRouteAvoidsObstacle() {
        let a = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 40, height: 40))
        let b = Shape(kind: .rectangle, rect: CGRect(x: 300, y: 0, width: 40, height: 40))
        let wall = Shape(kind: .rectangle, rect: CGRect(x: 150, y: -30, width: 40, height: 100))
        let c = Connector(fromShape: a.id, fromPort: 1, toShape: b.id, toPort: 3)
        let d = Diagram(shapes: [a, b, wall], connectors: [c])
        let route = d.connectorPoints(c)!
        XCTAssertEqual(route.first, CGPoint(x: 40, y: 20))
        XCTAssertEqual(route.last, CGPoint(x: 300, y: 20))
        for i in 0..<(route.count - 1) {
            let p = route[i], q = route[i + 1]
            XCTAssertTrue(p.x == q.x || p.y == q.y, "segment orthogonal")
            for k in 0...20 {
                let t = CGFloat(k) / 20
                let m = CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
                XCTAssertFalse(wall.rect.insetBy(dx: 1, dy: 1).contains(m), "le tracé traverse l'obstacle en \(m)")
            }
        }
        var straight = c
        straight.routing = .straight
        XCTAssertEqual(d.connectorPoints(straight)!, [CGPoint(x: 40, y: 20), CGPoint(x: 300, y: 20)])
        var curved = c
        curved.routing = .curved
        let pts = d.connectorPoints(curved)!
        XCTAssertEqual(pts.first, CGPoint(x: 40, y: 20))
        XCTAssertEqual(pts.last!.x, 300, accuracy: 1e-9)
    }

    func testRulerGuidesSnap() {
        let snap = alignmentSnap(moving: CGRect(x: 97, y: 0, width: 20, height: 20), targets: [],
                                 tolerance: 6, verticalLines: [100])
        XCTAssertEqual(snap.dx, 3)
        let store = DocumentStore()
        store.addGuide(GuideLine(vertical: true, position: 100))
        XCTAssertEqual(store.doc.guides.count, 1)
        store.undo()
        XCTAssertTrue(store.doc.guides.isEmpty)
        var bad = Diagram()
        bad.guides = [GuideLine(vertical: false, position: .nan)]
        XCTAssertThrowsError(try DiagramIO.validate(bad))
        bad = Diagram()
        bad.scale = 0
        XCTAssertThrowsError(try DiagramIO.validate(bad))
    }

    func testSVGPathParser() {
        let p = SVGPathParser.parse("M10 10 h20 v20 H10 z m40 0 a10 10 0 1 0 20 0 a10 10 0 1 0 -20 0")!
        let box = p.cgPath.boundingBoxOfPath
        XCTAssertEqual(box.minX, 10, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 70, accuracy: 0.01)
        XCTAssertEqual(SVGPathParser.numbers("1.5.5-2e1,3"), [1.5, 0.5, -20, 3])
        XCTAssertNil(SVGPathParser.parse("n'importe quoi"))
    }

    func testSVGImport() throws {
        let svg = """
        <?xml version="1.0"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="200pt" height="100pt" viewBox="0 0 400 200">
          <defs><rect id="cache" width="5" height="5"/></defs>
          <rect x="0" y="0" width="100" height="50" fill="#ff0000" stroke="black" stroke-width="2"/>
          <g transform="translate(200 0)">
            <circle cx="50" cy="50" r="25" style="fill:none;stroke:#0000ff"/>
            <line x1="0" y1="100" x2="100" y2="100" stroke="green"/>
            <path d="M0 150 L50 190 L100 150 Z" fill="rgb(0,128,0)"/>
          </g>
          <text x="10" y="180" font-size="20" font-weight="bold">Bonjour</text>
        </svg>
        """
        let shapes = try SVGImporter.shapes(from: Data(svg.utf8))
        XCTAssertEqual(shapes.map(\.kind), [.rectangle, .ellipse, .line, .freeform, .text])
        // viewBox 400 → 200 pt : échelle 0,5.
        XCTAssertEqual(shapes[0].rect, CGRect(x: 0, y: 0, width: 50, height: 25))
        XCTAssertEqual(shapes[0].fill, RGBA(r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(shapes[0].line.width, 1, accuracy: 1e-9)
        XCTAssertEqual(shapes[1].rect, CGRect(x: 112.5, y: 12.5, width: 25, height: 25))
        XCTAssertTrue(shapes[1].noFill)
        XCTAssertEqual(shapes[4].text, "Bonjour")
        XCTAssertTrue(shapes[4].textStyle.bold)

        // Entité externe : jamais résolue (pas de lecture de fichier local).
        let xxe = """
        <?xml version="1.0"?>
        <!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <svg xmlns="http://www.w3.org/2000/svg"><text x="0" y="20">A&xxe;</text><rect width="5" height="5"/></svg>
        """
        let parsed = (try? SVGImporter.shapes(from: Data(xxe.utf8))) ?? []
        XCTAssertFalse(parsed.contains { $0.text.contains("root") })

        let store = DocumentStore()
        try store.importSVG(data: Data(svg.utf8))
        XCTAssertEqual(store.doc.shapes.count, 5)
        XCTAssertEqual(Set(store.doc.shapes.compactMap(\.groupID)).count, 1, "import regroupé")
        store.undo()
        XCTAssertTrue(store.doc.shapes.isEmpty)

        XCTAssertThrowsError(try SVGImporter.shapes(from: Data("<html></html>".utf8)))
    }

    func testSVGExportRoundTrip() throws {
        var d = Diagram()
        var r = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50), text: "A & B")
        r.fill = RGBA(r: 0, g: 0, b: 1, a: 1)
        let e = Shape(kind: .ellipse, rect: CGRect(x: 200, y: 0, width: 60, height: 60))
        d.shapes = [r, e]
        d.connectors = [Connector(fromShape: r.id, fromPort: 1, toShape: e.id, toPort: 3)]
        let svg = SVGExporter.svg(for: d)
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("A &amp; B"))
        XCTAssertTrue(svg.contains("#0000ff"))
        let back = try SVGImporter.shapes(from: Data(svg.utf8))
        XCTAssertGreaterThanOrEqual(back.count, 4, "fond, rectangle, ellipse, connecteur et texte relus")
        XCTAssertTrue(back.contains { $0.kind == .text && $0.text == "A & B" })
    }
}

// MARK: - Performance et régressions de la révision

@MainActor
final class PerformanceTests: XCTestCase {
    /// Grille de formes reliées en chaîne : de quoi mesurer le routage et les tests de clic.
    private func bigDiagram(columns: Int = 20, rows: Int = 15) -> Diagram {
        var d = Diagram()
        for r in 0..<rows {
            for c in 0..<columns {
                d.shapes.append(Shape(kind: .rectangle,
                                      rect: CGRect(x: CGFloat(c) * 120, y: CGFloat(r) * 100, width: 60, height: 40)))
            }
        }
        for i in 1..<d.shapes.count {
            d.connectors.append(Connector(fromShape: d.shapes[i - 1].id, fromPort: 1, toShape: d.shapes[i].id, toPort: 3))
        }
        return d
    }

    private func seconds(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    func testRoutingAllConnectorsIsFast() {
        let d = bigDiagram()   // 300 formes, 299 connecteurs
        let context = RoutingContext(d)
        let first = seconds { for c in d.connectors { _ = d.connectorPoints(c, context: context) } }
        let cached = seconds { for c in d.connectors { _ = d.connectorPoints(c, context: context) } }
        XCTAssertLessThan(first, 3.0, "routage initial trop lent : \(first) s")
        XCTAssertLessThan(cached, 0.2, "routage en cache trop lent : \(cached) s")
    }

    func testHitTestingIsFast() {
        let store = DocumentStore()
        store.perform { $0 = self.bigDiagram() }
        let t = seconds {
            for i in 0..<50 { _ = store.hitShape(at: CGPoint(x: CGFloat(i) * 37, y: CGFloat(i) * 23)) }
            _ = store.hitConnector(at: CGPoint(x: 90, y: 20))
        }
        XCTAssertLessThan(t, 1.0, "tests de clic trop lents : \(t) s")
    }

    func testOffScreenShapesAreCulled() {
        let d = bigDiagram()
        let painter = DiagramPainter(diagram: d, zoom: 1, offset: .zero, viewport: CGRect(x: 0, y: 0, width: 400, height: 300))
        let onScreen = d.shapes.filter { painter.isOnScreen($0) }.count
        XCTAssertLessThan(onScreen, d.shapes.count / 3, "les formes hors champ doivent être ignorées")
        XCTAssertTrue(painter.labelledShapes.isEmpty, "aucune vue de libellé pour des formes sans texte")
    }
}

@MainActor
final class RevisionTwoTests: XCTestCase {
    func testMarqueeSelectsInnerConnectors() {
        let store = DocumentStore()
        let a = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 40, height: 40))
        let b = Shape(kind: .rectangle, rect: CGRect(x: 100, y: 0, width: 40, height: 40))
        let far = Shape(kind: .rectangle, rect: CGRect(x: 1000, y: 0, width: 40, height: 40))
        let inner = Connector(fromShape: a.id, fromPort: 1, toShape: b.id, toPort: 3)
        let outer = Connector(fromShape: b.id, fromPort: 1, toShape: far.id, toPort: 3)
        store.perform { $0.shapes = [a, b, far]; $0.connectors = [inner, outer] }
        store.selectInRect(CGRect(x: -10, y: -10, width: 200, height: 100), additive: false)
        XCTAssertEqual(store.selection, [a.id, b.id, inner.id])
    }

    func testOptionDragDuplicatesInOneUndoStep() {
        let store = DocumentStore()
        let a = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 40, height: 40))
        let b = Shape(kind: .rectangle, rect: CGRect(x: 100, y: 0, width: 40, height: 40))
        store.perform { $0.shapes = [a, b] }
        store.selection = [a.id, b.id]
        store.beginTransaction()
        let copy = store.duplicateForDrag(primary: b.id)
        XCTAssertNotNil(copy)
        XCTAssertEqual(store.doc.shapes.count, 4)
        XCTAssertEqual(store.doc.shape(copy!)?.rect, b.rect, "copie de b à la même place")
        XCTAssertFalse(store.selection.contains(a.id), "les copies sont sélectionnées")
        store.commitTransaction()
        store.undo()
        XCTAssertEqual(store.doc.shapes.count, 2, "une seule annulation")
    }

    func testFreeformHitTestFollowsPath() {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 100, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 100))
        p.closeSubpath()   // triangle : le coin bas-droit de la boîte englobante est vide
        let s = Shape.freeform(from: p)!
        XCTAssertTrue(s.contains(CGPoint(x: 20, y: 20)))
        XCTAssertFalse(s.contains(CGPoint(x: 90, y: 90)))
        var open = s
        open.noFill = true
        XCTAssertFalse(open.contains(CGPoint(x: 20, y: 20)), "sans remplissage : seul le trait est cliquable")
        XCTAssertTrue(open.contains(CGPoint(x: 50, y: 1)))
    }

    func testZoomHundredKeepsCentre() {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 800, height: 600)
        store.offset = CGSize(width: -500, height: -300)
        store.zoom = 2
        let centre = store.toWorld(CGPoint(x: 400, y: 300))
        store.setZoom(1)
        XCTAssertEqual(store.zoom, 1)
        let after = store.toWorld(CGPoint(x: 400, y: 300))
        XCTAssertEqual(after.x, centre.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, centre.y, accuracy: 1e-6)
    }
}

@MainActor
final class TextBlockTests: XCTestCase {
    func testDefaultFrameAndOffset() {
        var s = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 120, height: 60), text: "Bonjour")
        var f = s.textFrame(content: s.text)
        XCTAssertEqual(f.anchor, CGPoint(x: 60, y: 30), "par défaut : centre de la forme")
        XCTAssertEqual(f.local.width, 112, "largeur automatique : forme moins 8")
        s.textOffset = CGPoint(x: 100, y: -50)
        s.textBlockWidth = 200
        f = s.textFrame(content: s.text)
        XCTAssertEqual(f.anchor, CGPoint(x: 160, y: -20))
        XCTAssertEqual(f.local.width, 200)
        XCTAssertTrue(s.hasCustomTextBlock)
    }

    func testOffsetFollowsRotation() {
        var s = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 40), text: "A", rotation: 90)
        s.textOffset = CGPoint(x: 30, y: 0)   // à droite dans le repère de la forme
        let a = s.textFrame(content: "A").anchor
        XCTAssertEqual(a.x, 50, accuracy: 1e-6)
        XCTAssertEqual(a.y, 50, accuracy: 1e-6, "pivotée de 90° : la droite de la forme est vers le bas")
    }

    func testClickOnMovedTextSelectsShape() {
        let store = DocumentStore()
        var s = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 120, height: 60), text: "Étiquette")
        s.textOffset = CGPoint(x: 300, y: 0)
        store.perform { $0.shapes = [s] }
        XCTAssertEqual(store.hitShape(at: CGPoint(x: 360, y: 30))?.id, s.id, "clic sur le texte déplacé")
        XCTAssertNil(store.hitShape(at: CGPoint(x: 360, y: 200)))
        store.selection = [s.id]
        store.resetTextBlocks()
        XCTAssertFalse(store.doc.shapes[0].hasCustomTextBlock)
        store.undo()
        XCTAssertEqual(store.doc.shapes[0].textOffset, CGPoint(x: 300, y: 0))
    }

    func testTextBlockPersistenceAndValidation() throws {
        var s = Shape(kind: .ellipse, rect: CGRect(x: 0, y: 0, width: 50, height: 50), text: "X")
        s.textOffset = CGPoint(x: 12.5, y: -40)
        s.textBlockWidth = 150
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tb-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramIO.save(Diagram(shapes: [s]), to: url)
        XCTAssertEqual(try DiagramIO.load(from: url).pages[0].shapes[0], s)
        var bad = s
        bad.textBlockWidth = 0
        XCTAssertThrowsError(try DiagramIO.validate(Diagram(shapes: [bad])))
        bad = s
        bad.textOffset = CGPoint(x: CGFloat.nan, y: 0)
        XCTAssertThrowsError(try DiagramIO.validate(Diagram(shapes: [bad])))
    }

    func testExportIncludesMovedText() {
        var s = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50), text: "Loin")
        s.textOffset = CGPoint(x: 0, y: 200)
        let bounds = DiagramExporter.contentBounds(Diagram(shapes: [s]))!
        XCTAssertGreaterThan(bounds.maxY, 220, "le texte déplacé est dans la zone exportée")
        XCTAssertTrue(SVGExporter.svg(for: Diagram(shapes: [s])).contains("Loin"))
    }
}

@MainActor
final class DimensionTests: XCTestCase {
    private func points(_ s: Shape) -> [CGPoint] { s.worldPoints }

    /// Page avec un rectangle (0, 0, 100 × 50) et une cote horizontale collée à ses coins supérieurs,
    /// ligne de cote 20 au-dessus.
    private func gluedStore() -> (DocumentStore, rect: UUID, dim: UUID) {
        let store = DocumentStore()
        let rect = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        var dim = Shape(kind: .dimensionHorizontal, rect: .zero, line: .dimensionDefault)
        dim.setWorldPoints([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: -20)])
        dim.glue = [GluePoint(point: 0, shape: rect.id, anchor: 0), GluePoint(point: 1, shape: rect.id, anchor: 1)]
        store.perform { $0.shapes = [rect, dim] }
        return (store, rect.id, dim.id)
    }

    func testLayoutsAndMeasures() {
        var d = Diagram()
        var h = Shape(kind: .dimensionHorizontal, rect: .zero)
        h.setWorldPoints([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 50, y: -20)])
        XCTAssertEqual(h.dimensionLayout!.value, 100, accuracy: 1e-9)
        XCTAssertEqual(h.dimensionLayout!.line, [CGPoint(x: 0, y: -20), CGPoint(x: 100, y: -20)])
        var v = Shape(kind: .dimensionVertical, rect: .zero)
        v.setWorldPoints([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: -20, y: 25)])
        XCTAssertEqual(v.dimensionLayout!.value, 50, accuracy: 1e-9)
        XCTAssertEqual(v.dimensionLayout!.labelAngle, -.pi / 2, accuracy: 1e-9, "texte vertical lu de bas en haut")
        var a = Shape(kind: .angularDimension, rect: .zero)
        a.setWorldPoints(normalizedDimensionPoints(kind: .angularDimension,
            [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: -100), CGPoint(x: 40, y: 0)]))
        XCTAssertEqual(a.dimensionLayout!.value, 90, accuracy: 1e-9)
        XCTAssertEqual(a.worldPoints[3].distance(to: .zero), 40, accuracy: 1e-9, "rayon de l'arc conservé")
        XCTAssertEqual(d.dimensionMeasure(a), "90,0°")
        var r = Shape(kind: .radiusDimension, rect: .zero)
        r.setWorldPoints([CGPoint(x: 0, y: 0), CGPoint(x: 72, y: 0)])
        XCTAssertEqual(d.dimensionMeasure(r), "R 25,4 mm")
        var dia = Shape(kind: .diameterDimension, rect: .zero)
        dia.setWorldPoints([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 36)])
        XCTAssertEqual(d.dimensionMeasure(dia), "Ø 25,4 mm")
        XCTAssertEqual(dia.dimensionLayout!.line.first!.y, -36, accuracy: 1e-9, "le diamètre traverse le cercle")
        d.shapes = [h, v, a, r, dia]
        XCTAssertNoThrow(try DiagramIO.validate(d))
        let svg = SVGExporter.svg(for: d)
        XCTAssertTrue(svg.contains("R 25,4 mm") && svg.contains("90,0°"))
    }

    func testGluedDimensionFollowsMoveAndResize() {
        let (store, rectID, dimID) = gluedStore()
        func dim() -> Shape { store.doc.shape(dimID)! }
        store.perform { d in
            let i = d.shapes.firstIndex { $0.id == rectID }!
            d.shapes[i].rect.origin.x += 30
        }
        XCTAssertEqual(points(dim())[0].x, 30, accuracy: 1e-9)
        XCTAssertEqual(points(dim())[2].y, -20, accuracy: 1e-9)
        store.perform { d in
            let i = d.shapes.firstIndex { $0.id == rectID }!
            d.shapes[i].rect.size.width = 150
            d.shapes[i].rect.origin.y += 10
        }
        XCTAssertEqual(dim().dimensionLayout!.value, 150, accuracy: 1e-9, "la mesure suit le redimensionnement")
        XCTAssertEqual(points(dim())[2].y, -10, accuracy: 1e-9, "la ligne de cote garde son écart")
        XCTAssertEqual(dim().glue.count, 2)
        store.undo()
        XCTAssertEqual(dim().dimensionLayout!.value, 100, accuracy: 1e-9)
    }

    func testRotatedTargetAndAlignedDimension() {
        let store = DocumentStore()
        let rect = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 40))
        var dim = Shape(kind: .dimension, rect: .zero, line: .dimensionDefault)
        dim.setWorldPoints(makeDimensionPoints(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), offset: 15))
        dim.glue = [GluePoint(point: 0, shape: rect.id, anchor: 0), GluePoint(point: 1, shape: rect.id, anchor: 1)]
        store.perform { $0.shapes = [rect, dim] }
        store.perform { $0.shapes[0].rotation = 30 }
        let g = store.doc.shapes[1].dimension!
        XCTAssertEqual(g.length, 100, accuracy: 1e-6, "la longueur du côté pivoté reste 100")
        XCTAssertEqual(g.offset, 15, accuracy: 1e-6)
    }

    func testMovingDimensionAloneUnglues() {
        let (store, _, dimID) = gluedStore()
        store.selection = [dimID]
        store.nudgeSelection(dx: 0, dy: 5)
        let d = store.doc.shape(dimID)!
        XCTAssertTrue(d.glue.isEmpty, "une cote déplacée seule est décollée")
        XCTAssertEqual(points(d)[0].y, 5, accuracy: 1e-9)
    }

    func testMovingBothKeepsGlue() {
        let (store, rectID, dimID) = gluedStore()
        store.selection = [rectID, dimID]
        store.nudgeSelection(dx: 7, dy: 3)
        XCTAssertEqual(store.doc.shape(dimID)!.glue.count, 2)
        XCTAssertEqual(points(store.doc.shape(dimID)!)[1], CGPoint(x: 107, y: 3))
    }

    func testDeletingTargetUnglues() {
        let (store, rectID, dimID) = gluedStore()
        store.selection = [rectID]
        store.deleteSelection()
        XCTAssertTrue(store.doc.shape(dimID)!.glue.isEmpty)
        XCTAssertNoThrow(try DiagramIO.validate(store.doc))
    }

    func testDuplicateRemapsGlue() {
        let (store, rectID, dimID) = gluedStore()
        store.selection = [rectID, dimID]
        store.duplicateSelection()
        let copies = store.selectedShapes
        let newRect = copies.first { $0.kind == .rectangle }!
        let newDim = copies.first { $0.kind == .dimensionHorizontal }!
        XCTAssertEqual(Set(newDim.glue.map(\.shape)), [newRect.id], "la copie est collée à la copie de la forme")
        store.selection = [dimID]
        store.duplicateSelection()
        XCTAssertTrue(store.selectedShapes[0].glue.isEmpty, "copie seule : décollée")
    }

    func testDrawingDimensionBetweenCornersGlues() {
        let store = DocumentStore()
        store.perform { $0.shapes = [Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50))] }
        store.beginTransaction()
        store.insertPath(kind: .dimension, from: CGPoint(x: 2, y: 1), to: CGPoint(x: 99, y: 0))
        store.commitTransaction()
        let dim = store.doc.shapes[1]
        XCTAssertEqual(dim.glue.count, 2)
        XCTAssertEqual(dim.dimension!.length, 100, accuracy: 1e-9)
    }

    func testEditingHandles() {
        var a = Shape(kind: .angularDimension, rect: .zero)
        a.setWorldPoints(initialDimensionPoints(kind: .angularDimension, in: CGRect(x: 0, y: 0, width: 100, height: 80)))
        let r = a.worldPoints[0].distance(to: a.worldPoints[3])
        let moved = a.dimensionPoints(moving: 1, to: CGPoint(x: 0, y: 200))
        XCTAssertEqual(moved[0].distance(to: moved[3]), r, accuracy: 1e-9, "déplacer une branche garde le rayon de l'arc")
        var h = Shape(kind: .dimensionHorizontal, rect: .zero)
        h.setWorldPoints([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: -20)])
        let p = h.dimensionPoints(moving: 1, to: CGPoint(x: 60, y: 30))
        XCTAssertEqual(p[2], CGPoint(x: 30, y: -20), "la ligne de cote reste en place, poignée au milieu")
    }

    func testGluePersistenceAndValidation() throws {
        let (store, rectID, _) = gluedStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glue-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramIO.save(store.doc, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url).pages[0], store.doc)

        var bad = store.doc
        bad.shapes[1].glue.append(GluePoint(point: 2, shape: rectID, anchor: 0))
        XCTAssertThrowsError(try DiagramIO.validate(bad), "la poignée de la ligne de cote ne se colle pas")
        bad = store.doc
        bad.shapes[1].glue[0].anchor = 99
        XCTAssertThrowsError(try DiagramIO.validate(bad))
        bad = store.doc
        bad.shapes[0].glue = [GluePoint(point: 0, shape: rectID, anchor: 0)]
        XCTAssertThrowsError(try DiagramIO.validate(bad), "seules les cotes se collent")

        // Forme cible absente du fichier : la cote se charge, décollée.
        var orphan = store.doc
        orphan.shapes.removeFirst()
        try DiagramIO.save(orphan, to: url)
        XCTAssertTrue(try DiagramIO.load(from: url).pages[0].shapes[0].glue.isEmpty)
    }

    func testDimensionStencils() {
        let library = StencilCatalog.libraries.first { $0.id == "dimensions" }!
        XCTAssertEqual(library.name, "Cotation")
        XCTAssertEqual(library.items.count, 12)
        let store = DocumentStore()
        for item in library.items {
            store.insertStencil(item, centeredAt: CGPoint(x: 200, y: 200))
            XCTAssertEqual(StencilCatalog.item(fromDragPayload: StencilCatalog.dragPayload(item))?.id, item.id)
        }
        XCTAssertEqual(store.doc.shapes.count, 12)
        XCTAssertTrue(store.doc.shapes.allSatisfy { $0.dimensionLayout != nil })
        XCTAssertNoThrow(try DiagramIO.validate(store.doc))
        let ticks = store.doc.shapes.filter { $0.line.endArrow == .tick }
        XCTAssertEqual(ticks.count, 6, "une variante architecture par type")
        let tick = arrowHead(.tick, tip: .zero, from: CGPoint(x: -10, y: 0), size: 8)!
        XCTAssertFalse(tick.filled)
        XCTAssertEqual(tick.path.boundingRect.width, 8 * 0.5.squareRoot(), accuracy: 1e-6, "trait à 45°")
    }
}

@MainActor
final class ShapeOperationTests: XCTestCase {
    /// Page contenant les formes, sélectionnées dans l'ordre donné.
    private func store(_ shapes: [Shape]) -> DocumentStore {
        let store = DocumentStore()
        store.perform { $0.shapes = shapes }
        for s in shapes { store.selection.insert(s.id) }
        return store
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Shape {
        Shape(kind: .rectangle, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    private func line(_ a: CGPoint, _ b: CGPoint) -> Shape {
        var s = Shape(kind: .line, rect: .zero)
        s.setWorldPoints([a, b])
        return s
    }

    private func assertRect(_ r: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, expected.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(r.minY, expected.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(r.width, expected.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(r.height, expected.height, accuracy: 0.01, file: file, line: line)
    }

    func testUnionIsUndoableAndKeepsPrimaryFormat() throws {
        var a = rect(0, 0, 100, 100)
        a.fill = RGBA(r: 1, g: 0, b: 0, a: 1)
        a.text = "A"
        let s = store([a, rect(50, 0, 100, 100)])
        try s.applyOperation(.union)
        XCTAssertEqual(s.doc.shapes.count, 1)
        let u = s.doc.shapes[0]
        XCTAssertEqual(u.kind, .freeform)
        assertRect(u.rect, CGRect(x: 0, y: 0, width: 150, height: 100))
        XCTAssertEqual(u.fill, a.fill)
        XCTAssertEqual(u.text, "A")
        XCTAssertTrue(u.contains(CGPoint(x: 125, y: 50)))
        XCTAssertEqual(s.selection, [u.id])
        XCTAssertNoThrow(try DiagramIO.validate(s.doc))
        s.undo()
        XCTAssertEqual(s.doc.shapes.count, 2)
    }

    func testIntersectAndSubtractFollowSelectionOrder() throws {
        let a = rect(0, 0, 100, 100), b = rect(50, 0, 100, 100)
        var s = store([a, b])
        try s.applyOperation(.intersect)
        assertRect(s.doc.shapes[0].rect, CGRect(x: 50, y: 0, width: 50, height: 100))

        s = store([a, b])
        try s.applyOperation(.subtract)
        assertRect(s.doc.shapes[0].rect, CGRect(x: 0, y: 0, width: 50, height: 100))

        s = store([b, a])   // B d'abord : A est retiré de B
        try s.applyOperation(.subtract)
        assertRect(s.doc.shapes[0].rect, CGRect(x: 100, y: 0, width: 50, height: 100))
    }

    func testCombineHollowsOverlap() throws {
        let s = store([rect(0, 0, 100, 100), rect(50, 0, 100, 100)])
        try s.applyOperation(.combine)
        let c = s.doc.shapes[0]
        XCTAssertTrue(c.evenOdd)
        XCTAssertTrue(c.contains(CGPoint(x: 25, y: 50)))
        XCTAssertFalse(c.contains(CGPoint(x: 75, y: 50)), "zone commune évidée")
        XCTAssertTrue(c.contains(CGPoint(x: 125, y: 50)))
    }

    func testFragmentSplitsAlongIntersections() throws {
        let s = store([rect(0, 0, 100, 100), rect(50, 0, 100, 100)])
        try s.applyOperation(.fragment)
        XCTAssertEqual(s.doc.shapes.count, 3)
        let widths = s.doc.shapes.map { ($0.rect.width * 100).rounded() / 100 }.sorted()
        XCTAssertEqual(widths, [50, 50, 50])
        XCTAssertEqual(s.selection.count, 3)
    }

    func testRotationIsTakenIntoAccount() throws {
        var bar = rect(0, 0, 100, 20)
        bar.rotation = 90   // centre (50, 10) : occupe x 40…60, y -40…60
        let s = store([bar, rect(40, 50, 20, 30)])
        try s.applyOperation(.union)
        assertRect(s.doc.shapes[0].rect, CGRect(x: 40, y: -40, width: 20, height: 120))
    }

    func testErrors() {
        let s = store([rect(0, 0, 10, 10), rect(100, 0, 10, 10)])
        XCTAssertThrowsError(try s.applyOperation(.intersect)) {
            XCTAssertEqual($0 as? ShapeOperationError, .emptyResult)
        }
        XCTAssertEqual(s.doc.shapes.count, 2, "rien n'est modifié en cas d'échec")
        s.selection = [s.doc.shapes[0].id]
        XCTAssertFalse(s.canApply(.union))
        XCTAssertThrowsError(try s.applyOperation(.union))
        XCTAssertTrue(s.canApply(.offset))
        let lines = store([line(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), line(CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 5))])
        XCTAssertFalse(lines.canApply(.union), "un trait n'a pas de surface")
        XCTAssertThrowsError(try lines.applyOperation(.trim)) {
            XCTAssertEqual($0 as? ShapeOperationError, .nothingToDo)
        }
    }

    func testJoinChainsLinesAndClosesLoop() throws {
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        let open = store([line(p[0], p[1]), line(p[2], p[1])])   // le second est à l'envers
        try open.applyOperation(.join)
        XCTAssertEqual(open.doc.shapes.count, 1)
        let o = open.doc.shapes[0]
        XCTAssertTrue(o.noFill, "tracé ouvert : pas de remplissage")
        XCTAssertEqual(contours(of: o.paths(in: o.rect).fill).count, 1, "un seul tracé continu")

        let triangle = store([line(p[0], p[1]), line(p[1], p[2]), line(p[2], p[0])])
        try triangle.applyOperation(.join)
        let t = triangle.doc.shapes[0]
        let c = contours(of: t.paths(in: t.rect).fill)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].closed)
        XCTAssertFalse(t.noFill, "boucle fermée : forme remplissable")
        XCTAssertTrue(t.contains(CGPoint(x: 70, y: 30)))
    }

    func testTrimCutsAtIntersections() throws {
        let s = store([line(CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)),
                       line(CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100))])
        try s.applyOperation(.trim)
        XCTAssertEqual(s.doc.shapes.count, 4)
        XCTAssertTrue(s.doc.shapes.allSatisfy { abs(max($0.rect.width, $0.rect.height) - 50) < 0.01 })

        let r = store([rect(0, 0, 100, 100), line(CGPoint(x: -10, y: 50), CGPoint(x: 110, y: 50))])
        try r.applyOperation(.trim)
        XCTAssertEqual(r.doc.shapes.count, 5, "contour coupé en 2, trait coupé en 3")
        XCTAssertNoThrow(try DiagramIO.validate(r.doc))
    }

    func testOffsetKeepsOriginal() throws {
        let s = store([rect(0, 0, 100, 100)])
        s.offsetDistance = 10
        try s.applyOperation(.offset)
        XCTAssertEqual(s.doc.shapes.count, 2)
        let o = s.doc.shapes[1]
        assertRect(o.rect, CGRect(x: -10, y: -10, width: 120, height: 120))
        XCTAssertTrue(o.noFill)
        XCTAssertEqual(contours(of: o.paths(in: o.rect).fill).count, 2, "contours extérieur et intérieur")
    }

    func testFitCurveSmoothsPolyline() throws {
        var path = Path()
        path.addLines([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 40), CGPoint(x: 100, y: 0), CGPoint(x: 150, y: 40)])
        let poly = Shape.freeform(from: path)!
        let s = store([poly])
        try s.applyOperation(.fitCurve)
        let f = s.doc.shapes[0]
        XCTAssertTrue(f.segments.contains { if case .cubic = $0 { return true } else { return false } })
        XCTAssertEqual(f.rect.minX, 0, accuracy: 0.01)
    }

    func testSelectionOrderAndPersistence() throws {
        let a = rect(0, 0, 10, 10), b = rect(5, 0, 10, 10)
        let s = store([b, a])
        XCTAssertEqual(s.selectionOrder, [b.id, a.id])
        s.selection.remove(b.id)
        s.selection.insert(b.id)
        XCTAssertEqual(s.selectionOrder, [a.id, b.id])
        s.selection = [a.id, b.id]
        XCTAssertEqual(s.selectionOrder, [a.id, b.id], "sélection inchangée : ordre conservé")

        try s.applyOperation(.combine)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ops-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramIO.save(s.doc, to: url)
        let loaded = try DiagramIO.load(from: url).pages[0]
        XCTAssertEqual(loaded, s.doc)
        XCTAssertTrue(loaded.shapes[0].evenOdd)
        XCTAssertTrue(SVGExporter.svg(for: loaded).contains("fill-rule=\"evenodd\""))
    }
}

/// Moteur factice : renvoie des réponses écrites à l'avance et garde les requêtes reçues.
final class ScriptedEngine: AssistantEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<EngineReply, Error>]
    private(set) var requests: [[JSONValue]] = []

    init(_ replies: [Result<EngineReply, Error>]) { self.replies = replies }

    func respond(system: String, messages: [JSONValue], tools: [JSONValue]) async throws -> EngineReply {
        let next: Result<EngineReply, Error>? = lock.withLock {
            requests.append(messages)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let next else { return EngineReply(content: [["type": "text", "text": "Fin."]], stopReason: "end_turn") }
        return try next.get()
    }
}

@MainActor
final class AssistantTests: XCTestCase {
    private func toolUse(_ name: String, _ input: JSONValue, id: String = "t1") -> JSONValue {
        ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
    }

    private func wait(_ session: AssistantSession) async {
        for _ in 0..<500 where session.isWorking { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testJSONValueRoundTrip() throws {
        let data = Data(#"{"a":[1,2.5,true,null,"x"],"b":{"c":"é"}}"#.utf8)
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(v["a"]?.array?[0], .int(1))
        XCTAssertEqual(v["a"]?.array?[1].double, 2.5)
        XCTAssertEqual(v["a"]?.array?[2], .bool(true))
        XCTAssertEqual(v["b"]?["c"]?.string, "é")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(v.jsonText.utf8)), v)
        XCTAssertEqual(AssistantToolbox.color("#FF8000"), RGBA(r: 1, g: 128.0 / 255, b: 0, a: 1))
        XCTAssertNil(AssistantToolbox.color("orange"))
        XCTAssertFalse(AssistantToolbox.specs.isEmpty)
        XCTAssertTrue(AssistantPrompt.system.contains("rectangle"))
    }

    func testAddShapesUsesPageUnitsAndScale() throws {
        let store = DocumentStore()
        let tools = AssistantToolbox(store: store)
        var out = tools.run("set_page", ["unit": "m", "scale": 100])
        XCTAssertFalse(out.isError, out.result)
        out = tools.run("add_shapes", ["shapes": [["type": "rectangle", "x": 0, "y": 0, "width": 5, "height": 3,
                                                   "fill": "none", "text": "Pièce"]]])
        XCTAssertFalse(out.isError, out.result)
        let s = store.doc.shapes[0]
        XCTAssertEqual(store.doc.measure(s.rect.width), 5, accuracy: 1e-9)
        XCTAssertEqual(store.doc.measure(s.rect.height), 3, accuracy: 1e-9)
        XCTAssertTrue(s.noFill)
        XCTAssertEqual(s.text, "Pièce")
        let state = tools.pageState()
        XCTAssertEqual(state["shapes"]?.array?.first?["width"]?.double ?? 0, 5, accuracy: 1e-6)
        XCTAssertEqual(state["unit"]?.string, "m")
    }

    func testToolsConnectUpdateDimensionDelete() throws {
        let store = DocumentStore()
        let tools = AssistantToolbox(store: store)
        store.perform { $0.unit = .pt }
        XCTAssertFalse(tools.run("add_shapes", ["shapes": [
            ["type": "rectangle", "x": 0, "y": 0, "width": 100, "height": 50],
            ["type": "diamond", "x": 0, "y": 150, "width": 100, "height": 60, "fill": "#FFA500"],
        ]]).isError)
        let ids = store.doc.shapes.map { AssistantToolbox.shortID($0.id) }
        var out = tools.run("connect_shapes", ["connections": [["from": .string(ids[0]), "to": .string(ids[1])]]])
        XCTAssertFalse(out.isError, out.result)
        XCTAssertEqual(store.doc.connectors.first?.fromPort, 2, "bas de la première forme")
        XCTAssertEqual(store.doc.connectors.first?.toPort, 0, "haut de la seconde")

        out = tools.run("update_shapes", ["ids": [.string(ids[0])], "changes": ["move_by": [10, 0], "bold": true]])
        XCTAssertFalse(out.isError, out.result)
        XCTAssertEqual(store.doc.shapes[0].rect.minX, 10, accuracy: 1e-9)
        XCTAssertTrue(store.doc.shapes[0].textStyle.bold)

        out = tools.run("add_dimension", ["type": "horizontal", "shape": .string(ids[0]), "offset": 20])
        XCTAssertFalse(out.isError, out.result)
        let dim = store.doc.shapes.last!
        XCTAssertEqual(dim.glue.count, 2)
        XCTAssertEqual(dim.dimensionLayout!.value, 100, accuracy: 1e-9)

        XCTAssertTrue(tools.run("update_shapes", ["ids": ["zzzzzz"], "changes": ["fill": "#000000"]]).isError)
        XCTAssertTrue(tools.run("update_shapes", ["ids": [.string(ids[0])], "changes": ["fill": "rouge"]]).isError)
        XCTAssertTrue(tools.run("add_shapes", ["shapes": [["type": "line", "x": 0, "y": 0]]]).isError)
        XCTAssertTrue(tools.run("add_shapes", ["shapes": [["type": "rectangle", "x": 0, "y": 0, "width": -5]]]).isError)
        XCTAssertTrue(tools.run("teleport", [:]).isError)

        out = tools.run("delete_items", ["ids": [.string(ids[1])]])
        XCTAssertFalse(out.isError, out.result)
        XCTAssertTrue(store.doc.connectors.isEmpty, "le connecteur part avec la forme")
        XCTAssertNoThrow(try DiagramIO.validate(store.doc))
    }

    func testSessionRunsToolsAsOneUndoStep() async throws {
        let store = DocumentStore()
        let session = AssistantSession(store: store)
        let engine = ScriptedEngine([
            .success(EngineReply(content: [
                ["type": "text", "text": "Je dessine deux étapes."],
                toolUse("add_shapes", ["shapes": [["type": "rectangle", "x": 0, "y": 0],
                                                  ["type": "rectangle", "x": 0, "y": 100]]]),
            ], stopReason: "tool_use")),
            .success(EngineReply(content: [toolUse("arrange", ["ids": [], "action": "nope"], id: "t2")], stopReason: "tool_use")),
            .success(EngineReply(content: [["type": "text", "text": "C'est fait."]], stopReason: "end_turn")),
        ])
        session.send("Deux étapes", engine: engine)
        await wait(session)
        XCTAssertFalse(session.isWorking)
        XCTAssertEqual(store.doc.shapes.count, 2)
        XCTAssertEqual(session.entries.map(\.kind), [.user, .assistant, .action, .assistant])
        XCTAssertEqual(engine.requests.count, 3)
        // Le résultat de l'outil est renvoyé au modèle, erreurs comprises.
        let lastRequest = engine.requests[2]
        XCTAssertEqual(lastRequest.last?["content"]?.array?.first?["is_error"], .bool(true))
        XCTAssertTrue(lastRequest[0]["content"]?.array?.first?["text"]?.string?.contains("<page>") ?? false)
        store.undo()
        XCTAssertTrue(store.doc.shapes.isEmpty, "toute la réponse s'annule en une fois")
    }

    func testSessionErrorRollsBackHistory() async throws {
        let store = DocumentStore()
        let session = AssistantSession(store: store)
        let engine = ScriptedEngine([.failure(AssistantError.http(401, "invalid x-api-key"))])
        session.send("Bonjour", engine: engine)
        await wait(session)
        XCTAssertEqual(session.entries.last?.kind, .error)
        XCTAssertFalse(store.canUndo)
        // La demande suivante repart d'un historique propre : un seul message utilisateur.
        let next = ScriptedEngine([])
        session.send("Encore", engine: next)
        await wait(session)
        XCTAssertEqual(next.requests.first?.count, 1)
    }
}

@MainActor
final class SheetTests: XCTestCase {
    func testPaperSizesAndOrientation() {
        var setup = PageSetup()
        XCTAssertEqual(setup.paper, .a4)
        XCTAssertEqual(setup.orientation, .landscape)
        XCTAssertEqual(setup.millimetres, CGSize(width: 297, height: 210))
        XCTAssertEqual(setup.size.width, 297 * 72 / 25.4, accuracy: 1e-9)
        setup.orientation = .portrait
        XCTAssertEqual(setup.millimetres, CGSize(width: 210, height: 297))
        setup.paper = .a2
        XCTAssertEqual(setup.millimetres, CGSize(width: 420, height: 594))
        setup.paper = .a5
        setup.orientation = .landscape
        XCTAssertEqual(setup.summary, "A5 paysage")
        setup.paper = .custom
        setup.customWidth = 500
        setup.customHeight = 300
        XCTAssertEqual(setup.millimetres, CGSize(width: 500, height: 300))
        XCTAssertEqual(setup.summary, "500 × 300 mm")
    }

    func testSheetIsSavedValidatedAndDefaultedForOldFiles() throws {
        var d = Diagram()
        d.pageSetup.paper = .a3
        d.pageSetup.orientation = .portrait
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramIO.save(d, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url).pages[0].pageSetup, d.pageSetup)

        var bad = d
        bad.pageSetup.customWidth = 2
        XCTAssertThrowsError(try DiagramIO.validate(bad))
        bad.pageSetup.customWidth = .nan
        XCTAssertThrowsError(try DiagramIO.validate(bad))

        let old = try JSONDecoder().decode(Diagram.self, from: Data(#"{"shapes":[],"connectors":[]}"#.utf8))
        XCTAssertEqual(old.pageSetup, PageSetup(), "ancien fichier : A4 paysage")
    }

    func testFitSheetToDrawingMovesDrawingAndResizesSheet() {
        let store = DocumentStore()
        let a = Shape(kind: .rectangle, rect: CGRect(x: -100, y: 50, width: 200, height: 100))
        let b = Shape(kind: .rectangle, rect: CGRect(x: 900, y: 700, width: 100, height: 100))
        store.perform { $0.shapes = [a, b]; $0.guides = [GuideLine(vertical: true, position: 0)] }
        store.fitSheetToDrawing()
        let margin = 10 / Diagram.millimetresPerWorldUnit
        let d = store.doc
        XCTAssertEqual(d.shapes[0].rect.minX, margin, accuracy: 1e-9)
        XCTAssertEqual(d.shapes[0].rect.minY, margin, accuracy: 1e-9)
        XCTAssertEqual(d.guides[0].position, 100 + margin, accuracy: 1e-9)
        XCTAssertEqual(d.pageSetup.paper, .custom)
        XCTAssertEqual(d.pageSetup.orientation, .landscape)
        XCTAssertTrue(d.sheetRect.contains(d.shapes[1].bounds), "tout le dessin tient sur la feuille")
        XCTAssertNoThrow(try DiagramIO.validate(d))
        store.undo()
        XCTAssertEqual(store.doc.shapes[0].rect.minX, -100)
        XCTAssertEqual(store.doc.pageSetup, PageSetup())
    }

    func testPDFPagesUseTheSheet() throws {
        var doc = CADDocument()
        doc.pages[0].shapes = [Shape(kind: .rectangle, rect: CGRect(x: 10, y: 10, width: 50, height: 50))]
        var second = Diagram()
        second.pageSetup.paper = .a3
        second.pageSetup.orientation = .portrait
        doc.pages.append(second)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramExporter.writePDF(doc, to: url)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 2)
        let first = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(first.width, 297 * 72 / 25.4, accuracy: 0.5)
        XCTAssertEqual(first.height, 210 * 72 / 25.4, accuracy: 0.5)
        let a3 = try XCTUnwrap(pdf.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(a3.height, 420 * 72 / 25.4, accuracy: 0.5)
    }

    func testAssistantCanSetTheSheet() {
        let store = DocumentStore()
        let tools = AssistantToolbox(store: store)
        var out = tools.run("set_page", ["paper": "a3", "orientation": "portrait"])
        XCTAssertFalse(out.isError, out.result)
        XCTAssertEqual(store.doc.pageSetup.millimetres, CGSize(width: 297, height: 420))
        out = tools.run("set_page", ["custom_width_mm": 1000, "custom_height_mm": 600])
        XCTAssertFalse(out.isError, out.result)
        XCTAssertEqual(store.doc.pageSetup.millimetres, CGSize(width: 1000, height: 600))
        XCTAssertTrue(tools.run("set_page", ["custom_width_mm": 1]).isError)
        XCTAssertEqual(tools.pageState()["sheet"]?["paper"]?.string, "custom")
    }
}

@MainActor
final class GridTests: XCTestCase {
    func testVariableGridUsesRoundValuesOfThePageUnit() {
        var d = Diagram()   // mm, échelle 1:1, grille variable normale (12 pt à l'écran au moins)
        XCTAssertEqual(d.measure(d.gridStep(zoom: 1)), 5, accuracy: 1e-9, "12 pt ≈ 4,2 mm → 5 mm")
        XCTAssertEqual(d.measure(d.gridStep(zoom: 4)), 2, accuracy: 1e-9, "zoom 400 % → 2 mm")
        XCTAssertEqual(d.measure(d.gridStep(zoom: 0.1)), 50, accuracy: 1e-9)
        d.grid.density = .coarse
        XCTAssertEqual(d.measure(d.gridStep(zoom: 1)), 10, accuracy: 1e-9)
        d.unit = .m
        d.scale = 100
        XCTAssertEqual(d.measure(d.gridStep(zoom: 1)), 1, accuracy: 1e-9, "1:100 en mètres : 1 m")
        XCTAssertEqual(d.gridSpacingText(zoom: 1), "1 m")
    }

    func testGridIsMetricByDefaultWithPointsAsOption() {
        var d = Diagram()
        XCTAssertEqual(d.grid.measure, .metric)
        d.unit = .inch
        XCTAssertEqual(d.gridMetricUnit, .mm, "page en pouces : grille en millimètres")
        XCTAssertEqual(d.gridMeasure(d.gridStep(zoom: 1)), 5, accuracy: 1e-9)
        XCTAssertEqual(d.gridSpacingText(zoom: 1), "5 mm")
        d.unit = .cm
        XCTAssertEqual(d.gridSpacingText(zoom: 1), "0,5 cm")
        d.scale = 50
        XCTAssertEqual(d.gridSpacingText(zoom: 1), "50 cm", "l'échelle 1:50 agrandit la grille")

        d.grid.measure = .points
        XCTAssertEqual(d.gridStep(zoom: 1), 20, accuracy: 1e-9, "12 pt → 20 pt, sans échelle")
        XCTAssertEqual(d.gridStep(zoom: 2), 10, accuracy: 1e-9)
        XCTAssertEqual(d.gridSpacingText(zoom: 1), "20 pt")
        d.grid.mode = .fixed
        d.grid.fixedSpacing = Double(d.gridWorldLength(15))
        XCTAssertEqual(d.gridStep(zoom: 3), 15, accuracy: 1e-9)

        let old = try? JSONDecoder().decode(GridSettings.self, from: Data(#"{"visible":false}"#.utf8))
        XCTAssertEqual(old?.measure, .metric, "anciens réglages : grille métrique")
        XCTAssertEqual(old?.visible, false)
    }

    func testFixedGridDrivesSnapAndIsSaved() throws {
        let store = DocumentStore()
        store.updatePageSettings { $0.grid.mode = .fixed; $0.grid.fixedSpacing = 25; $0.grid.subdivisions = 4 }
        XCTAssertEqual(store.gridSize, 25)
        store.zoom = 3
        XCTAssertEqual(store.gridSize, 25, "grille fixe : indépendante du zoom")
        XCTAssertEqual(store.snap(CGPoint(x: 37, y: 63)), CGPoint(x: 25, y: 75))
        store.snapEnabled = false
        XCTAssertEqual(store.snap(CGPoint(x: 37, y: 63)), CGPoint(x: 37, y: 63))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grid-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiagramIO.save(store.doc, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url).pages[0].grid, store.doc.grid)
        var bad = store.doc
        bad.grid.subdivisions = 0
        XCTAssertThrowsError(try DiagramIO.validate(bad))
        bad.grid.subdivisions = 5
        bad.grid.fixedSpacing = -1
        XCTAssertThrowsError(try DiagramIO.validate(bad))
        store.undo()
        XCTAssertEqual(store.doc.grid, GridSettings(), "réglage de grille annulable")
    }

    func testAssistantCanSetTheGrid() {
        let store = DocumentStore()
        let tools = AssistantToolbox(store: store)
        var out = tools.run("set_page", ["grid_unit": "points", "grid_spacing": 18])
        XCTAssertFalse(out.isError, out.result)
        XCTAssertEqual(store.gridSize, 18, accuracy: 1e-9)
        out = tools.run("set_page", ["grid_unit": "metric", "grid_spacing": 20, "grid_visible": false])
        XCTAssertFalse(out.isError, out.result)
        XCTAssertEqual(store.doc.grid.mode, .fixed)
        XCTAssertFalse(store.doc.grid.visible)
        XCTAssertEqual(store.doc.measure(store.gridSize), 20, accuracy: 1e-9)
        XCTAssertEqual(tools.pageState()["grid"]?["mode"]?.string, "fixed")
        XCTAssertEqual(Diagram.formatCompact(2.50), "2,5")
        XCTAssertEqual(Diagram.formatCompact(5), "5")
    }
}

@MainActor
final class ConsistencyTests: XCTestCase {
    func testNewPageInheritsPageSettings() {
        let store = DocumentStore()
        store.updatePageSettings {
            $0.unit = .m; $0.scale = 100; $0.precision = 3
            $0.pageSetup.paper = .a3; $0.grid.mode = .fixed; $0.defaultRouting = .curved
        }
        store.addPage()
        let page = store.doc
        XCTAssertEqual(store.currentPage, 1)
        XCTAssertEqual(page.unit, .m)
        XCTAssertEqual(page.scale, 100)
        XCTAssertEqual(page.precision, 3)
        XCTAssertEqual(page.pageSetup.paper, .a3)
        XCTAssertEqual(page.grid.mode, .fixed)
        XCTAssertEqual(page.defaultRouting, .curved)
        XCTAssertTrue(page.shapes.isEmpty)
    }

    func testDuplicatedPageKeepsDimensionGlue() {
        let store = DocumentStore()
        let rect = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        var dim = Shape(kind: .dimensionHorizontal, rect: .zero, line: .dimensionDefault)
        dim.setWorldPoints([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: -20)])
        dim.glue = [GluePoint(point: 0, shape: rect.id, anchor: 0), GluePoint(point: 1, shape: rect.id, anchor: 1)]
        store.perform { $0.shapes = [rect, dim] }
        store.duplicatePage(0)
        let copy = store.doc
        let newRect = copy.shapes[0], newDim = copy.shapes[1]
        XCTAssertNotEqual(newRect.id, rect.id)
        XCTAssertEqual(Set(newDim.glue.map(\.shape)), [newRect.id], "la cote copiée reste collée à la forme copiée")
        store.perform { $0.shapes[0].rect.size.width = 150 }
        XCTAssertEqual(store.doc.shapes[1].dimensionLayout!.value, 150, accuracy: 1e-9)
        XCTAssertNoThrow(try DiagramIO.validate(store.doc))
    }

    func testToolLabelsAndShortcutsAreConsistent() {
        XCTAssertEqual(Tool.select.label, "Pointeur")
        XCTAssertEqual(Tool.select.labelWithShortcut, "Pointeur (V)")
        XCTAssertEqual(Set(Tool.allCases.map(\.shortcut)).count, Tool.allCases.count)
        XCTAssertTrue(AssistantPrompt.system.contains("Pointeur (V)"))
    }
}

@MainActor
final class ScaleChangeTests: XCTestCase {
    func testChangingScaleKeepsRealDimensionsAndResizesTheDrawing() {
        let store = DocumentStore()
        store.updatePageSettings { $0.unit = .m; $0.scale = 100 }
        let w = store.doc.worldLength(forMeasure: 5), h = store.doc.worldLength(forMeasure: 3)
        let room = Shape(kind: .rectangle, rect: CGRect(x: 20, y: 30, width: w, height: h))
        var dim = Shape(kind: .dimensionHorizontal, rect: .zero, line: .dimensionDefault)
        dim.setWorldPoints([CGPoint(x: 20, y: 30), CGPoint(x: 20 + w, y: 30), CGPoint(x: 20 + w / 2, y: 10)])
        dim.glue = [GluePoint(point: 0, shape: room.id, anchor: 0), GluePoint(point: 1, shape: room.id, anchor: 1)]
        store.perform {
            $0.shapes = [room, dim]
            $0.guides = [GuideLine(vertical: true, position: 100)]
            $0.grid.mode = .fixed
            $0.grid.fixedSpacing = Double($0.worldLength(forMeasure: 0.5))
        }

        store.updatePageSettings { $0.scale = 50 }   // 1:100 → 1:50 : le dessin double sur la feuille
        let d = store.doc
        XCTAssertEqual(d.shapes[0].rect.width, 2 * w, accuracy: 1e-9)
        XCTAssertEqual(d.shapes[0].rect.minX, 40, accuracy: 1e-9)
        XCTAssertEqual(d.measure(d.shapes[0].rect.width), 5, accuracy: 1e-9, "5 m restent 5 m")
        XCTAssertEqual(d.dimensionMeasure(d.shapes[1]), "5,0 m")
        XCTAssertEqual(d.shapes[1].glue.count, 2, "la cote reste collée")
        XCTAssertEqual(d.guides[0].position, 200, accuracy: 1e-9)
        XCTAssertEqual(d.measure(d.gridStep(zoom: 1)), 0.5, accuracy: 1e-9, "grille fixe : 0,5 m réels")
        XCTAssertNoThrow(try DiagramIO.validate(d))

        store.undo()
        XCTAssertEqual(store.doc.scale, 100)
        XCTAssertEqual(store.doc.shapes[0].rect.width, w, accuracy: 1e-9)
    }

    func testScaleChangeThatWouldOverflowIsRefused() {
        let store = DocumentStore()
        store.perform { $0.shapes = [Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 5_000_000, height: 10))] }
        store.updatePageSettings { $0.scale = 0.001 }   // ×1000 : dépasserait les limites du dessin
        XCTAssertEqual(store.doc.scale, 1)
        XCTAssertEqual(store.doc.shapes[0].rect.width, 5_000_000)
    }
}

final class NumericFieldTests: XCTestCase {
    func testParsingAcceptsCommaDotAndSpaces() {
        XCTAssertEqual(NumericField.parse("50"), 50)
        XCTAssertEqual(NumericField.parse("2,5"), 2.5)
        XCTAssertEqual(NumericField.parse("2.5"), 2.5)
        XCTAssertEqual(NumericField.parse(" 1 000 "), 1000)
        XCTAssertEqual(NumericField.parse("1\u{202F}000,25"), 1000.25)
        XCTAssertEqual(NumericField.parse("\u{2212}3"), -3)
    }

    func testEmptyOrInvalidInputIsRejected() {
        // Champ vidé (dernier chiffre effacé) : pas de valeur, la saisie n'est pas appliquée.
        XCTAssertNil(NumericField.parse(""))
        XCTAssertNil(NumericField.parse("   "))
        XCTAssertNil(NumericField.parse("abc"))
        XCTAssertNil(NumericField.parse("1:50"))
        XCTAssertNil(NumericField.parse("nan"))
        XCTAssertNil(NumericField.parse("inf"))
        XCTAssertNil(NumericField.parse("1e400"))
    }

    func testFormattedValuesReadBack() {
        for v in [1.0, 50, 100, 1000, 2.5, 0.125, 12345.6789] {
            let text = NumericField.format(v, fractionDigits: 4)
            XCTAssertEqual(NumericField.parse(text) ?? .nan, v, accuracy: 1e-9, text)
        }
        XCTAssertEqual(NumericField.parse(NumericField.format(1000, fractionDigits: 0)), 1000, "sans séparateur de milliers")
    }
}

@MainActor
final class PageCenteringTests: XCTestCase {
    func testPageIsCentredWhenTheDrawingAreaIsFirstMeasured() {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 1000, height: 700)   // apparition de la zone de dessin
        let sheet = store.doc.sheetRect
        let centre = store.toWorld(CGPoint(x: 500, y: 350))
        XCTAssertEqual(centre.x, sheet.midX, accuracy: 1e-6)
        XCTAssertEqual(centre.y, sheet.midY, accuracy: 1e-6)
        // Toute la feuille est visible, avec une marge.
        let topLeft = store.toWorld(.zero), bottomRight = store.toWorld(CGPoint(x: 1000, y: 700))
        XCTAssertLessThan(topLeft.x, sheet.minX)
        XCTAssertLessThan(topLeft.y, sheet.minY)
        XCTAssertGreaterThan(bottomRight.x, sheet.maxX)
        XCTAssertGreaterThan(bottomRight.y, sheet.maxY)
    }

    func testPageStaysCentredWhilePanesResizeUntilTheUserMovesTheView() {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 1000, height: 700)
        store.canvasSize = CGSize(width: 700, height: 700)    // volet ouvert
        var centre = store.toWorld(CGPoint(x: 350, y: 350))
        XCTAssertEqual(centre.x, store.doc.sheetRect.midX, accuracy: 1e-6)

        store.zoom(by: 1.25)                                   // l'utilisateur zoome : la vue lui appartient
        let zoom = store.zoom, offset = store.offset
        store.canvasSize = CGSize(width: 900, height: 700)
        XCTAssertEqual(store.zoom, zoom)
        XCTAssertEqual(store.offset, offset)

        store.fitPage()                                        // nouveau document : à nouveau centré
        centre = store.toWorld(CGPoint(x: 450, y: 350))
        XCTAssertEqual(centre.x, store.doc.sheetRect.midX, accuracy: 1e-6)
        XCTAssertEqual(centre.y, store.doc.sheetRect.midY, accuracy: 1e-6)
    }

    func testChangingThePaperKeepsThePageCentred() {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 1000, height: 700)
        store.updatePageSettings { $0.pageSetup.orientation = $0.pageSetup.orientation == .portrait ? .landscape : .portrait }
        let centre = store.toWorld(CGPoint(x: 500, y: 350))
        XCTAssertEqual(centre.x, store.doc.sheetRect.midX, accuracy: 1e-6)
        XCTAssertEqual(centre.y, store.doc.sheetRect.midY, accuracy: 1e-6)
    }
}

@MainActor
final class ShapeDrawingTests: XCTestCase {
    func testSimpleClickIsNotADrag() {
        let p = CGPoint(x: 100, y: 100)
        XCTAssertFalse(ShapeDrawing.isDrag(from: p, to: p, zoom: 1), "simple clic : rien n'est créé")
        XCTAssertFalse(ShapeDrawing.isDrag(from: p, to: CGPoint(x: 103, y: 101), zoom: 1))
        XCTAssertTrue(ShapeDrawing.isDrag(from: p, to: CGPoint(x: 110, y: 100), zoom: 1))
        XCTAssertFalse(ShapeDrawing.isDrag(from: p, to: CGPoint(x: 104, y: 100), zoom: 1), "5 px écran au moins")
        XCTAssertTrue(ShapeDrawing.isDrag(from: p, to: CGPoint(x: 104, y: 100), zoom: 2))
    }

    func testFreeRectangleFollowsTheDragInAnyDirection() {
        let r = ShapeDrawing.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 40, y: 160),
                                  kind: .rectangle, aspect: nil, fromCenter: false)
        XCTAssertEqual(r, CGRect(x: 40, y: 100, width: 60, height: 60))
    }

    func testShiftKeepsProportionsAndOptionDrawsFromTheCentre() {
        let square = ShapeDrawing.rect(from: .zero, to: CGPoint(x: 80, y: 30), kind: .ellipse, aspect: 1, fromCenter: false)
        XCTAssertEqual(square, CGRect(x: 0, y: 0, width: 80, height: 80))
        let upLeft = ShapeDrawing.rect(from: .zero, to: CGPoint(x: -30, y: -90), kind: .rectangle, aspect: 2, fromCenter: false)
        XCTAssertEqual(upLeft, CGRect(x: -180, y: -90, width: 180, height: 90))
        let centred = ShapeDrawing.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 70, y: 60),
                                        kind: .rectangle, aspect: nil, fromCenter: true)
        XCTAssertEqual(centred, CGRect(x: 30, y: 40, width: 40, height: 20))
    }

    func testFlatDragGivesAMinimumHeight() {
        let r = ShapeDrawing.rect(from: .zero, to: CGPoint(x: 100, y: 0), kind: .rectangle, aspect: nil, fromCenter: false)
        XCTAssertEqual(r.width, 100)
        XCTAssertEqual(r.height, ShapeDrawing.minimumSize(for: .rectangle).height)
    }

    func testSegmentAngleConstraintAndCentre() {
        let s = ShapeDrawing.segment(from: .zero, to: CGPoint(x: 100, y: 8), constrainAngle: true, fromCenter: false)
        XCTAssertEqual(s.end.y, 0, accuracy: 1e-9)
        XCTAssertEqual(s.end.x, hypot(100, 8), accuracy: 1e-9)
        let c = ShapeDrawing.segment(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 10), constrainAngle: false, fromCenter: true)
        XCTAssertEqual(c.start, CGPoint(x: -10, y: 10))
        XCTAssertEqual(c.end, CGPoint(x: 30, y: 10))
    }

    func testLibraryShapeIsArmedThenDrawnInTheDraggedFrame() throws {
        let store = DocumentStore()
        let item = try XCTUnwrap(StencilCatalog.libraries.first?.items.first)
        store.armStencil(item)
        XCTAssertEqual(store.activeStencil?.id, item.id)
        XCTAssertTrue(store.doc.shapes.isEmpty, "un clic sur la vignette n'insère rien")

        let r = CGRect(x: 10, y: 20, width: 200, height: 90)
        store.insertStencil(item, in: r)
        XCTAssertEqual(store.doc.shapes.count, 1)
        XCTAssertEqual(store.doc.shapes[0].kind, item.kind)
        XCTAssertEqual(store.doc.shapes[0].rect, r)
        XCTAssertEqual(store.activeStencil?.id, item.id, "la forme reste choisie pour en tracer d'autres")

        store.armStencil(item)
        XCTAssertNil(store.activeStencil, "second clic : abandon")
        store.armStencil(item)
        store.tool = .rectangle
        XCTAssertNil(store.activeStencil, "choisir un outil abandonne la forme de bibliothèque")
    }

    func testLibraryDimensionKeepsItsStyle() throws {
        let store = DocumentStore()
        let item = try XCTUnwrap(StencilCatalog.libraries.first { $0.id == "dimensions" }?.items
            .first { $0.kind == .dimensionHorizontal && $0.variant == "architecture" })
        store.insertPath(kind: item.kind, from: CGPoint(x: 0, y: 100), to: CGPoint(x: 200, y: 100), line: item.line)
        let s = try XCTUnwrap(store.doc.shapes.first)
        XCTAssertEqual(s.kind, .dimensionHorizontal)
        XCTAssertEqual(s.line, item.line)
        XCTAssertFalse(store.doc.dimensionMeasure(s).isEmpty)
        XCTAssertNoThrow(try DiagramIO.validate(store.doc))
    }
}

@MainActor
final class GroupRotationTests: XCTestCase {
    /// Groupe : rectangle, trait et cote alignée collée au rectangle, plus une forme hors groupe.
    private func groupedStore() -> (DocumentStore, rect: UUID, line: UUID, dim: UUID, outside: UUID) {
        let store = DocumentStore()
        let rect = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        var line = Shape(kind: .line, rect: .zero, line: .pathDefault)
        line.setWorldPoints([CGPoint(x: 0, y: 80), CGPoint(x: 100, y: 80)])
        var dim = Shape(kind: .dimension, rect: .zero, line: .dimensionDefault)
        dim.setWorldPoints(makeDimensionPoints(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), offset: 20))
        dim.glue = [GluePoint(point: 0, shape: rect.id, anchor: 0), GluePoint(point: 1, shape: rect.id, anchor: 1)]
        let outside = Shape(kind: .ellipse, rect: CGRect(x: 300, y: 300, width: 40, height: 40))
        store.perform { $0.shapes = [rect, line, dim, outside] }
        store.selection = [rect.id, line.id, dim.id]
        store.groupSelection()
        return (store, rect.id, line.id, dim.id, outside.id)
    }

    func testGroupedShapesOfAllKindsRotateTogether() throws {
        let (store, rectID, lineID, dimID, outsideID) = groupedStore()
        store.selection = store.expandedToGroups([rectID])
        let frame = try XCTUnwrap(store.selectionRotationFrame)
        let pivot = frame.center
        let rectCentre = store.doc.shape(rectID)!.center
        let lineStart = store.doc.shape(lineID)!.worldPoints[0]
        let measure = store.doc.dimensionMeasure(store.doc.shape(dimID)!)

        store.rotateSelection(by: 90)

        let rect = try XCTUnwrap(store.doc.shape(rectID))
        XCTAssertEqual(rect.rotation, 90)
        let expectedCentre = rectCentre.rotated(by: .pi / 2, around: pivot)
        XCTAssertEqual(rect.center.x, expectedCentre.x, accuracy: 1e-3)
        XCTAssertEqual(rect.center.y, expectedCentre.y, accuracy: 1e-3)
        let expectedStart = lineStart.rotated(by: .pi / 2, around: pivot)
        XCTAssertEqual(store.doc.shape(lineID)!.worldPoints[0].x, expectedStart.x, accuracy: 1e-3)
        XCTAssertEqual(store.doc.shape(lineID)!.worldPoints[0].y, expectedStart.y, accuracy: 1e-3)
        let dim = try XCTUnwrap(store.doc.shape(dimID))
        XCTAssertEqual(dim.glue.count, 2, "la cote reste collée au rectangle du groupe")
        XCTAssertEqual(store.doc.dimensionMeasure(dim), measure)
        XCTAssertEqual(store.doc.shape(outsideID)!.rect, CGRect(x: 300, y: 300, width: 40, height: 40), "hors groupe : inchangée")
        XCTAssertTrue(store.selectedShapes.allSatisfy { $0.groupRotation == 90 })
        XCTAssertNoThrow(try DiagramIO.validate(store.doc))

        store.undo()
        XCTAssertEqual(store.doc.shape(rectID)!.rotation, 0)
        XCTAssertEqual(store.doc.shape(rectID)!.center, rectCentre)
    }

    func testGroupFrameStaysOrientedAndRotationFieldSetsTheAngle() throws {
        let (store, rectID, _, _, _) = groupedStore()
        store.selection = store.expandedToGroups([rectID])
        let before = try XCTUnwrap(store.selectionRotationFrame)
        XCTAssertEqual(before.angle, 0)

        store.setSelectionRotation(30)
        let after = try XCTUnwrap(store.selectionRotationFrame)
        XCTAssertEqual(after.angle, 30, accuracy: 1e-9)
        XCTAssertEqual(after.size.width, before.size.width, accuracy: 1e-2, "le cadre du groupe pivote sans grandir")
        XCTAssertEqual(after.size.height, before.size.height, accuracy: 1e-2)
        XCTAssertEqual(after.center.x, before.center.x, accuracy: 1e-2)
        XCTAssertEqual(store.doc.shape(rectID)!.rotation, 30, accuracy: 1e-9)

        store.setSelectionRotation(0)
        XCTAssertEqual(store.doc.shape(rectID)!.rotation, 0, accuracy: 1e-9)
        XCTAssertEqual(store.doc.shape(rectID)!.rect.minX, 0, accuracy: 1e-2)
        XCTAssertEqual(store.doc.shape(rectID)!.rect.minY, 0, accuracy: 1e-2)
    }

    func testMultipleSelectionRotatesByTheEnteredAngle() throws {
        let store = DocumentStore()
        let a = Shape(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 40, height: 20))
        let b = Shape(kind: .rectangle, rect: CGRect(x: 100, y: 0, width: 40, height: 20))
        store.perform { $0.shapes = [a, b] }
        store.selection = [a.id, b.id]
        XCTAssertEqual(store.selectionRotationFrame?.angle, 0)
        store.setSelectionRotation(45)
        XCTAssertEqual(store.doc.shape(a.id)!.rotation, 45, accuracy: 1e-9)
        XCTAssertEqual(store.doc.shape(b.id)!.rotation, 45, accuracy: 1e-9)
        XCTAssertEqual(store.doc.shape(a.id)!.groupRotation, 0, "hors groupe : pas d'angle de groupe")
        XCTAssertEqual(store.selectionRotationFrame?.angle, 0)
    }

    func testLiveRotationStartsFromTheOriginals() throws {
        let (store, rectID, _, _, _) = groupedStore()
        store.selection = store.expandedToGroups([rectID])
        let frame = try XCTUnwrap(store.selectionRotationFrame)
        let originals = store.selectedShapes
        store.beginTransaction()
        for angle in stride(from: 5.0, through: 60, by: 5) {
            store.applyLiveRotation(originals: originals, by: angle, around: frame.center)
        }
        store.commitTransaction()
        XCTAssertEqual(store.doc.shape(rectID)!.rotation, 60, accuracy: 1e-9, "pas d'accumulation")
        XCTAssertEqual(store.selectedShapes.first!.groupRotation, 60, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(store.doc.shape(rectID)!.rotation, 0, "une seule étape d'annulation")
    }

    func testGroupAngleIsSavedAndResetOnUngroup() throws {
        let (store, rectID, _, _, _) = groupedStore()
        store.selection = store.expandedToGroups([rectID])
        store.setSelectionRotation(20)
        let s = try XCTUnwrap(store.doc.shape(rectID))
        let decoded = try JSONDecoder().decode(Shape.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.groupRotation, 20, accuracy: 1e-9)

        var bad = store.doc
        bad.shapes[0].groupRotation = .nan
        XCTAssertThrowsError(try DiagramIO.validate(bad))

        store.ungroupSelection()
        XCTAssertTrue(store.doc.shapes.allSatisfy { $0.groupRotation == 0 })
        XCTAssertEqual(store.doc.shape(rectID)!.rotation, 20, accuracy: 1e-9, "les formes gardent leur rotation")
    }
}
