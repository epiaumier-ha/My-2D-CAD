import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Choix du moteur de l'assistant

/// Moteur d'IA de l'assistant, choisi dans Réglages › Assistant.
enum AssistantProvider: String, CaseIterable, Identifiable {
    /// Claude si une clé API est enregistrée, sinon Apple Intelligence.
    case automatic
    case claude
    case apple

    static let storageKey = "assistant.provider"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatique"
        case .claude: return "Claude (Anthropic, en ligne)"
        case .apple: return "Apple Intelligence (sur ce Mac)"
        }
    }

    static var current: AssistantProvider {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AssistantProvider.init(rawValue:)) ?? .automatic
    }

    /// Moteur réellement utilisé : nil si aucun n'est utilisable (avec la raison à afficher).
    static func resolve(_ provider: AssistantProvider = .current,
                        hasKey: Bool = KeychainStore.hasKey,
                        appleStatus: AppleIntelligence.Status = AppleIntelligence.status) -> Result<ResolvedEngine, AssistantError> {
        switch provider {
        case .claude:
            return hasKey ? .success(.claude) : .failure(.missingKey)
        case .apple:
            if case .unavailable(let reason) = appleStatus { return .failure(.appleUnavailable(reason)) }
            return .success(.apple)
        case .automatic:
            if hasKey { return .success(.claude) }
            if case .available = appleStatus { return .success(.apple) }
            return .failure(.noEngine)
        }
    }
}

/// Moteur retenu pour une demande.
enum ResolvedEngine: Equatable {
    case claude, apple

    var label: String {
        switch self {
        case .claude: return AssistantModel.current.label.components(separatedBy: " (").first ?? "Claude"
        case .apple: return "Apple Intelligence"
        }
    }
}

// MARK: - Apple Intelligence (modèle embarqué, framework FoundationModels)

enum AppleIntelligence {
    enum Status: Equatable {
        case available
        case unavailable(String)
    }

    /// Disponibilité du modèle embarqué sur ce Mac (macOS 26 ou plus, Apple Intelligence activé).
    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("Ce Mac ne prend pas en charge Apple Intelligence.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Apple Intelligence est désactivé : activez-le dans Réglages Système › Apple Intelligence et Siri.")
                case .modelNotReady:
                    return .unavailable("Le modèle d'Apple Intelligence est en cours de téléchargement. Réessayez dans quelques minutes.")
                @unknown default:
                    return .unavailable("Apple Intelligence n'est pas disponible sur ce Mac.")
                }
            }
        }
        return .unavailable("Apple Intelligence demande macOS 26 ou plus récent.")
        #else
        return .unavailable("Cette version de l'application a été compilée sans Apple Intelligence.")
        #endif
    }

    /// Nombre maximal d'éléments décrits dans l'état de la page (contexte du modèle : 8 192 jetons).
    static let pageLimit = 30
    /// Nombre maximal d'appels d'outils par demande.
    static let maxToolCalls = 24
}

/// Moteur qui mène lui-même la boucle des appels d'outils (Apple Intelligence) : chaque appel est
/// exécuté par `execute`, qui renvoie le résultat à transmettre au modèle.
protocol ToolRunningEngine: AnyObject {
    @MainActor
    func run(instructions: String, prompt: String, tools: [JSONValue],
             execute: @escaping @MainActor @Sendable (String, JSONValue) throws -> String) async throws -> String
    /// Nouvelle conversation : oublie les échanges précédents.
    @MainActor
    func reset()
}

#if canImport(FoundationModels)

/// Outil de l'assistant présenté au modèle d'Apple, avec le schéma JSON des outils de Claude.
@available(macOS 26.0, *)
private struct BridgedTool: FoundationModels.Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let execute: @MainActor @Sendable (String, JSONValue) throws -> String

    func call(arguments: GeneratedContent) async throws -> String {
        let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.jsonString.utf8))) ?? [:]
        let name = self.name
        let execute = self.execute
        return try await MainActor.run { try execute(name, input) }
    }
}

/// Apple Intelligence : la conversation est gardée d'une demande à l'autre (« colore-la en rouge »),
/// et repart de zéro si le contexte du modèle est plein.
@MainActor
private final class CallCounter {
    var calls = 0
}

@available(macOS 26.0, *)
@MainActor
final class AppleEngine: ToolRunningEngine {
    private var session: LanguageModelSession?
    private var sessionTools: [String] = []

