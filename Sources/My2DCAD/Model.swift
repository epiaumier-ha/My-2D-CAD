import Foundation
import SwiftUI
import AppKit

// MARK: - Modèle de données (indépendant du rendu)

struct RGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let defaultFill = RGBA(r: 0.87, g: 0.92, b: 0.99, a: 1)

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

enum ShapeKind: String, Codable, CaseIterable {
    case rectangle, ellipse, diamond, text
}

struct Shape: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ShapeKind
    /// Rectangle englobant en coordonnées « monde » (origine en haut à gauche, Y vers le bas).
    var rect: CGRect
    var text = ""
    var fill = RGBA.defaultFill
}

/// Connecteur collé : il référence des points de connexion (0 haut, 1 droite, 2 bas, 3 gauche)
/// de deux formes. Son tracé est recalculé quand les formes bougent.
struct Connector: Identifiable, Codable, Equatable {
    var id = UUID()
    var fromShape: UUID
    var fromPort: Int
    var toShape: UUID
    var toPort: Int
}

struct Diagram: Codable, Equatable {
    static let currentVersion = 1

    var version = Diagram.currentVersion
    var shapes: [Shape] = []
    var connectors: [Connector] = []

    func shape(_ id: UUID) -> Shape? { shapes.first { $0.id == id } }

    mutating func removeItems(_ ids: Set<UUID>) {
        shapes.removeAll { ids.contains($0.id) }
        connectors.removeAll {
            ids.contains($0.id) || ids.contains($0.fromShape) || ids.contains($0.toShape)
        }
    }

    func connectorPoints(_ c: Connector) -> [CGPoint]? {
        guard let a = shape(c.fromShape), let b = shape(c.toShape) else { return nil }
        return routeConnector(from: a.portPoint(c.fromPort), portA: c.fromPort,
                              to: b.portPoint(c.toPort), portB: c.toPort)
    }
}
