import Foundation

enum DiagramIOError: LocalizedError {
    case fileTooLarge
    case unsupportedVersion(Int)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "Le fichier est trop volumineux."
        case .unsupportedVersion(let v): return "Version de fichier non prise en charge (\(v))."
        case .invalid(let m): return "Fichier invalide : \(m)"
        }
    }
}

/// Lecture/écriture JSON avec validation stricte : un fichier est une donnée non fiable.
enum DiagramIO {
    static let maxFileSize = 50 * 1024 * 1024
    static let maxShapes = 50_000
    static let maxConnectors = 100_000
    static let maxCoordinate: CGFloat = 10_000_000
    static let maxTextLength = 10_000
    static let maxLayers = 64
    static let maxNameLength = 200

    private struct VersionProbe: Decodable {
        var version: Int?
    }

    /// Lit un fichier .cad2d : version 2 (plusieurs pages) ou version 1 (une seule page).
    static func load(from url: URL) throws -> CADDocument {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? Int, size > maxFileSize { throw DiagramIOError.fileTooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileSize else { throw DiagramIOError.fileTooLarge }
        let version = (try? JSONDecoder().decode(VersionProbe.self, from: data))?.version ?? 1
        let document: CADDocument
        switch version {
        case 1:
            document = CADDocument(pages: [try JSONDecoder().decode(Diagram.self, from: data)])
        case CADDocument.currentVersion:
            document = try JSONDecoder().decode(CADDocument.self, from: data)
        default:
            throw DiagramIOError.unsupportedVersion(version)
        }
        try validate(document)
        // Cotes collées recalées sur leurs formes (fichier modifié ailleurs, cible disparue).
        var resolved = document
        for i in resolved.pages.indices { resolved.pages[i].resolveGlue(previous: nil) }
        return resolved
    }

    static func save(_ document: CADDocument, to url: URL) throws {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    /// Enregistre une seule page (document d'une page).
    static func save(_ diagram: Diagram, to url: URL) throws {
        try save(CADDocument(pages: [diagram]), to: url)
    }

    static func validate(_ document: CADDocument) throws {
        guard document.version == CADDocument.currentVersion else {
            throw DiagramIOError.unsupportedVersion(document.version)
        }
        guard (1...CADDocument.maxPages).contains(document.pages.count) else {
            throw DiagramIOError.invalid("nombre de pages incorrect")
        }
        guard Set(document.pages.map(\.id)).count == document.pages.count else {
            throw DiagramIOError.invalid("identifiants de pages dupliqués")
        }
        let total = document.pages.reduce(0) { $0 + $1.shapes.count }
        guard total <= maxShapes else { throw DiagramIOError.invalid("trop d'éléments") }
        for page in document.pages { try validate(page) }
    }

    static func validate(_ d: Diagram) throws {
        guard d.version >= 1, d.version <= Diagram.currentVersion else {
            throw DiagramIOError.unsupportedVersion(d.version)
        }
        guard d.shapes.count <= maxShapes, d.connectors.count <= maxConnectors else {
            throw DiagramIOError.invalid("trop d'éléments")
        }
        guard d.name.count <= maxNameLength else { throw DiagramIOError.invalid("nom de page trop long") }
        guard d.layers.count <= maxLayers else { throw DiagramIOError.invalid("trop de calques") }
        guard d.pageSetup.isValid else { throw DiagramIOError.invalid("taille de feuille invalide") }
        guard d.grid.isValid else { throw DiagramIOError.invalid("réglages de grille invalides") }
        guard d.scale.isFinite, Diagram.scaleRange.contains(d.scale), (0...4).contains(d.precision) else {
            throw DiagramIOError.invalid("réglages de page invalides")
        }
        guard d.guides.count <= Diagram.maxGuides,
              d.guides.allSatisfy({ $0.position.isFinite && abs($0.position) <= maxCoordinate }) else {
            throw DiagramIOError.invalid("repères invalides")
        }
        let layerIDs = Set(d.layers.map(\.id))
        guard layerIDs.count == d.layers.count else { throw DiagramIOError.invalid("identifiants de calques dupliqués") }
        guard d.layers.allSatisfy({ $0.name.count <= maxNameLength }) else {
            throw DiagramIOError.invalid("nom de calque trop long")
        }
        if let active = d.activeLayerID, !layerIDs.contains(active) {
            throw DiagramIOError.invalid("calque actif inconnu")
        }
        let shapeIDs = Set(d.shapes.map(\.id))
        guard shapeIDs.count == d.shapes.count else { throw DiagramIOError.invalid("identifiants de formes dupliqués") }
        guard Set(d.connectors.map(\.id)).count == d.connectors.count else {
            throw DiagramIOError.invalid("identifiants de connecteurs dupliqués")
        }
        for s in d.shapes {
            let r = s.rect
            let values = [r.origin.x, r.origin.y, r.size.width, r.size.height]
            guard values.allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }) else {
                throw DiagramIOError.invalid("coordonnées hors limites")
            }
            guard r.size.width > 0, r.size.height > 0 else { throw DiagramIOError.invalid("taille de forme nulle") }
            if let l = s.layerID, !layerIDs.contains(l) { throw DiagramIOError.invalid("calque inconnu") }
            guard s.points.count <= 16, s.points.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && abs($0.x) <= maxCoordinate && abs($0.y) <= maxCoordinate
            }) else { throw DiagramIOError.invalid("points invalides") }
            guard s.segments.count <= Shape.maxSegments, s.segments.allSatisfy({ seg in
                seg.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1000 && abs($0.y) <= 1000 }
            }) else { throw DiagramIOError.invalid("tracé invalide") }
            if s.kind.isPath {
                guard s.points.count == s.kind.pointCount else {
                    throw DiagramIOError.invalid("nombre de points incorrect")
                }
            }
            // Collage d'une cote : points et points de collage dans les bornes, un collage par point.
            // Une forme cible absente est tolérée : le collage est simplement abandonné au chargement.
            guard s.glue.isEmpty || s.kind.isDimension,
                  s.glue.count <= s.kind.gluePointIndices.count,
                  Set(s.glue.map(\.point)).count == s.glue.count,
                  s.glue.allSatisfy({ s.kind.gluePointIndices.contains($0.point)
                      && (0..<GluePoint.maxAnchors).contains($0.anchor) && $0.shape != s.id }) else {
                throw DiagramIOError.invalid("collage de cote invalide")
            }
            guard s.textOffset.x.isFinite, s.textOffset.y.isFinite,
                  abs(s.textOffset.x) <= maxCoordinate, abs(s.textOffset.y) <= maxCoordinate,
                  s.textBlockWidth.map({ $0.isFinite && Shape.textBlockWidthRange.contains($0) }) ?? true else {
                throw DiagramIOError.invalid("bloc de texte invalide")
            }
            guard s.textStyle.isValid else { throw DiagramIOError.invalid("style de texte invalide") }
            guard s.fillTransparency.isFinite, (0...1).contains(s.fillTransparency) else {
                throw DiagramIOError.invalid("transparence invalide")
            }
            guard s.line.isValid else { throw DiagramIOError.invalid("style de trait invalide") }
            guard s.rotation.isFinite, abs(s.rotation) <= 360 else { throw DiagramIOError.invalid("rotation invalide") }
            guard s.groupRotation.isFinite, abs(s.groupRotation) <= 360 else {
                throw DiagramIOError.invalid("rotation de groupe invalide")
            }
            guard [s.pin, s.groupPin].allSatisfy({ p in
                p.map { Shape.pinRange.contains($0.x) && Shape.pinRange.contains($0.y) } ?? true
            }) else { throw DiagramIOError.invalid("point de rotation invalide") }
            guard s.text.count <= maxTextLength else { throw DiagramIOError.invalid("texte trop long") }
            let c = [s.fill.r, s.fill.g, s.fill.b, s.fill.a]
            guard c.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
                throw DiagramIOError.invalid("couleur invalide")
            }
        }
        for c in d.connectors {
            guard shapeIDs.contains(c.fromShape), shapeIDs.contains(c.toShape) else {
                throw DiagramIOError.invalid("connecteur orphelin")
            }
            guard c.line.isValid else { throw DiagramIOError.invalid("style de connecteur invalide") }
            guard (0..<Port.count).contains(c.fromPort), (0..<Port.count).contains(c.toPort) else {
                throw DiagramIOError.invalid("point de connexion invalide")
            }
        }
    }
}
