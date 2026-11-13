import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Modèle : gabarits personnels (« Mes formes »)

/// Forme de base d'un gabarit personnel : formes (styles, texte, cotes) et connecteurs internes,
/// ramenés à l'origine. Plusieurs formes se posent comme un seul groupe, comme dans Visio.
struct UserMaster: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var fragment: ClipboardFragment

    /// Cadre englobant (rotation comprise) ; l'origine est en (0, 0) après normalisation.
    var bounds: CGRect {
        guard let first = fragment.shapes.first else { return .zero }
        return fragment.shapes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    /// Forme de base créée à partir d'une sélection : calques retirés, collages et connecteurs
    /// limités aux formes copiées, plusieurs formes réunies en un groupe, cadre ramené à l'origine.
    static func make(name: String, from fragment: ClipboardFragment) -> UserMaster? {
        guard !fragment.shapes.isEmpty else { return nil }
        let ids = Set(fragment.shapes.map(\.id))
        var shapes = fragment.shapes
        // Une sélection qui forme déjà un seul groupe garde son angle et son point de rotation.
        let groups = Set(shapes.map(\.groupID))
        let singleGroup = shapes.count > 1 && groups.count == 1 && groups.first! != nil
        let newGroup = UUID()
        for i in shapes.indices {
            shapes[i].layerID = nil
            shapes[i].glue = shapes[i].glue.filter { ids.contains($0.shape) }
            if shapes.count == 1 {
                shapes[i].groupID = nil
                shapes[i].groupRotation = 0
                shapes[i].groupPin = nil
            } else if !singleGroup {
                shapes[i].groupID = newGroup
                shapes[i].groupRotation = 0
                shapes[i].groupPin = nil
            }
        }
        let connectors = fragment.connectors.filter { ids.contains($0.fromShape) && ids.contains($0.toShape) }
            .map { c -> Connector in
                var copy = c
                if let a = c.afterShape, !ids.contains(a) { copy.afterShape = nil }
                return copy
            }
        var master = UserMaster(name: name, fragment: ClipboardFragment(shapes: shapes, connectors: connectors))
        let b = master.bounds
        for i in master.fragment.shapes.indices {
            master.fragment.shapes[i].rect.origin.x -= b.minX
            master.fragment.shapes[i].rect.origin.y -= b.minY
        }
        return master
    }

    /// Nom proposé : le texte de la forme, sinon son type (comme le nom de forme de base de Visio).
    static func defaultName(for shapes: [Shape]) -> String {
        if shapes.count == 1, let s = shapes.first {
            let text = s.text.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !text.isEmpty { return String(text.prefix(60)) }
            return s.kind.displayName
        }
        return "Groupe de \(shapes.count) formes"
    }

    /// Fragment placé avec le coin haut-gauche de son cadre en `origin`.
    func fragment(at origin: CGPoint) -> ClipboardFragment {
        var f = fragment
        let b = bounds
        for i in f.shapes.indices {
            f.shapes[i].rect.origin.x += origin.x - b.minX
            f.shapes[i].rect.origin.y += origin.y - b.minY
        }
        return f
    }
}

/// Gabarit personnel : un fichier par gabarit dans Documents/Mes formes, comme les .vssx de Visio.
struct UserStencil: Codable, Identifiable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var id = UUID()
    var name: String
    var masters: [UserMaster] = []
}

// MARK: - Lecture / écriture

enum UserStencilIO {
    static let fileExtension = "cad2dstencil"
    static let maxFileSize = 50 * 1024 * 1024
    static let maxMasters = 500
    static let maxShapesPerMaster = 2_000
    static let maxShapesPerStencil = 20_000

