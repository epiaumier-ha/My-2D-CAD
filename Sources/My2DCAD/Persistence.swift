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

    static func load(from url: URL) throws -> Diagram {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? Int, size > maxFileSize { throw DiagramIOError.fileTooLarge }
        let data = try Data(contentsOf: url)
        let diagram = try JSONDecoder().decode(Diagram.self, from: data)
        try validate(diagram)
        return diagram
    }

    static func save(_ diagram: Diagram, to url: URL) throws {
        try validate(diagram)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(diagram).write(to: url, options: .atomic)
    }

    static func validate(_ d: Diagram) throws {
        guard d.version >= 1, d.version <= Diagram.currentVersion else {
            throw DiagramIOError.unsupportedVersion(d.version)
        }
        guard d.shapes.count <= maxShapes, d.connectors.count <= maxConnectors else {
            throw DiagramIOError.invalid("trop d'éléments")
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
            guard (0..<Port.count).contains(c.fromPort), (0..<Port.count).contains(c.toPort) else {
                throw DiagramIOError.invalid("point de connexion invalide")
            }
        }
    }
}
