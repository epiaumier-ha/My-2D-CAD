import SwiftUI

// MARK: - Panneau de discussion

struct AssistantPanel: View {
    @ObservedObject private var session = AssistantSession.shared
    @State private var input = ""
    @State private var hasKey = KeychainStore.hasKey
    @FocusState private var inputFocused: Bool
    @AppStorage(PanelKey.assistant) private var showAssistant = false
    @AppStorage(AssistantProvider.storageKey) private var provider = AssistantProvider.automatic.rawValue

    /// Moteur qui traitera la prochaine demande, ou la raison pour laquelle aucun n'est utilisable.
    private var engine: Result<ResolvedEngine, AssistantError> {
        AssistantProvider.resolve(AssistantProvider(rawValue: provider) ?? .automatic, hasKey: hasKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            if case .failure(let error) = engine { unavailableNotice(error) }
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { hasKey = KeychainStore.hasKey }
        .onReceive(NotificationCenter.default.publisher(for: .assistantKeyChanged)) { _ in hasKey = KeychainStore.hasKey }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Label("Assistant", systemImage: "sparkles").font(.headline)
                if case .success(let e) = engine {
                    Text(e == .apple ? "Apple Intelligence · sur ce Mac" : "\(e.label) · en ligne")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(e == .apple ? "Modèle d'Apple embarqué : rien n'est envoyé sur Internet."
                                          : "Claude, via l'API d'Anthropic (clé API, facturé à l'usage).")
                }
            }
            Spacer()
            Button { session.clear() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("Nouvelle conversation")
                .disabled(session.entries.isEmpty)
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Réglages de l'assistant (moteur, clé API, modèle)")
            PanelCollapseButton(.assistant)
            Button { showAssistant = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Fermer le volet (⌥⌘I pour le rouvrir)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.entries.isEmpty { welcome }
                    ForEach(session.entries) { entry in
                        EntryView(entry: entry).id(entry.id)
                    }
                    if session.isWorking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("L'assistant travaille…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                }
                .padding(12)
            }
            .onChange(of: session.entries.count) { _, _ in
                if let last = session.entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: session.isWorking) { _, working in
                if working { withAnimation { proxy.scrollTo("working") } }
            }
        }
    }

    private var welcome: some View {
        Text("Décrivez ce que vous voulez dessiner ou modifier. Chaque demande s'annule en un ⌘Z.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func unavailableNotice(_ error: AssistantError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error.localizedDescription)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text("Ouvrir les réglages…") }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Votre demande…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
            if session.isWorking {
                Button { session.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .help("Interrompre")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? engine.get()) == nil)
                    .help("Envoyer (Entrée)")
            }
        }
        .padding(10)
    }

    private func send() {
        guard !session.isWorking else { return }
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        session.send(text)
    }
}

private struct EntryView: View {
    let entry: AssistantSession.Entry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.18)))
            }
        case .assistant:
            Text(entry.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action:
            Label(entry.text, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

extension Notification.Name {
    static let assistantKeyChanged = Notification.Name("My2DCAD.assistantKeyChanged")
}

// MARK: - Réglages

struct AssistantSettingsView: View {
    @AppStorage(AssistantModel.storageKey) private var model = AssistantModel.default.rawValue
    @AppStorage(AssistantProvider.storageKey) private var provider = AssistantProvider.automatic.rawValue
    private let appleStatus = AppleIntelligence.status
    @State private var keyInput = ""
    @State private var hasKey = KeychainStore.hasKey
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Picker("Moteur", selection: $provider) {
                    ForEach(AssistantProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                LabeledContent("Apple Intelligence") {
                    switch appleStatus {
                    case .available:
                        Label("Disponible", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable(let reason):
                        Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Moteur de l'assistant")
            } footer: {
                Text("Automatique : Claude si une clé API est enregistrée, sinon Apple Intelligence. Apple Intelligence fonctionne sur ce Mac, gratuitement et sans rien envoyer sur Internet, mais son modèle est plus petit : il convient aux demandes simples et aux petites pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if hasKey {
                    LabeledContent("Clé API") {
                        HStack {
                            Text("Enregistrée dans le trousseau").foregroundStyle(.secondary)
                            Button("Supprimer", role: .destructive) {
                                KeychainStore.deleteKey()
                                refresh("Clé supprimée.")
                            }
                        }
                    }
                } else {
                    SecureField("Clé API", text: $keyInput, prompt: Text("sk-ant-…"))
                    HStack {
                        Button("Enregistrer") {
                            let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard key.count >= 20, key.count <= 300, !key.contains(where: \.isWhitespace) else {
                                message = "Cette clé ne semble pas valide."
                                return
                            }
                            refresh(KeychainStore.saveKey(key) ? "Clé enregistrée." : "Impossible d'enregistrer la clé.")
                            keyInput = ""
                        }
                        .disabled(keyInput.isEmpty)
                        Link("Créer une clé…", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    }
                }
                Picker("Modèle", selection: $model) {
                    ForEach(AssistantModel.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Claude (Anthropic)")
            } footer: {
                Text("La clé reste dans le trousseau de votre Mac. Chaque demande envoie à Anthropic l'état de la page affichée ; l'utilisation de l'API est facturée par Anthropic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding()
    }

    private func refresh(_ text: String) {
        hasKey = KeychainStore.hasKey
        message = text
        NotificationCenter.default.post(name: .assistantKeyChanged, object: nil)
    }
}