    /// Un gabarit est une donnée non fiable (fichier copié, reçu par courriel…) : tout est contrôlé.
    static func validate(_ s: UserStencil) throws {
        guard s.version == UserStencil.currentVersion else {
            throw DiagramIOError.unsupportedVersion(s.version)
        }
        let name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, s.name.count <= DiagramIO.maxNameLength else {
            throw DiagramIOError.invalid("nom de gabarit incorrect")
        }
        guard s.masters.count <= maxMasters else { throw DiagramIOError.invalid("trop de formes dans le gabarit") }
        guard Set(s.masters.map(\.id)).count == s.masters.count else {
            throw DiagramIOError.invalid("identifiants de formes dupliqués")
        }
        let total = s.masters.reduce(0) { $0 + $1.fragment.shapes.count }
        guard total <= maxShapesPerStencil else { throw DiagramIOError.invalid("gabarit trop volumineux") }
        for m in s.masters {
            guard !m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  m.name.count <= DiagramIO.maxNameLength else {
                throw DiagramIOError.invalid("nom de forme incorrect")
            }
            guard (1...maxShapesPerMaster).contains(m.fragment.shapes.count) else {
                throw DiagramIOError.invalid("forme vide ou trop complexe")
            }
            // Même contrôle qu'une page : coordonnées, styles, connecteurs, collages…
            try DiagramIO.validate(Diagram(shapes: m.fragment.shapes, connectors: m.fragment.connectors))
        }
    }

    static func load(from url: URL) throws -> UserStencil {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? Int, size > maxFileSize { throw DiagramIOError.fileTooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileSize else { throw DiagramIOError.fileTooLarge }
        let stencil = try JSONDecoder().decode(UserStencil.self, from: data)
        try validate(stencil)
        return stencil
    }

    static func save(_ stencil: UserStencil, to url: URL) throws {
        try validate(stencil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stencil).write(to: url, options: .atomic)
    }

    /// Nom de fichier tiré du nom du gabarit (sans séparateur de chemin ni fichier caché).
    static func fileName(for name: String) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .filter { !$0.isNewline && $0 != "\0" }
            .trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(100)).trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Gabarit" : base
    }
}

// MARK: - Bibliothèque « Mes formes »

@MainActor
final class UserStencilLibrary: ObservableObject {
    static let shared = UserStencilLibrary(directory: defaultDirectory)

