import XCTest
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
        XCTAssertEqual(try DiagramIO.load(from: url), d)
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
            let b = parts.fill.boundingRect.union(parts.stroke.boundingRect)
            XCTAssertTrue(r.insetBy(dx: -1, dy: -1).contains(b), "\(kind) déborde de son cadre : \(b)")
        }
    }

    func testCatalogIsConsistent() {
        let items = StencilCatalog.libraries.flatMap(\.items)
        XCTAssertEqual(Set(items.map(\.kind)).count, items.count, "type présent dans deux bibliothèques")
        for item in items {
            XCTAssertGreaterThan(item.size.width, 0)
            XCTAssertGreaterThan(item.size.height, 0)
        }
        // Tous les types sauf « texte » sont proposés dans une bibliothèque.
        for kind in ShapeKind.allCases where kind != .text {
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
            Shape(kind: $0.kind, rect: CGRect(origin: .zero, size: $0.size), text: $0.defaultText)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stencils-\(UUID().uuidString).cad2d")
        defer { try? FileManager.default.removeItem(at: url) }
        let d = Diagram(shapes: shapes)
        try DiagramIO.save(d, to: url)
        XCTAssertEqual(try DiagramIO.load(from: url), d)
    }
}
