import Foundation
import SwiftUI

// MARK: - Conversation avec l'assistant

@MainActor
final class AssistantSession: ObservableObject {
    static let shared = AssistantSession()

    struct Entry: Identifiable, Equatable {
        enum Kind { case user, assistant, action, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isWorking = false

    /// Historique au format de l'API Messages.
    private var messages: [JSONValue] = []
    /// Indices des messages qui ouvrent un échange (demande de l'utilisateur).
    private var turnStarts: [Int] = []
    private var task: Task<Void, Never>?

    static let maxRounds = 16
    static let maxMessages = 60
    static let maxRequestLength = 4000

    let store: DocumentStore

    init(store: DocumentStore? = nil) {
        self.store = store ?? .shared
    }

    /// Moteur d'une demande : boucle d'outils menée par la session (Claude) ou par le moteur (Apple).
    private enum Backend {
        case messages(any AssistantEngine)
        case tools(any ToolRunningEngine)
    }

    /// Moteur Apple Intelligence, gardé d'une demande à l'autre (il garde la conversation).
    private var appleEngine: (any ToolRunningEngine)?
    /// Moteur utilisé pour la dernière demande (affiché dans le volet).
    @Published private(set) var lastEngine: ResolvedEngine?

    /// Envoie une demande. `engine` / `toolEngine` : moteur imposé (tests) ; sinon, réglage de l'utilisateur.
    func send(_ text: String, engine: (any AssistantEngine)? = nil, toolEngine: (any ToolRunningEngine)? = nil) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, !request.isEmpty else { return }
        guard request.count <= Self.maxRequestLength else {
            entries.append(Entry(kind: .error, text: "Demande trop longue (\(Self.maxRequestLength) caractères au plus)."))
            return
        }
        let backend: Backend
        if let engine {
            backend = .messages(engine)
        } else if let toolEngine {
            backend = .tools(toolEngine)
        } else {
            switch AssistantProvider.resolve() {
            case .success(.claude):
                guard let key = KeychainStore.readKey() else {
                    entries.append(Entry(kind: .error, text: AssistantError.missingKey.localizedDescription))
                    return
                }
                backend = .messages(ClaudeEngine(apiKey: key, model: AssistantModel.current.rawValue))
                lastEngine = .claude
            case .success(.apple):
                if appleEngine == nil { appleEngine = makeAppleEngine() }
                guard let apple = appleEngine else {
                    entries.append(Entry(kind: .error, text: AssistantError.appleUnavailable(
                        "Apple Intelligence n'est pas disponible sur ce Mac.").localizedDescription))
                    return
                }
                backend = .tools(apple)
                lastEngine = .apple
            case .failure(let error):
                entries.append(Entry(kind: .error, text: error.localizedDescription))
                return
            }
        }
        store.endTextEditing()
        entries.append(Entry(kind: .user, text: request))
        trimHistory()
        turnStarts.append(messages.count)
        // Modèle embarqué : contexte réduit, la page est décrite plus brièvement.
        let limit: Int
        if case .tools = backend { limit = AppleIntelligence.pageLimit } else { limit = 300 }
        let page = AssistantToolbox(store: store).pageState(limit: limit).jsonText
        let prompt = "<page>\n\(page)\n</page>\n\n\(request)"
        messages.append(["role": "user", "content": [["type": "text", "text": .string(prompt)]]])
        // Modèle embarqué : la demande d'abord, puis l'état de la page, présenté comme une donnée
        // (sinon le petit modèle a tendance à le recopier au lieu d'appeler les outils).
        let applePrompt = "Demande : \(request)\n\nÉtat actuel de la page (données JSON, ne pas recopier) : \(page)"
        isWorking = true
        switch backend {
        case .messages(let e): task = Task { await self.run(e) }
        case .tools(let e): task = Task { await self.runTools(e, prompt: applePrompt) }
        }
    }

    func stop() { task?.cancel() }

    func clear() {
        stop()
        appleEngine?.reset()
        entries = []
        messages = []
        turnStarts = []
    }

