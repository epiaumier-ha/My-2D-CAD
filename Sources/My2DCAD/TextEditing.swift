import Foundation

@MainActor
extension DocumentStore {
    /// Ouvre l'éditeur de texte sur la forme (double-clic, Entrée ou F2).
    func startTextEditing(_ id: UUID) {
        if editingShapeID != nil { commitTextEditing() }
        guard let shape = doc.shape(id) else { return }
        selection = [id]
        editingText = shape.text
        editingShapeID = id
    }

    /// Enregistre le texte saisi (une seule étape d'annulation) et ferme l'éditeur.
    func commitTextEditing() {
        guard let id = editingShapeID else { return }
        editingShapeID = nil
        let text = String(editingText.prefix(DiagramIO.maxTextLength))
        perform { d in
            if let i = d.shapes.firstIndex(where: { $0.id == id }) { d.shapes[i].text = text }
        }
    }

    /// Ferme l'éditeur sans rien modifier (Échap).
    func cancelTextEditing() {
        editingShapeID = nil
    }
}