    /// Documents/Mes formes, comme Visio.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mes formes", isDirectory: true)
    }

    static let dragPrefix = "my2dcad.usermaster:"

    struct Entry: Identifiable, Equatable {
        var stencil: UserStencil
        var url: URL
        var id: UUID { stencil.id }
    }

    let directory: URL
    @Published private(set) var entries: [Entry] = []
    /// Fichiers illisibles du dossier (nom et raison), signalés dans le volet.
    @Published private(set) var loadErrors: [String] = []
    /// Gabarit survolé pendant qu'on y fait glisser une sélection du dessin.
    @Published var dropTargetID: UUID?
    private var loaded = false

    /// Cadres (coordonnées de la fenêtre) des gabarits du volet, et zone visible du volet,
    /// cibles d'une sélection glissée depuis le dessin.
    var dropFrames: [UUID: CGRect] = [:]
    var panelFrame: CGRect = .zero

    init(directory: URL) {
        self.directory = directory
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        reload()
    }

    /// Relit le dossier : chaque fichier est validé ; les fichiers invalides sont ignorés et signalés.
    func reload() {
        loaded = true
        var result: [Entry] = []
        var errors: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        for url in files where url.pathExtension == UserStencilIO.fileExtension {
            do {
                var stencil = try UserStencilIO.load(from: url)
                // Fichier copié : même identifiant qu'un autre gabarit.
                if result.contains(where: { $0.id == stencil.id }) { stencil.id = UUID() }
                result.append(Entry(stencil: stencil, url: url))
            } catch {
                errors.append("\(url.lastPathComponent) : \(error.localizedDescription)")
            }
        }
        entries = result.sorted { $0.stencil.name.localizedStandardCompare($1.stencil.name) == .orderedAscending }
        loadErrors = errors
    }

    func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    private func uniqueURL(for name: String, excluding current: URL? = nil) -> URL {
        let base = UserStencilIO.fileName(for: name)
        var n = 1
        while true {
            let file = n == 1 ? base : "\(base) \(n)"
            let url = directory.appendingPathComponent(file).appendingPathExtension(UserStencilIO.fileExtension)
            if url == current || !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    private func write(_ stencil: UserStencil, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try UserStencilIO.save(stencil, to: url)
    }

    private func replace(_ entry: Entry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry } else { entries.append(entry) }
        entries.sort { $0.stencil.name.localizedStandardCompare($1.stencil.name) == .orderedAscending }
    }

    /// Nouveau gabarit vide (Visio : Plus de formes › Nouveau gabarit).
    @discardableResult
    func createStencil(named name: String) throws -> UUID {
        loadIfNeeded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stencil = UserStencil(name: trimmed.isEmpty ? "Gabarit" : trimmed)
        let url = uniqueURL(for: stencil.name)
        try write(stencil, to: url)
        replace(Entry(stencil: stencil, url: url))
        return stencil.id
    }

    /// Renomme le gabarit et son fichier.
    func renameStencil(_ id: UUID, to name: String) throws {
        guard var e = entry(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != e.stencil.name else { return }
        e.stencil.name = trimmed
        let newURL = uniqueURL(for: trimmed, excluding: e.url)
        try write(e.stencil, to: newURL)
        if newURL != e.url { try? FileManager.default.removeItem(at: e.url) }
        e.url = newURL
        replace(e)
    }

    /// Supprime un gabarit : son fichier va à la Corbeille (récupérable).
    func deleteStencil(_ id: UUID) throws {
        guard let e = entry(id) else { return }
        if FileManager.default.fileExists(atPath: e.url.path) {
            try FileManager.default.trashItem(at: e.url, resultingItemURL: nil)
        }
        entries.removeAll { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout UserStencil) throws -> Void) throws {
        guard var e = entry(id) else { return }
        try change(&e.stencil)
        try write(e.stencil, to: e.url)
        replace(e)
    }

    /// Ajoute une forme de base au gabarit (fragment de la sélection) ; renvoie son identifiant.
    @discardableResult
    func addMaster(_ fragment: ClipboardFragment, name: String, to id: UUID) throws -> UUID? {
        guard let master = UserMaster.make(name: name, from: fragment) else { return nil }
        guard fragment.shapes.count <= UserStencilIO.maxShapesPerMaster else {
            throw DiagramIOError.invalid("sélection trop grande pour une forme de gabarit")
        }
        try update(id) { $0.masters.append(master) }
        return master.id
    }

    func renameMaster(_ masterID: UUID, in id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try update(id) { s in
            if let i = s.masters.firstIndex(where: { $0.id == masterID }) { s.masters[i].name = trimmed }
        }
    }

    func deleteMaster(_ masterID: UUID, in id: UUID) throws {
        try update(id) { $0.masters.removeAll { $0.id == masterID } }
    }

    /// Ouvre un gabarit reçu d'ailleurs : il est validé puis copié dans Mes formes.
    @discardableResult
    func importStencil(from url: URL) throws -> UUID {
        loadIfNeeded()
        var stencil = try UserStencilIO.load(from: url)
        if entries.contains(where: { $0.id == stencil.id }) { stencil.id = UUID() }
        let dest = uniqueURL(for: stencil.name)
        try write(stencil, to: dest)
        replace(Entry(stencil: stencil, url: dest))
        return stencil.id
    }

    // MARK: Glisser-déposer

    static func dragPayload(stencil: UUID, master: UUID) -> String {
        dragPrefix + stencil.uuidString + "/" + master.uuidString
    }

    /// Les données glissées peuvent venir d'une autre application : seul un identifiant connu est accepté.
    func master(fromDragPayload payload: String) -> UserMaster? {
        guard payload.count <= 100, payload.hasPrefix(Self.dragPrefix) else { return nil }
        let parts = payload.dropFirst(Self.dragPrefix.count).split(separator: "/")
        guard parts.count == 2, let s = UUID(uuidString: String(parts[0])),
              let m = UUID(uuidString: String(parts[1])) else { return nil }
        return entry(s)?.stencil.masters.first { $0.id == m }
    }

    /// Gabarit du volet sous un point de la fenêtre (sélection glissée depuis le dessin).
    func dropTarget(at windowPoint: CGPoint) -> UUID? {
        guard panelFrame.contains(windowPoint) else { return nil }
        return dropFrames.first { entry($0.key) != nil && $0.value.contains(windowPoint) }?.key
    }
}

// MARK: - Insertion dans le dessin

@MainActor
extension DocumentStore {
    /// Pose une forme de Mes formes centrée sur un point (une étape d'annulation).
    @discardableResult
    func insertUserMaster(_ master: UserMaster, centeredAt center: CGPoint) -> Bool {
        let limit = DiagramIO.maxCoordinate / 2
        guard center.x.isFinite, center.y.isFinite, abs(center.x) < limit, abs(center.y) < limit else { return false }
        let size = master.bounds.size
        let origin = snap(CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        endTextEditing()
        activeStencil = nil
        tool = .select
        return insertFragment(master.fragment(at: origin), offset: 0)
    }

    /// Ajoute la sélection au gabarit (bouton « + » ou sélection glissée sur le gabarit).
    @discardableResult
    func addSelection(to stencilID: UUID) throws -> UUID? {
        try addSelection(to: stencilID, library: .shared)
    }

    @discardableResult
    func addSelection(to stencilID: UUID, library: UserStencilLibrary) throws -> UUID? {
        guard let fragment = makeFragment() else { return nil }
        return try library.addMaster(fragment, name: UserMaster.defaultName(for: fragment.shapes), to: stencilID)
    }
}

// MARK: - Volet

/// Rubrique « Mes formes » du volet Formes.
struct UserStencilsSection: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var library: UserStencilLibrary
    let search: String
    @Binding var open: Set<String>

    private static let sectionKey = "mes-formes"

    var body: some View {
        DisclosureGroup(isExpanded: expanded(Self.sectionKey)) {
            VStack(alignment: .leading, spacing: 6) {
                if library.entries.isEmpty {
                    Text("Créez un gabarit, puis glissez-y une sélection du dessin ou cliquez sur « + ».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(library.entries) { e in
                    let masters = filtered(e.stencil.masters)
                    if search.isEmpty || !masters.isEmpty {
                        stencilGroup(e, masters: masters)
                    }
                }
                ForEach(library.loadErrors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6)
        } label: {
            HStack {
                Label("Mes formes", systemImage: "person.crop.square").font(.headline)
                Spacer()
                Menu {
                    Button("Nouveau gabarit…") { newStencil() }
                    Button("Ouvrir un gabarit…") { importStencil() }
                    Divider()
                    Button("Afficher le dossier dans le Finder") { revealFolder() }
                    Button("Actualiser") { library.reload() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Gabarits personnels (Documents/Mes formes)")
            }
        }
        .onAppear { library.loadIfNeeded() }
    }

    private func stencilGroup(_ e: UserStencilLibrary.Entry, masters: [UserMaster]) -> some View {
        let target = library.dropTargetID == e.id
        return DisclosureGroup(isExpanded: expanded(e.id.uuidString)) {
            if masters.isEmpty {
                Text("Gabarit vide : glissez-y une sélection du dessin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 4)], spacing: 4) {
                    ForEach(masters) { UserMasterTile(stencilID: e.id, master: $0, library: library) }
                }
                .padding(.vertical, 4)
            }
        } label: {
            HStack {
                Label(e.stencil.name, systemImage: "square.on.square").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    perform { try store.addSelection(to: e.id, library: library) }
                    open.insert(e.id.uuidString)
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(store.selection.isEmpty || store.selectedShapes.isEmpty)
                .help("Ajouter la sélection à « \(e.stencil.name) »")
            }
            .contextMenu {
                Button("Renommer le gabarit…") {
                    if let name = UserStencilPrompt.text(title: "Renommer le gabarit", value: e.stencil.name) {
                        perform { try library.renameStencil(e.id, to: name) }
                    }
                }
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
                Divider()
                Button("Supprimer le gabarit…", role: .destructive) { deleteStencil(e) }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(target ? Color.accentColor.opacity(0.15) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(target ? Color.accentColor : .clear, lineWidth: 1.5))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { library.dropFrames[e.id] = $0 }
        .onDisappear { library.dropFrames[e.id] = nil }
    }

    private func filtered(_ masters: [UserMaster]) -> [UserMaster] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return masters }
        return masters.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !search.isEmpty || open.contains(id) },
            set: { isOpen in
                if isOpen { open.insert(id) } else { open.remove(id) }
            })
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { UserStencilPrompt.error(error) }
    }

    private func newStencil() {
        guard let name = UserStencilPrompt.text(title: "Nouveau gabarit", value: "Mes formes") else { return }
        perform {
            let id = try library.createStencil(named: name)
            open.insert(Self.sectionKey)
            open.insert(id.uuidString)
        }
    }

    private func importStencil() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: UserStencilIO.fileExtension) ?? .json]
        panel.message = "Choisissez un gabarit My2DCAD : il sera copié dans Documents/Mes formes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let id = try library.importStencil(from: url)
            open.insert(Self.sectionKey)
            open.insert(id.uuidString)
        }
    }

    private func revealFolder() {
        perform {
            try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(library.directory)
        }
    }

    private func deleteStencil(_ e: UserStencilLibrary.Entry) {
        let alert = NSAlert()
        alert.messageText = "Supprimer le gabarit « \(e.stencil.name) » ?"
        alert.informativeText = "Le fichier est placé dans la Corbeille. Les formes déjà posées dans vos dessins ne changent pas."
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try library.deleteStencil(e.id) }
    }
}