    private func run(_ engine: any AssistantEngine) async {
        let toolbox = AssistantToolbox(store: store)
        let turnStart = turnStarts.last ?? messages.count
        let shapesBefore = Set(store.doc.shapes.map(\.id))
        store.beginAssistantEdit()
        defer {
            store.endAssistantEdit()
            isWorking = false
            task = nil
        }
        do {
            var finished = false
            for _ in 0..<Self.maxRounds {
                let reply = try await engine.respond(system: AssistantPrompt.system, messages: messages,
                                                     tools: AssistantToolbox.specs)
                try Task.checkCancellation()
                messages.append(["role": "assistant", "content": .array(reply.content)])
                var results: [JSONValue] = []
                for block in reply.content {
                    switch block["type"]?.string ?? "" {
                    case "text":
                        if let t = block["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            entries.append(Entry(kind: .assistant, text: t))
                        }
                    case "tool_use":
                        let name = block["name"]?.string ?? ""
                        let outcome = toolbox.run(name, block["input"] ?? [:])
                        if let summary = outcome.summary { entries.append(Entry(kind: .action, text: summary)) }
                        results.append([
                            "type": "tool_result",
                            "tool_use_id": block["id"] ?? "",
                            "content": .string(outcome.result),
                            "is_error": .bool(outcome.isError),
                        ])
                    default:
                        break
                    }
                }
                if results.isEmpty {
                    finished = true
                    break
                }
                messages.append(["role": "user", "content": .array(results)])
            }
            if !finished {
                entries.append(Entry(kind: .error, text: "L'assistant a atteint le nombre maximal d'étapes pour cette demande."))
                rollBack(to: turnStart)
            }
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            entries.append(Entry(kind: .error, text: cancelled ? "Demande interrompue." : error.localizedDescription))
            rollBack(to: turnStart)
        }
        reveal(shapesAddedSince: shapesBefore)
    }

    /// Moteur qui mène lui-même les appels d'outils (Apple Intelligence) : chaque appel passe par la
    /// même boîte à outils validée que Claude ; toute la réponse forme une seule étape d'annulation.
    private func runTools(_ engine: any ToolRunningEngine, prompt: String) async {
        let toolbox = AssistantToolbox(store: store)
        let turnStart = turnStarts.last ?? messages.count
        let shapesBefore = Set(store.doc.shapes.map(\.id))
        store.beginAssistantEdit()
        defer {
            store.endAssistantEdit()
            isWorking = false
            task = nil
        }
        do {
            let reply = try await engine.run(instructions: AssistantPromptCompact.system, prompt: prompt,
                                             tools: AssistantToolbox.compactSpecs) { [weak self] name, input in
                let outcome = toolbox.run(name, input)
                if let summary = outcome.summary { self?.entries.append(Entry(kind: .action, text: summary)) }
                return outcome.isError ? "Erreur : \(outcome.result)" : outcome.result
            }
            try Task.checkCancellation()
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { entries.append(Entry(kind: .assistant, text: text)) }
            messages.append(["role": "assistant", "content": [["type": "text", "text": .string(text.isEmpty ? "C'est fait." : text)]]])
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            entries.append(Entry(kind: .error, text: cancelled ? "Demande interrompue." : Self.describe(error)))
            rollBack(to: turnStart)
        }
        reveal(shapesAddedSince: shapesBefore)
    }

    /// Message d'erreur lisible (les erreurs du modèle embarqué sont parfois peu explicites).
    private static func describe(_ error: Error) -> String {
        if let e = error as? AssistantError { return e.localizedDescription }
        let text = error.localizedDescription
        let raw = String(describing: error)
        if raw.contains("guardrail") || raw.contains("Guardrail") {
            return "Apple Intelligence a refusé cette demande (filtre de sécurité). Reformulez-la."
        }
        if raw.contains("ontext") && (raw.contains("xceeded") || raw.contains("Size")) {
            return "La demande ou la page est trop grande pour Apple Intelligence. Utilisez Claude pour les grandes pages."
        }
        return text
    }

    /// Nouvelles formes hors de la vue : on ajuste le zoom pour les montrer.
    private func reveal(shapesAddedSince before: Set<UUID>) {
        let added = store.doc.shapes.filter { !before.contains($0.id) }
        guard !added.isEmpty else { return }
        let view = CGRect(origin: store.toWorld(.zero),
                          size: CGSize(width: store.canvasSize.width / store.zoom, height: store.canvasSize.height / store.zoom))
        if added.contains(where: { !view.contains($0.bounds) }) { store.fitToContent() }
    }

    /// Échange interrompu : l'historique repart d'un état cohérent (le dessin, lui, garde les modifications).
    private func rollBack(to index: Int) {
        guard index <= messages.count else { return }
        messages.removeSubrange(index...)
        turnStarts.removeAll { $0 >= index }
    }

