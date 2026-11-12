import Foundation
import CoreGraphics

// MARK: - Outils de l'assistant
//
// L'IA n'écrit jamais dans le fichier : elle appelle ces outils. Chaque appel est appliqué sur une
// copie de la page, validé comme un fichier ouvert (DiagramIO.validate), puis seulement recopié dans
// le document. Toutes les longueurs échangées sont dans l'unité de la page, échelle comprise.

struct AssistantToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
struct AssistantToolbox {
    let store: DocumentStore

    struct Outcome {
        var result: String
        var isError = false
        /// Ligne affichée dans le panneau (nil : rien à signaler).
        var summary: String?
    }

    static let maxItemsPerCall = 500

    // MARK: Définitions (schémas JSON envoyés au modèle)

    static var shapeTypes: [ShapeKind] {
        ShapeKind.allCases.filter { !$0.isPath && $0 != .freeform }
    }

    private static let styleProperties: [String: JSONValue] = [
        "text": ["type": "string", "description": "Texte affiché dans la forme"],
        "fill": ["type": "string", "description": "Couleur de remplissage #RRGGBB, ou \"none\" pour aucun remplissage"],
        "fill_transparency": ["type": "number", "description": "Transparence du remplissage, 0 à 1"],
        "line_color": ["type": "string", "description": "Couleur du trait #RRGGBB"],
        "line_width": ["type": "number", "description": "Épaisseur du trait en points (0,25 à 20)"],
        "line_dash": ["type": "string", "enum": ["solid", "dash", "dot", "dash_dot", "long_dash", "none"]],
        "begin_arrow": ["type": "string", "enum": ["none", "open", "filled", "circle", "diamond", "tick"]],
        "end_arrow": ["type": "string", "enum": ["none", "open", "filled", "circle", "diamond", "tick"]],
        "font_size": ["type": "number", "description": "Taille du texte en points"],
        "bold": ["type": "boolean"],
        "italic": ["type": "boolean"],
        "text_color": ["type": "string", "description": "#RRGGBB"],
        "text_align": ["type": "string", "enum": ["left", "center", "right"]],
        "rotation": ["type": "number", "description": "Rotation en degrés (sens horaire)"],
        "layer": ["type": "string", "description": "Nom d'un calque existant"],
    ]

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    private static func tool(_ name: String, _ description: String, _ schema: JSONValue) -> JSONValue {
        ["name": .string(name), "description": .string(description), "input_schema": schema]
    }

    static let specs: [JSONValue] = {
        var shapeProps = AssistantToolbox.styleProperties
        shapeProps["type"] = ["type": "string", "enum": .array(AssistantToolbox.shapeTypes.map { .string($0.rawValue) })]
        shapeProps["x"] = ["type": "number", "description": "Bord gauche"]
        shapeProps["y"] = ["type": "number", "description": "Bord haut"]
        shapeProps["width"] = ["type": "number", "description": "Largeur (facultatif : taille par défaut du type)"]
        shapeProps["height"] = ["type": "number", "description": "Hauteur (facultatif)"]

        var lineProps = AssistantToolbox.styleProperties
        lineProps["type"] = ["type": "string", "enum": ["line", "curve"]]
        lineProps["points"] = ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                               "description": "Trait : [[x1,y1],[x2,y2]]. Courbe : [[début],[point de contrôle],[fin]]"]

        var changes = AssistantToolbox.styleProperties
        changes["x"] = ["type": "number"]
        changes["y"] = ["type": "number"]
        changes["width"] = ["type": "number"]
        changes["height"] = ["type": "number"]
        changes["move_by"] = ["type": "array", "items": ["type": "number"], "description": "Déplacement [dx, dy]"]
        changes["routing"] = ["type": "string", "enum": ["orthogonal", "straight", "curved"],
                              "description": "Connecteurs seulement"]

