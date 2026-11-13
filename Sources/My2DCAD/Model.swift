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
    // Cote linéaire alignée (2 points mesurés + point de décalage) et forme libre (tracé quelconque, import SVG)
    case dimension, freeform
    // Cotation : cotes horizontale et verticale, angulaire, de rayon et de diamètre
    case dimensionHorizontal, dimensionVertical, angularDimension, radiusDimension, diameterDimension
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
    /// Attributs du trait (contour des formes, traits, courbes).
    var line = LineStyle()
    /// Mise en forme du texte.
    var textStyle = TextStyle()
    /// Remplissage désactivé (forme transparente, seul le contour est dessiné).
    var noFill = false
    /// Transparence du remplissage : 0 = opaque, 1 = invisible.
    var fillTransparency: Double = 0
    /// Calque de la forme (nil : aucun calque, toujours visible).
    var layerID: UUID?
    /// Groupe de la forme : toutes les formes d'un même groupe se sélectionnent ensemble.
    var groupID: UUID?
    /// Tracé d'une forme libre, en coordonnées relatives au rectangle (0…1).
    var segments: [PathSegment] = []
    /// Décalage du bloc de texte par rapport à sa position par défaut (repère de la forme, unités du dessin).
    var textOffset: CGPoint = .zero
    /// Largeur personnalisée du bloc de texte (nil : automatique).
    var textBlockWidth: Double?
    /// Cote : extrémités collées à des points d'autres formes (suivent leurs déplacements).
    var glue: [GluePoint] = []
    /// Remplissage pair-impair (résultats des opérations sur les formes : les zones évidées restent vides).
    var evenOdd = false
    /// Angle du groupe de la forme, en degrés (identique pour tous les membres) : le cadre du groupe
    /// reste orienté après une rotation. 0 hors groupe.
    var groupRotation: Double = 0
    /// Point de rotation choisi (nil : centre), relatif à la forme : fraction du rectangle (formes),
    /// ou repère premier point → dernier point (traits, courbes, cotes). Il suit la forme.
    var pin: CGPoint?
    /// Point de rotation du groupe de la forme (nil : centre du cadre), fraction du cadre orienté du
    /// groupe ; identique pour tous les membres.
    var groupPin: CGPoint?
    /// Les sommets de la forme s'ajoutent aux points de connexion (milieux des côtés).
    var vertexPorts = false

    enum CodingKeys: String, CodingKey {
        case id, kind, rect, text, fill, rotation, points, line, textStyle, noFill, fillTransparency, layerID, groupID
        case segments, textOffset, textBlockWidth, glue, evenOdd, groupRotation, pin, groupPin, vertexPorts
    }

    /// Couleur de remplissage effective (nil si aucun remplissage).
    var fillColor: Color? {
        noFill ? nil : fill.color.opacity(1 - fillTransparency)
    }

    /// Le remplissage a-t-il un sens pour ce type ? (ni texte, ni trait, ni symbole électrique)
    var supportsFill: Bool { kind != .text && !kind.isPath && !kind.isLineArt }
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
        // Anciens fichiers : la couleur d'un trait ou d'une courbe était stockée dans « fill ».
        line = try c.decodeIfPresent(LineStyle.self, forKey: .line)
            ?? (kind.isPath ? LineStyle(color: fill, width: 2) : LineStyle())
        textStyle = try c.decodeIfPresent(TextStyle.self, forKey: .textStyle) ?? TextStyle()
        noFill = try c.decodeIfPresent(Bool.self, forKey: .noFill) ?? false
        fillTransparency = try c.decodeIfPresent(Double.self, forKey: .fillTransparency) ?? 0
        layerID = try c.decodeIfPresent(UUID.self, forKey: .layerID)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        segments = try c.decodeIfPresent([PathSegment].self, forKey: .segments) ?? []
        textOffset = try c.decodeIfPresent(CGPoint.self, forKey: .textOffset) ?? .zero
        textBlockWidth = try c.decodeIfPresent(Double.self, forKey: .textBlockWidth)
        glue = try c.decodeIfPresent([GluePoint].self, forKey: .glue) ?? []
        evenOdd = try c.decodeIfPresent(Bool.self, forKey: .evenOdd) ?? false
        groupRotation = try c.decodeIfPresent(Double.self, forKey: .groupRotation) ?? 0
        pin = try c.decodeIfPresent(CGPoint.self, forKey: .pin)
        groupPin = try c.decodeIfPresent(CGPoint.self, forKey: .groupPin)
        vertexPorts = try c.decodeIfPresent(Bool.self, forKey: .vertexPorts) ?? false
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
    var line = LineStyle.connectorDefault
    var routing: ConnectorRouting = .orthogonal
    /// Ordre de superposition : le connecteur est dessiné juste au-dessus de cette forme
    /// (nil, ou forme disparue : sous toutes les formes, comme à sa création).
    var afterShape: UUID?

    enum CodingKeys: String, CodingKey { case id, fromShape, fromPort, toShape, toPort, line, routing, afterShape }
}

extension Connector {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fromShape = try c.decode(UUID.self, forKey: .fromShape)
        fromPort = try c.decode(Int.self, forKey: .fromPort)
        toShape = try c.decode(UUID.self, forKey: .toShape)
        toPort = try c.decode(Int.self, forKey: .toPort)
        line = try c.decodeIfPresent(LineStyle.self, forKey: .line) ?? .connectorDefault
        routing = try c.decodeIfPresent(ConnectorRouting.self, forKey: .routing) ?? .orthogonal
        afterShape = try c.decodeIfPresent(UUID.self, forKey: .afterShape)
    }
}