    /// Garde l'historique raisonnable : on oublie les plus anciens échanges entiers.
    private func trimHistory() {
        while messages.count > Self.maxMessages, turnStarts.count > 1 {
            let cut = turnStarts[1]
            messages.removeSubrange(0..<cut)
            turnStarts = turnStarts.dropFirst().map { $0 - cut }
        }
    }
}

// MARK: - Instructions de l'assistant

@MainActor
enum AssistantPrompt {
    static let system: String = {
        let shapes = AssistantToolbox.shapeTypes.map { "\($0.rawValue) (\($0.displayName))" }.joined(separator: ", ")
        let tools = Tool.allCases.map { $0.labelWithShortcut }.joined(separator: ", ")
        return """
        Tu es l'assistant de dessin intégré à My2DCAD, une application de dessin 2D (CAO) pour Mac inspirée de Microsoft Visio.
        Tu aides l'utilisateur à créer et modifier ses dessins, à analyser ses schémas et à utiliser l'application.

        Fonctionnement :
        - Tu agis sur le dessin uniquement avec les outils fournis. Chaque demande de l'utilisateur forme une seule étape d'annulation (⌘Z).
        - Chaque demande commence par l'état de la page (<page>) : unité, échelle, zone visible, calques, éléments et sélection. Les identifiants sont les codes courts « id ».
        - Toutes les longueurs et positions sont dans l'unité de la page (« unit »), échelle comprise : ce sont des mesures réelles. Exemple : à l'échelle 1:100 en mm, un mur de 5 m mesure 5000.
        - Origine en haut à gauche, axe Y vers le bas ; x et y d'une forme désignent son coin supérieur gauche.
        - La feuille (« sheet ») va de (0, 0) à (width, height) : c'est la partie imprimée. Place le dessin sur la feuille ; s'il ne tient pas, change d'échelle ou de format avec set_page.
        - Si une taille demandée est sans commune mesure avec la zone visible (plus de 20 fois plus grande ou plus petite), choisis une échelle adaptée avec set_page avant de dessiner et dis-le.
        - Place les nouveaux éléments dans la zone visible, sans chevaucher l'existant, alignés et régulièrement espacés. Organigramme : de haut en bas, formes de même taille, connecteurs entre elles.
        - Une forme sans remplissage : fill = "none". Couleurs en #RRGGBB.
        - Pour coter une forme, utilise add_dimension : la cote reste collée à la forme.
        - Si la demande est ambiguë au point de risquer un dessin inutile, pose une question courte au lieu d'agir.
        - Pour analyser un schéma, appuie-toi sur l'état de la page (formes non reliées, textes manquants, incohérences) et propose des corrections sans les appliquer, sauf si on te le demande.

        Types de formes disponibles pour add_shapes : \(shapes).

        Aide sur l'application :
        - Outils (raccourcis) : \(tools). Échap revient au pointeur ; Espace maintenu fait glisser la vue.
        - Bibliothèques de formes à gauche (organigramme, réseau, électricité, cotation) : glisser une forme sur la page.
        - Ruban en haut, comme Visio : Fichier (ouvrir, enregistrer, exporter, imprimer), Accueil (presse-papiers, police, outils, styles de forme, organiser), Insertion (pages, SVG, connecteurs, cotes, formes, texte), Création (feuille : format A5 à A2 ou personnalisé, orientation, ajuster au dessin ; unité, échelle, décimales ; connecteurs ; calques), Affichage (règles, grille, repères, volets, zoom), Développeur (opérations sur les formes, grouper, comportement).
        - Volet « Format de la forme » à droite (remplissage, trait, texte, taille et position) ; sans sélection, il présente la page et la feuille. Volet Formes à gauche (⌥⌘1), volet Format (⌥⌘2), assistant (⌥⌘I).
        - Menus de la barre des menus : Fichier, Édition, Affichage, Insertion, Forme (aligner, répartir, pivoter, grouper ⌘G, ordre, opérations), Outils, Page. Le PDF et l'impression reprennent la feuille ; le PNG et le SVG, le dessin.
        - Double-clic sur une forme pour modifier son texte ; le losange jaune déplace le bloc de texte.
        - Cotes : bibliothèque « Cotation » ; glisser une extrémité sur un coin, un milieu ou le centre d'une forme la colle.

        Réponds en français, en une à trois phrases : ce que tu as fait, ou la réponse à la question. Pas de liste des appels d'outils.
        """
    }()
}