        let ids: JSONValue = ["type": "array", "items": ["type": "string"], "description": "Identifiants (get_page)"]
        let side: JSONValue = ["type": "string", "enum": ["top", "right", "bottom", "left"]]
        let arrowEnum: JSONValue = ["type": "string", "enum": ["none", "open", "filled", "circle", "diamond", "tick"]]
        var connection: [String: JSONValue] = [:]
        connection["from"] = ["type": "string"]
        connection["to"] = ["type": "string"]
        connection["from_side"] = side
        connection["to_side"] = side
        connection["routing"] = ["type": "string", "enum": ["orthogonal", "straight", "curved"]]
        connection["line_color"] = ["type": "string"]
        connection["line_width"] = ["type": "number"]
        connection["line_dash"] = ["type": "string", "enum": ["solid", "dash", "dot", "dash_dot", "long_dash"]]
        connection["begin_arrow"] = arrowEnum
        connection["end_arrow"] = arrowEnum
        let anchor: JSONValue = ["type": "string", "enum": ["top_left", "top_right", "bottom_right", "bottom_left",
                                                             "top_middle", "right_middle", "bottom_middle",
                                                             "left_middle", "center", "start", "end"]]
        return [
            AssistantToolbox.tool("get_page", "Renvoie l'état complet de la page : unité, échelle, zone visible, calques, formes, traits, cotes, connecteurs et sélection.",
                 AssistantToolbox.object([:])),
            AssistantToolbox.tool("add_shapes", "Ajoute des formes (rectangles, ellipses, symboles des bibliothèques…). Renvoie leurs identifiants.",
                 AssistantToolbox.object(["shapes": ["type": "array", "items": AssistantToolbox.object(shapeProps, required: ["type", "x", "y"])]],
                        required: ["shapes"])),
            AssistantToolbox.tool("add_lines", "Ajoute des traits droits ou des courbes.",
                 AssistantToolbox.object(["lines": ["type": "array", "items": AssistantToolbox.object(lineProps, required: ["type", "points"])]],
                        required: ["lines"])),
            AssistantToolbox.tool("connect_shapes", "Relie des formes par des connecteurs (qui suivent les formes). Côtés : choisis automatiquement si absents.",
                 AssistantToolbox.object(["connections": ["type": "array", "items": AssistantToolbox.object(connection, required: ["from", "to"])]],
                             required: ["connections"])),
            AssistantToolbox.tool("add_dimension", "Ajoute une cote collée à une forme : elle suit la forme et sa mesure se met à jour. Points : coins, milieux des côtés, centre (start/end pour un trait).",
                 AssistantToolbox.object([
                    "type": ["type": "string", "enum": ["horizontal", "vertical", "aligned", "radius", "diameter"]],
                    "shape": ["type": "string", "description": "Forme cotée"],
                    "from": anchor, "to": anchor,
                    "to_shape": ["type": "string", "description": "Forme du second point si différente"],
                    "offset": ["type": "number", "description": "Écart de la ligne de cote (positif : au-dessus ou à gauche)"],
                    "style": ["type": "string", "enum": ["engineering", "architecture"]],
                 ], required: ["type", "shape"])),
            AssistantToolbox.tool("update_shapes", "Modifie des formes, traits ou connecteurs existants (position, taille, texte, style).",
                 AssistantToolbox.object(["ids": ids, "changes": AssistantToolbox.object(changes)], required: ["ids", "changes"])),
            AssistantToolbox.tool("delete_items", "Supprime des formes ou des connecteurs.", AssistantToolbox.object(["ids": ids], required: ["ids"])),
            AssistantToolbox.tool("arrange", "Aligne, répartit, groupe, change l'ordre d'empilement ou fait pivoter des formes.",
                 AssistantToolbox.object(["ids": ids, "action": ["type": "string", "enum": [
                    "align_left", "align_center", "align_right", "align_top", "align_middle", "align_bottom",
                    "distribute_horizontal", "distribute_vertical", "group", "ungroup",
                    "bring_to_front", "send_to_back", "rotate_right", "rotate_left"]]],
                        required: ["ids", "action"])),
            AssistantToolbox.tool("shape_operation", "Opération sur les formes, comme dans Visio. L'ordre des identifiants compte : la première forme donne son format et sert de base à subtract.",
                 AssistantToolbox.object(["ids": ids,
                         "operation": ["type": "string", "enum": .array(ShapeOperation.allCases.map { .string($0.rawValue) })],
                         "offset_distance": ["type": "number", "description": "Distance pour offset"]],
                        required: ["ids", "operation"])),
            AssistantToolbox.tool("set_page", "Change l'unité, l'échelle (1:N, donner N) ou la précision d'affichage de la page.",
                 AssistantToolbox.object(["unit": ["type": "string", "enum": .array(MeasureUnit.allCases.map { .string($0.rawValue) })],
                         "scale": ["type": "number"], "precision": ["type": "integer"]])),
            AssistantToolbox.tool("select", "Sélectionne des éléments pour les montrer à l'utilisateur.", AssistantToolbox.object(["ids": ids], required: ["ids"])),
            AssistantToolbox.tool("fit_view", "Ajuste le zoom pour afficher tout le dessin.", AssistantToolbox.object([:])),
        ]
    }()

    // MARK: Exécution

    func run(_ name: String, _ input: JSONValue) -> Outcome {
        do {
            switch name {
            case "get_page": return Outcome(result: pageState().jsonText)
            case "add_shapes": return try addShapes(input)
            case "add_lines": return try addLines(input)
            case "connect_shapes": return try connect(input)
            case "add_dimension": return try addDimension(input)
            case "update_shapes": return try update(input)
            case "delete_items": return try delete(input)
            case "arrange": return try arrange(input)
            case "shape_operation": return try shapeOperation(input)
            case "set_page": return try setPage(input)
            case "select":
                store.selection = try resolveAll(input["ids"])
                return Outcome(result: "ok")
            case "fit_view":
                store.fitToContent()
                return Outcome(result: "ok")
            default:
                throw AssistantToolError("Outil inconnu : \(name)")
            }
        } catch {
            return Outcome(result: error.localizedDescription, isError: true)
        }
    }

    // MARK: Conversions

    private var d: Diagram { store.doc }

    private func length(_ v: JSONValue?, _ name: String) throws -> CGFloat? {
        guard let v else { return nil }
        guard let x = v.double else { throw AssistantToolError("« \(name) » doit être un nombre") }
        let w = d.worldLength(forMeasure: x)
        guard w.isFinite, abs(w) <= DiagramIO.maxCoordinate / 2 else {
            throw AssistantToolError("« \(name) » est hors limites à l'échelle actuelle : changez l'échelle avec set_page")
        }
        return w
    }

    private func point(_ v: JSONValue?) throws -> CGPoint {
        guard let a = v?.array, a.count == 2 else { throw AssistantToolError("Point attendu : [x, y]") }
        return CGPoint(x: try length(a[0], "x") ?? 0, y: try length(a[1], "y") ?? 0)
    }

    static func color(_ text: String) -> RGBA? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? (v << 8) | 0xFF : v
        return RGBA(r: Double((rgba >> 24) & 0xFF) / 255, g: Double((rgba >> 16) & 0xFF) / 255,
                    b: Double((rgba >> 8) & 0xFF) / 255, a: Double(rgba & 0xFF) / 255)
    }

    static func hex(_ c: RGBA) -> String {
        func b(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }

    private func requireColor(_ v: JSONValue, _ name: String) throws -> RGBA {
        guard let s = v.string, let c = Self.color(s) else { throw AssistantToolError("« \(name) » : couleur #RRGGBB attendue") }
        return c
    }

    private func dash(_ v: JSONValue) throws -> DashPattern {
        let map: [String: DashPattern] = ["solid": .solid, "dash": .dash, "dot": .dot, "dash_dot": .dashDot,
                                          "long_dash": .longDash, "none": .none]
        guard let s = v.string, let p = map[s] else { throw AssistantToolError("Type de trait inconnu") }
        return p
    }

    private func arrow(_ v: JSONValue) throws -> ArrowHead {
        guard let s = v.string, let a = ArrowHead(rawValue: s) else { throw AssistantToolError("Extrémité inconnue") }
        return a
    }

    /// Style commun aux formes et aux traits.
    private func applyStyle(_ spec: JSONValue, to s: inout Shape) throws {
        if let v = spec["text"] {
            guard let t = v.string, t.count <= DiagramIO.maxTextLength else { throw AssistantToolError("Texte invalide") }
            s.text = t
        }
        if let v = spec["fill"] {
            if v.string == "none" { s.noFill = true } else { s.fill = try requireColor(v, "fill"); s.noFill = false }
        }
        if let v = spec["fill_transparency"]?.double { s.fillTransparency = min(max(v, 0), 1) }
        try applyLine(spec, to: &s.line)
        if let v = spec["font_size"]?.double { s.textStyle.size = min(max(v, 4), 400) }
        if let v = spec["bold"]?.bool { s.textStyle.bold = v }
        if let v = spec["italic"]?.bool { s.textStyle.italic = v }
        if let v = spec["text_color"] { s.textStyle.color = try requireColor(v, "text_color") }
        if let v = spec["text_align"] {
            guard let a = v.string.flatMap(TextAlign.init(rawValue:)) else { throw AssistantToolError("Alignement inconnu") }
            s.textStyle.alignment = a
        }
        if let v = spec["rotation"]?.double, !s.kind.isPath { s.rotation = normalizedAngle(v) }
        if let v = spec["layer"] {
            guard let name = v.string, let layer = d.layers.first(where: { $0.name == name }) else {
                throw AssistantToolError("Calque inconnu")
            }
            s.layerID = layer.id
        }
    }

    private func applyLine(_ spec: JSONValue, to l: inout LineStyle) throws {
        if let v = spec["line_color"] { l.color = try requireColor(v, "line_color") }
        if let v = spec["line_width"]?.double { l.width = min(max(v, 0.25), 20) }
        if let v = spec["line_dash"] { l.dash = try dash(v) }
        if let v = spec["begin_arrow"] { l.beginArrow = try arrow(v) }
        if let v = spec["end_arrow"] { l.endArrow = try arrow(v) }
    }

    // MARK: Identifiants

    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    private func resolve(_ text: String) throws -> UUID {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard key.count >= 4 else { throw AssistantToolError("Identifiant trop court : \(text)") }
        let all = d.shapes.map(\.id) + d.connectors.map(\.id)
        let matches = all.filter { $0.uuidString.lowercased().hasPrefix(key) }
        guard matches.count == 1, let id = matches.first else {
            throw AssistantToolError(matches.isEmpty ? "Élément introuvable : \(text)" : "Identifiant ambigu : \(text)")
        }
        return id
    }

    private func resolveAll(_ v: JSONValue?) throws -> Set<UUID> {
        Set(try resolveOrdered(v))
    }

    private func resolveOrdered(_ v: JSONValue?) throws -> [UUID] {
        guard let list = v?.array, list.count <= Self.maxItemsPerCall else { throw AssistantToolError("Liste d'identifiants attendue") }
        return try list.map { item in
            guard let s = item.string else { throw AssistantToolError("Identifiant invalide") }
            return try resolve(s)
        }
    }

    /// Applique une modification validée à la page.
    private func commit(_ page: Diagram) throws {
        do { try DiagramIO.validate(page) } catch {
            throw AssistantToolError("Modification refusée : \(error.localizedDescription)")
        }
        store.doc = page
    }

    private func items(_ v: JSONValue?, _ name: String) throws -> [JSONValue] {
        guard let a = v?.array, !a.isEmpty else { throw AssistantToolError("« \(name) » : liste attendue") }
        guard a.count <= Self.maxItemsPerCall else { throw AssistantToolError("Trop d'éléments en un appel") }
        return a
    }

    // MARK: Outils

    private func addShapes(_ input: JSONValue) throws -> Outcome {
        var page = d
        var created: [UUID] = []
        for spec in try items(input["shapes"], "shapes") {
            guard let type = spec["type"]?.string, let kind = ShapeKind(rawValue: type), Self.shapeTypes.contains(kind) else {
                throw AssistantToolError("Type de forme inconnu : \(spec["type"]?.string ?? "?")")
            }
            let defaultSize = StencilCatalog.item(for: kind)?.size ?? (kind == .text ? CGSize(width: 120, height: 30)
                                                                                    : CGSize(width: 120, height: 70))
            let w = try length(spec["width"], "width") ?? defaultSize.width
            let h = try length(spec["height"], "height") ?? defaultSize.height
            guard w > 0, h > 0 else { throw AssistantToolError("Largeur et hauteur doivent être positives") }
            let origin = CGPoint(x: try length(spec["x"], "x") ?? 0, y: try length(spec["y"], "y") ?? 0)
            var s = Shape(kind: kind, rect: CGRect(origin: origin, size: CGSize(width: w, height: h)))
            s.text = StencilCatalog.item(for: kind)?.defaultText ?? ""
            s.layerID = page.activeLayerID
            try applyStyle(spec, to: &s)
            page.shapes.append(s)
            created.append(s.id)
        }
        try commit(page)
        return Outcome(result: (["created": .array(created.map { .string(Self.shortID($0)) })] as JSONValue).jsonText,
                       summary: created.count == 1 ? "1 forme ajoutée" : "\(created.count) formes ajoutées")
    }

    private func addLines(_ input: JSONValue) throws -> Outcome {
        var page = d
        var created: [UUID] = []
        for spec in try items(input["lines"], "lines") {
            guard let type = spec["type"]?.string, let kind = ShapeKind(rawValue: type), kind == .line || kind == .curve else {
                throw AssistantToolError("Type de trait inconnu")
            }
            guard let raw = spec["points"]?.array, raw.count == kind.pointCount else {
                throw AssistantToolError(kind == .line ? "Un trait a 2 points" : "Une courbe a 3 points")
            }
            var s = Shape(kind: kind, rect: .zero, fill: RGBA(r: 0.2, g: 0.2, b: 0.2, a: 1), line: .pathDefault)
            s.setWorldPoints(try raw.map { try point($0) })
            s.layerID = page.activeLayerID
            try applyStyle(spec, to: &s)
            page.shapes.append(s)
            created.append(s.id)
        }
        try commit(page)
        return Outcome(result: (["created": .array(created.map { .string(Self.shortID($0)) })] as JSONValue).jsonText,
                       summary: created.count == 1 ? "1 trait ajouté" : "\(created.count) traits ajoutés")
    }

    private func connect(_ input: JSONValue) throws -> Outcome {
        var page = d
        var created: [UUID] = []
        let sides = ["top": 0, "right": 1, "bottom": 2, "left": 3]
        for spec in try items(input["connections"], "connections") {
            let fromID = try resolve(spec["from"]?.string ?? ""), toID = try resolve(spec["to"]?.string ?? "")
            guard let a = page.shape(fromID), let b = page.shape(toID), !a.kind.isPath, !b.kind.isPath, a.id != b.id else {
                throw AssistantToolError("Un connecteur relie deux formes différentes (pas des traits)")
            }
            let fromPort = try spec["from_side"].map { v -> Int in
                guard let p = v.string.flatMap({ sides[$0] }) else { throw AssistantToolError("Côté inconnu") }
                return p
            } ?? a.nearestPort(to: b.center)
            let toPort = try spec["to_side"].map { v -> Int in
                guard let p = v.string.flatMap({ sides[$0] }) else { throw AssistantToolError("Côté inconnu") }
                return p
            } ?? b.nearestPort(to: a.center)
            var c = Connector(fromShape: a.id, fromPort: fromPort, toShape: b.id, toPort: toPort)
            c.routing = page.defaultRouting
            if let r = spec["routing"] {
                guard let routing = r.string.flatMap(ConnectorRouting.init(rawValue:)) else { throw AssistantToolError("Routage inconnu") }
                c.routing = routing
            }
            try applyLine(spec, to: &c.line)
            page.connectors.append(c)
            created.append(c.id)
        }
        try commit(page)
        return Outcome(result: (["created": .array(created.map { .string(Self.shortID($0)) })] as JSONValue).jsonText,
                       summary: created.count == 1 ? "1 connecteur ajouté" : "\(created.count) connecteurs ajoutés")
    }

    private func addDimension(_ input: JSONValue) throws -> Outcome {
        guard let type = input["type"]?.string else { throw AssistantToolError("Type de cote manquant") }
        let kinds: [String: ShapeKind] = ["horizontal": .dimensionHorizontal, "vertical": .dimensionVertical,
                                          "aligned": .dimension, "radius": .radiusDimension, "diameter": .diameterDimension]
        guard let kind = kinds[type] else { throw AssistantToolError("Type de cote inconnu") }
        var page = d
        let shapeID = try resolve(input["shape"]?.string ?? "")
        let secondID = try (input["to_shape"]?.string).map { try resolve($0) } ?? shapeID
        guard let first = page.shape(shapeID), let second = page.shape(secondID),
              !first.kind.isDimension, !second.kind.isDimension else {
            throw AssistantToolError("La cote doit viser des formes (pas une autre cote)")
        }
        let names = ["top_left", "top_right", "bottom_right", "bottom_left", "top_middle", "right_middle",
                     "bottom_middle", "left_middle", "center"]
        func anchor(_ v: JSONValue?, of s: Shape, default fallback: String) throws -> (index: Int, point: CGPoint) {
            let name = v?.string ?? fallback
            let anchors = s.glueAnchors
            let index: Int?
            if s.kind.isPath {
                index = ["start": 0, "end": 1][name]
            } else {
                index = names.firstIndex(of: name)
            }
            guard let i = index, anchors.indices.contains(i) else { throw AssistantToolError("Point « \(name) » inconnu pour cette forme") }
            return (i, anchors[i])
        }
        let round = kind == .radiusDimension || kind == .diameterDimension
        let a = try anchor(input["from"], of: first, default: round ? "center" : (first.kind.isPath ? "start" : "top_left"))
        let b = try anchor(input["to"], of: second, default: round ? "right_middle" : (second.kind.isPath ? "end" : "top_right"))
        guard a.point.distance(to: b.point) > 0.01 else { throw AssistantToolError("Les deux points sont confondus") }
        let offset = try length(input["offset"], "offset") ?? 24
        var points: [CGPoint]
        switch kind {
        case .dimensionHorizontal:
            let y = offset >= 0 ? min(a.point.y, b.point.y) - offset : max(a.point.y, b.point.y) - offset
            points = [a.point, b.point, CGPoint(x: 0, y: y)]
        case .dimensionVertical:
            let x = offset >= 0 ? min(a.point.x, b.point.x) - offset : max(a.point.x, b.point.x) - offset
            points = [a.point, b.point, CGPoint(x: x, y: 0)]
        case .dimension:
            points = makeDimensionPoints(a.point, b.point, offset: offset)
        default:
            points = [a.point, b.point]
        }
        points = normalizedDimensionPoints(kind: kind, points)
        var line = input["style"]?.string == "architecture" ? LineStyle.architecturalDimension : LineStyle.dimensionDefault
        if kind == .radiusDimension { line.beginArrow = .none }
        var s = Shape(kind: kind, rect: .zero, fill: RGBA(r: 0.2, g: 0.2, b: 0.2, a: 1), line: line)
        s.setWorldPoints(points)
        s.glue = [GluePoint(point: 0, shape: first.id, anchor: a.index), GluePoint(point: 1, shape: second.id, anchor: b.index)]
        s.layerID = page.activeLayerID
        page.shapes.append(s)
        try commit(page)
        let measure = store.doc.shape(s.id).map { store.doc.dimensionMeasure($0) } ?? ""
        return Outcome(result: (["created": .string(Self.shortID(s.id)), "measure": .string(measure)] as JSONValue).jsonText,
                       summary: "Cote ajoutée : \(measure)")
    }

    private func update(_ input: JSONValue) throws -> Outcome {
        let ids = try resolveOrdered(input["ids"])
        guard let changes = input["changes"], changes.object != nil else { throw AssistantToolError("« changes » attendu") }
        var page = d
        for id in ids {
            if let i = page.shapes.firstIndex(where: { $0.id == id }) {
                var s = page.shapes[i]
                if !s.kind.isPath {
                    if let x = try length(changes["x"], "x") { s.rect.origin.x = x }
                    if let y = try length(changes["y"], "y") { s.rect.origin.y = y }
                    if let w = try length(changes["width"], "width") {
                        guard w > 0 else { throw AssistantToolError("Largeur positive attendue") }
                        s.rect.size.width = w
                    }
                    if let h = try length(changes["height"], "height") {
                        guard h > 0 else { throw AssistantToolError("Hauteur positive attendue") }
                        s.rect.size.height = h
                    }
                }
                if let move = changes["move_by"] {
                    let delta = try point(move)
                    if s.kind.isPath {
                        s.setWorldPoints(s.worldPoints.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) })
                    } else {
                        s.rect.origin.x += delta.x
                        s.rect.origin.y += delta.y
                    }
                }
                try applyStyle(changes, to: &s)
                page.shapes[i] = s
            } else if let i = page.connectors.firstIndex(where: { $0.id == id }) {
                try applyLine(changes, to: &page.connectors[i].line)
                if let r = changes["routing"] {
                    guard let routing = r.string.flatMap(ConnectorRouting.init(rawValue:)) else { throw AssistantToolError("Routage inconnu") }
                    page.connectors[i].routing = routing
                }
            }
        }
        try commit(page)
        return Outcome(result: "ok", summary: ids.count == 1 ? "1 élément modifié" : "\(ids.count) éléments modifiés")
    }

    private func delete(_ input: JSONValue) throws -> Outcome {
        let ids = try resolveAll(input["ids"])
        var page = d
        page.removeItems(ids)
        try commit(page)
        store.selection.subtract(ids)
        return Outcome(result: "ok", summary: ids.count == 1 ? "1 élément supprimé" : "\(ids.count) éléments supprimés")
    }

    private func arrange(_ input: JSONValue) throws -> Outcome {
        let ids = try resolveOrdered(input["ids"])
        guard let action = input["action"]?.string else { throw AssistantToolError("Action manquante") }
        store.selection = Set(ids)
        let alignments: [String: ShapeAlignment] = ["align_left": .left, "align_center": .center, "align_right": .right,
                                                    "align_top": .top, "align_middle": .middle, "align_bottom": .bottom]
        if let a = alignments[action] {
            store.align(a)
        } else {
            switch action {
            case "distribute_horizontal": store.distribute(.horizontal)
            case "distribute_vertical": store.distribute(.vertical)
            case "group": store.groupSelection()
            case "ungroup": store.ungroupSelection()
            case "bring_to_front": store.reorderSelection(.front)
            case "send_to_back": store.reorderSelection(.back)
            case "rotate_right": store.rotateSelection(by: 90)
            case "rotate_left": store.rotateSelection(by: -90)
            default: throw AssistantToolError("Action inconnue : \(action)")
            }
        }
        return Outcome(result: "ok", summary: "Disposition : \(action.replacingOccurrences(of: "_", with: " "))")
    }

    private func shapeOperation(_ input: JSONValue) throws -> Outcome {
        let ids = try resolveOrdered(input["ids"])
        guard let name = input["operation"]?.string, let op = ShapeOperation(rawValue: name) else {
            throw AssistantToolError("Opération inconnue")
        }
        if let distance = try length(input["offset_distance"], "offset_distance") {
            guard distance > 0 else { throw AssistantToolError("Distance positive attendue") }
            store.offsetDistance = distance
        }
        store.selection = []
        for id in ids { store.selection.insert(id) }
        try store.applyOperation(op)
        let created = store.selection.map { JSONValue.string(Self.shortID($0)) }
        return Outcome(result: (["created": .array(created)] as JSONValue).jsonText, summary: "Opération : \(op.label)")
    }

    private func setPage(_ input: JSONValue) throws -> Outcome {
        var unit = d.unit, scale = d.scale, precision = d.precision
        if let u = input["unit"] {
            guard let v = u.string.flatMap(MeasureUnit.init(rawValue:)) else { throw AssistantToolError("Unité inconnue") }
            if v != unit { precision = v.defaultPrecision }
            unit = v
        }
        if let s = input["scale"] {
            guard let v = s.double, Diagram.scaleRange.contains(v) else { throw AssistantToolError("Échelle invalide") }
            scale = v
        }
        if let p = input["precision"] {
            guard let v = p.double, (0...4).contains(Int(v)) else { throw AssistantToolError("Précision : 0 à 4") }
            precision = Int(v)
        }
        store.updatePageSettings { $0.unit = unit; $0.scale = scale; $0.precision = precision }
        return Outcome(result: "ok", summary: "Page : unité \(unit.symbol), échelle 1:\(Diagram.format(scale, decimals: scale < 1 ? 4 : 0))")
    }

    // MARK: État de la page

    /// Description de la page envoyée au modèle (longueurs dans l'unité de la page).
    func pageState(limit: Int = 300) -> JSONValue {
        let page = d
        func m(_ v: CGFloat) -> JSONValue { .number((page.measure(v) * 1000).rounded() / 1000) }
        func pt(_ p: CGPoint) -> JSONValue { [m(p.x), m(p.y)] }
        let layerNames = Dictionary(page.layers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        var shapes: [JSONValue] = []
        for s in page.shapes.prefix(limit) where page.isVisible(s) {
            var o: [String: JSONValue] = ["id": .string(Self.shortID(s.id)), "type": .string(s.kind.rawValue)]
            if s.kind.isDimension {
                o["measure"] = .string(page.dimensionMeasure(s))
                o["glued_to"] = .array(Array(Set(s.glue.map(\.shape))).map { .string(Self.shortID($0)) })
            } else if s.kind.isPath {
                o["points"] = .array(s.worldPoints.map(pt))
            } else {
                o["x"] = m(s.rect.minX); o["y"] = m(s.rect.minY)
                o["width"] = m(s.rect.width); o["height"] = m(s.rect.height)
                if s.rotation != 0 { o["rotation"] = .number(s.rotation) }
                o["fill"] = .string(s.noFill ? "none" : Self.hex(s.fill))
            }
            if !s.text.isEmpty { o["text"] = .string(String(s.text.prefix(200))) }
            if s.line.dash == .none { o["line"] = "none" } else if !s.kind.isDimension {
                o["line_color"] = .string(Self.hex(s.line.color))
            }
            if page.layers.count > 1, let l = s.layerID, let name = layerNames[l] { o["layer"] = .string(name) }
            if let g = s.groupID { o["group"] = .string(Self.shortID(g)) }
            if !page.isSelectable(s) { o["locked"] = true }
            shapes.append(.object(o))
        }
        let connectors: [JSONValue] = page.connectors.prefix(limit).map { c -> JSONValue in
            ["id": .string(Self.shortID(c.id)), "from": .string(Self.shortID(c.fromShape)),
             "to": .string(Self.shortID(c.toShape)), "routing": .string(c.routing.rawValue)]
        }
        let topLeft = store.toWorld(.zero)
        let bottomRight = store.toWorld(CGPoint(x: store.canvasSize.width, y: store.canvasSize.height))
        var state: [String: JSONValue] = [
            "page": .string(page.name),
            "unit": .string(page.unit.rawValue),
            "scale_1_to": .number(page.scale),
            "visible_area": ["x": m(topLeft.x), "y": m(topLeft.y),
                             "width": m(bottomRight.x - topLeft.x), "height": m(bottomRight.y - topLeft.y)],
            "layers": .array(page.layers.map { l -> JSONValue in
                ["name": .string(l.name), "visible": .bool(l.visible), "locked": .bool(l.locked),
                 "active": .bool(l.id == page.activeLayerID)]
            }),
            "shapes": .array(shapes),
            "connectors": .array(connectors),
            "selection": .array(store.selectionOrder.map { .string(Self.shortID($0)) }),
        ]
        if page.shapes.count > limit || page.connectors.count > limit {
            state["truncated"] = .string("Page volumineuse : seuls les \(limit) premiers éléments sont listés.")
        }
        return .object(state)
    }
}