private struct UserMasterTile: View {
    @EnvironmentObject var store: DocumentStore
    let stencilID: UUID
    let master: UserMaster
    @ObservedObject var library: UserStencilLibrary

    var body: some View {
        VStack(spacing: 3) {
            UserMasterPreview(master: master).frame(width: 54, height: 40)
            Text(master.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(4)
        .contentShape(Rectangle())
        .help("\(master.name) : glissez-la sur le dessin")
        .draggable(UserStencilLibrary.dragPayload(stencil: stencilID, master: master.id)) {
            UserMasterPreview(master: master).frame(width: 64, height: 48)
        }
        .contextMenu {
            Button("Insérer au centre de la vue") { store.insertUserMaster(master, centeredAt: store.visibleCenter) }
            Button("Renommer la forme…") {
                if let name = UserStencilPrompt.text(title: "Renommer la forme", value: master.name) {
                    run { try library.renameMaster(master.id, in: stencilID, to: name) }
                }
            }
            Divider()
            Button("Supprimer du gabarit", role: .destructive) {
                run { try library.deleteMaster(master.id, in: stencilID) }
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { UserStencilPrompt.error(error) }
    }
}

/// Miniature d'une forme de Mes formes : le vrai rendu (styles, connecteurs), sans les textes.
struct UserMasterPreview: View {
    let master: UserMaster

    var body: some View {
        Canvas { ctx, size in
            let b = master.bounds
            guard b.width > 0 || b.height > 0 else { return }
            let zoom = min(size.width / max(b.width, 1), size.height / max(b.height, 1)) * 0.9
            let offset = CGSize(width: (size.width - b.width * zoom) / 2 - b.minX * zoom,
                                height: (size.height - b.height * zoom) / 2 - b.minY * zoom)
            let diagram = Diagram(shapes: master.fragment.shapes, connectors: master.fragment.connectors)
            DiagramPainter(diagram: diagram, zoom: zoom, offset: offset, forExport: true).drawContent(&ctx)
        }
    }
}

/// Petites fenêtres de dialogue du volet (saisie d'un nom, erreur).
@MainActor
enum UserStencilPrompt {
    static func text(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return String(name.prefix(DiagramIO.maxNameLength))
    }

    static func error(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Mes formes"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
