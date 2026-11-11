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