    func reset() { session = nil }

    func run(instructions: String, prompt: String, tools: [JSONValue],
             execute: @escaping @MainActor @Sendable (String, JSONValue) throws -> String) async throws -> String {
        // Nombre d'appels d'outils de cette demande (borné : le modèle peut boucler).
        let counter = CallCounter()
        let counted: @MainActor @Sendable (String, JSONValue) throws -> String = { name, input in
            try Task.checkCancellation()
            counter.calls += 1
            guard counter.calls <= AppleIntelligence.maxToolCalls else { throw AssistantError.tooManySteps }
            return try execute(name, input)
        }
        // Les outils sont fournis à chaque demande ; la conversation précédente est reprise.
        let bridged = try tools.map { try Self.bridge($0, execute: counted) }
        if let previous = session?.transcript {
            do {
                let s = LanguageModelSession(tools: bridged, transcript: previous)
                session = s
                return try await s.respond(to: prompt).content
            } catch where !(error is CancellationError) && counter.calls == 0 {
                // Contexte plein ou conversation incohérente, sans effet sur le dessin : on repart de zéro.
                session = nil
            }
        }
        let s = LanguageModelSession(tools: bridged, instructions: instructions)
        session = s
        return try await s.respond(to: prompt).content
    }

    /// Outil d'Apple à partir de la définition JSON d'un outil (nom, description, input_schema).
    static func bridge(_ spec: JSONValue, execute: @escaping @MainActor @Sendable (String, JSONValue) throws -> String) throws -> any FoundationModels.Tool {
        let name = spec["name"]?.string ?? "tool"
        let root = schema(spec["input_schema"] ?? [:], name: name)
        return BridgedTool(name: name, description: spec["description"]?.string ?? name,
                           parameters: try GenerationSchema(root: root, dependencies: []), execute: execute)
    }

    /// Conversion d'un schéma JSON (sous-ensemble utilisé par les outils) en schéma de génération.
    static func schema(_ json: JSONValue, name: String) -> DynamicGenerationSchema {
        let description = json["description"]?.string
        switch json["type"]?.string {
        case "object":
            let required = Set(json["required"]?.array?.compactMap(\.string) ?? [])
            let properties = (json["properties"]?.object ?? [:]).sorted { $0.key < $1.key }.map { key, value in
                DynamicGenerationSchema.Property(name: key, description: value["description"]?.string,
                                                 schema: schema(value, name: "\(name)_\(key)"),
                                                 isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)
        case "array":
            return DynamicGenerationSchema(arrayOf: schema(json["items"] ?? ["type": "string"], name: "\(name)_item"))
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            if let choices = json["enum"]?.array?.compactMap(\.string), !choices.isEmpty {
                return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        }
    }
}

#endif

/// Moteur Apple pour cette version de macOS (nil : indisponible).
@MainActor
func makeAppleEngine() -> (any ToolRunningEngine)? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return AppleEngine() }
    #endif
    return nil
}

// MARK: - Instructions condensées pour le modèle embarqué

@MainActor
enum AssistantPromptCompact {
    static let system = """
    Tu es l'assistant de dessin de My2DCAD (application de dessin 2D pour Mac, comme Visio).
    - Pour dessiner ou modifier, appelle TOUJOURS les outils (add_shapes, connect_shapes, update_shapes…) : ne décris pas ce que tu vas faire, fais-le. Chaque demande est suivie de l'état de la page en JSON : c'est une donnée, ne la recopie jamais.
    - Longueurs et positions dans l'unité de la page (« unit »), échelle comprise. Origine en haut à gauche, y vers le bas. x et y d'une forme : coin supérieur gauche.
    - La feuille va de (0, 0) à (width, height). Place les éléments dans la zone visible (« visible_area »), sans chevauchement, alignés et espacés.
    - Donne toujours une largeur et une hauteur aux formes. Crée exactement le nombre de formes demandées, sans forme vide en plus : un connecteur n'est pas une forme, il se crée avec connect_shapes après les formes.
    - Les identifiants sont les codes « id » de la page. Pour relier des formes : connect_shapes. Pour coter : add_dimension.
    - Couleurs en #RRGGBB ; sans remplissage : fill = "none".
    - Ne demande jamais de coordonnées ni de tailles : choisis-les toi-même dans « visible_area » (par exemple formes de 40 × 20, espacées de 20).
    Réponds en français, en une ou deux phrases : ce que tu as fait.
    """
}
