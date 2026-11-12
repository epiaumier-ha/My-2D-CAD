import Foundation
import Security

// MARK: - Valeur JSON quelconque (requêtes et réponses de l'API, paramètres des outils)

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .number(let d): try c.encode(d.isFinite ? d : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .number(let d): return d.isFinite ? d : nil
        default: return nil
        }
    }

    /// Texte JSON compact (clés triées).
    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Moteurs d'IA

/// Réponse d'un moteur : blocs de contenu au format de l'API Messages (texte, appels d'outils).
struct EngineReply: Sendable {
    var content: [JSONValue]
    var stopReason: String?
}

protocol AssistantEngine: Sendable {
    func respond(system: String, messages: [JSONValue], tools: [JSONValue]) async throws -> EngineReply
}

enum AssistantError: LocalizedError {
    case missingKey
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Aucune clé API : ajoutez-la dans Réglages (⌘,) › Assistant."
        case .http(let status, let message):
            switch status {
            case 401: return "Clé API refusée. Vérifiez-la dans Réglages (⌘,)."
            case 429: return "Limite d'utilisation de l'API atteinte. Réessayez dans un moment."
            case 529, 503: return "Le service Claude est surchargé. Réessayez dans un moment."
            default: return "Erreur de l'API (\(status)) : \(message)"
            }
        case .invalidResponse:
            return "Réponse de l'API illisible."
        }
    }
}

/// Modèles Claude proposés dans les réglages.
enum AssistantModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    case haiku = "claude-haiku-5-5"

    static let storageKey = "assistant.model"
    static let `default` = AssistantModel.sonnet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sonnet: return "Claude Sonnet 5.5 (recommandé)"
        case .opus: return "Claude Opus 5.5 (plus puissant, plus cher)"
        case .haiku: return "Claude Haiku 5.5 (rapide, économique)"
        }
    }

    static var current: AssistantModel {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AssistantModel.init(rawValue:)) ?? .default
    }
}

/// Claude via l'API Messages d'Anthropic.
struct ClaudeEngine: AssistantEngine {
    let apiKey: String
    let model: String

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxResponseBytes = 8_000_000

    func respond(system: String, messages: [JSONValue], tools: [JSONValue]) async throws -> EngineReply {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // Mise en cache des instructions et des outils (identiques d'une requête à l'autre).
        var cachedTools = tools
        if case .object(var last)? = cachedTools.last {
            last["cache_control"] = ["type": "ephemeral"]
            cachedTools[cachedTools.count - 1] = .object(last)
        }
        let body: JSONValue = [
            "model": .string(model),
            "max_tokens": 8192,
            "system": [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]],
            "tools": .array(cachedTools),
            "messages": .array(messages),
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= Self.maxResponseBytes else {
            throw AssistantError.invalidResponse
        }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            let message = json?["error"]?["message"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AssistantError.http(http.statusCode, String(message.prefix(300)))
        }
        guard let content = json?["content"]?.array else { throw AssistantError.invalidResponse }
        return EngineReply(content: content, stopReason: json?["stop_reason"]?.string)
    }
}

// MARK: - Trousseau (clé API)

enum KeychainStore {
    private static let service = "My2DCAD.assistant"
    private static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func readKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        deleteKey()
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static var hasKey: Bool { readKey() != nil }
}