/// Calque d'une page (équivalent des calques de Visio).
struct Layer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// Formes affichées.
    var visible = true
    /// Formes affichées mais impossibles à sélectionner ou à modifier.
    var locked = false
    /// Formes incluses dans l'export PDF / PNG et l'impression.
    var printable = true
}

/// Une page du dessin : formes, connecteurs et calques.
struct Diagram: Codable, Equatable {
    static let currentVersion = 1

    var version = Diagram.currentVersion
    var shapes: [Shape] = []
    var connectors: [Connector] = []
    var id = UUID()
    var name = "Page 1"
    var layers: [Layer] = []
    /// Calque attribué aux nouvelles formes (nil : aucun calque).
    var activeLayerID: UUID?
    /// Unité affichée (règles, cotes, barre d'état), échelle du dessin (1:scale) et décimales.
    var unit: MeasureUnit = .mm
    var scale: Double = 1
    var precision: Int = 1
    /// Routage des nouveaux connecteurs.
    var defaultRouting: ConnectorRouting = .orthogonal
    /// Repères tirés des règles.
    var guides: [GuideLine] = []
    /// Feuille : format et orientation de la page imprimée.
    var pageSetup = PageSetup()
    /// Grille : affichage, espacement variable ou fixe, subdivisions.
    var grid = GridSettings()
    /// Image d'arrière-plan de la page (sous la grille et les formes), incorporée au fichier.
    var backgroundImage: BackgroundImage?

    enum CodingKeys: String, CodingKey {
        case version, shapes, connectors, id, name, layers, activeLayerID
        case unit, scale, precision, defaultRouting, guides, pageSetup, grid, backgroundImage
    }

    func shape(_ id: UUID) -> Shape? { shapes.first { $0.id == id } }

    // MARK: Calques

    func layer(_ id: UUID?) -> Layer? {
        guard let id else { return nil }
        return layers.first { $0.id == id }
    }

    func isVisible(_ s: Shape) -> Bool { layer(s.layerID)?.visible ?? true }

    func isLocked(_ s: Shape) -> Bool { layer(s.layerID)?.locked ?? false }

    /// Peut être cliquée, sélectionnée et modifiée.
    func isSelectable(_ s: Shape) -> Bool { isVisible(s) && !isLocked(s) }

    /// Incluse dans l'export et l'impression.
    func isPrintable(_ s: Shape) -> Bool {
        guard let l = layer(s.layerID) else { return true }
        return l.visible && l.printable
    }

    /// Un connecteur est visible si ses deux formes le sont.
    func isVisible(_ c: Connector) -> Bool {
        guard let a = shape(c.fromShape), let b = shape(c.toShape) else { return false }
        return isVisible(a) && isVisible(b)
    }

    mutating func removeItems(_ ids: Set<UUID>) {
        // Connecteurs posés au-dessus d'une forme supprimée : ils gardent leur place dans l'empilement.
        if connectors.contains(where: { $0.afterShape.map(ids.contains) ?? false }) {
            var below: [UUID: UUID?] = [:]
            var last: UUID?
            for s in shapes {
                if ids.contains(s.id) { below[s.id] = last } else { last = s.id }
            }
            for i in connectors.indices {
                if let a = connectors[i].afterShape, let b = below[a] { connectors[i].afterShape = b }
            }
        }
        shapes.removeAll { ids.contains($0.id) }
        // Cotes collées à une forme supprimée : elles restent en place, décollées.
        for i in shapes.indices where !shapes[i].glue.isEmpty {
            shapes[i].glue.removeAll { ids.contains($0.shape) }
        }
        connectors.removeAll {
            ids.contains($0.id) || ids.contains($0.fromShape) || ids.contains($0.toShape)
        }
    }
}

extension Diagram {
    /// Décodage tolérant : les pages des anciens fichiers n'ont ni nom, ni calques.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Diagram.currentVersion
        shapes = try c.decodeIfPresent([Shape].self, forKey: .shapes) ?? []
        connectors = try c.decodeIfPresent([Connector].self, forKey: .connectors) ?? []
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Page 1"
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        activeLayerID = try c.decodeIfPresent(UUID.self, forKey: .activeLayerID)
        unit = try c.decodeIfPresent(MeasureUnit.self, forKey: .unit) ?? .mm
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        precision = try c.decodeIfPresent(Int.self, forKey: .precision) ?? 1
        defaultRouting = try c.decodeIfPresent(ConnectorRouting.self, forKey: .defaultRouting) ?? .orthogonal
        guides = try c.decodeIfPresent([GuideLine].self, forKey: .guides) ?? []
        pageSetup = try c.decodeIfPresent(PageSetup.self, forKey: .pageSetup) ?? PageSetup()
        grid = try c.decodeIfPresent(GridSettings.self, forKey: .grid) ?? GridSettings()
        backgroundImage = try c.decodeIfPresent(BackgroundImage.self, forKey: .backgroundImage)
    }
}

/// Document complet : une ou plusieurs pages (format de fichier version 2).
struct CADDocument: Codable, Equatable {
    static let currentVersion = 2
    static let maxPages = 200

    var version = CADDocument.currentVersion
    var pages: [Diagram] = [Diagram()]
}
