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
    // Formes de base (aussi utilisées par l'organigramme : processus, connecteur, décision)
    case rectangle, ellipse, diamond, text
    // Tracés libres : trait (2 points) et courbe de Bézier quadratique (début, contrôle, fin)
    case line, curve
    // Organigramme
    case terminator, data, document, predefinedProcess, manualInput, preparation
    case database, offPageReference, delay, manualOperation
    // Réseau
    case server, workstation, laptop, router, networkSwitch, firewall, cloud, printer, accessPoint
    // Électricité (symboles IEC, bornes à gauche et à droite)
    case resistor, capacitor, inductor, diode, battery, electricSwitch, ground, lamp, acSource, motor, fuse
}

struct Shape: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ShapeKind
    /// Rectangle englobant en coordonnées « monde » (origine en haut à gauche, Y vers le bas).
    var rect: CGRect
    var text = ""
    var fill = RGBA.defaultFill
    /// Rotation en degrés (sens horaire à l'écran) autour du centre du rectangle.
    var rotation: Double = 0
    /// Points d'un trait ou d'une courbe, relatifs à `rect.origin` (vide pour les autres formes).
    var points: [CGPoint] = []

    enum CodingKeys: String, CodingKey { case id, kind, rect, text, fill, rotation, points }
}

extension Shape {
    /// Décodage tolérant : les fichiers créés avant la rotation restent lisibles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ShapeKind.self, forKey: .kind)
        rect = try c.decode(CGRect.self, forKey: .rect)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill) ?? .defaultFill
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
    }
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
        return routeConnector(from: a.portPoint(c.fromPort), dirA: a.portDirection(c.fromPort),
                              to: b.portPoint(c.toPort), dirB: b.portDirection(c.toPort))
    }
}
