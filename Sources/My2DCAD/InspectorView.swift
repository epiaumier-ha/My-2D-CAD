import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        Form {
            if let s = store.singleSelectedShape {
                Section("Forme") {
                    TextField("Texte", text: Binding(
                        get: { s.text },
                        set: { v in
                            let limited = String(v.prefix(DiagramIO.maxTextLength))
                            store.editSelectedShape(key: "text") { $0.text = limited }
                        }))
                    if s.kind != .text {
                        ColorPicker("Remplissage", selection: Binding(
                            get: { s.fill.color },
                            set: { c in store.editSelectedShape(key: "fill") { $0.fill = RGBA(color: c) } }),
                                    supportsOpacity: false)
                    }
                }
                Section("Position et taille") {
                    field("X", value: s.rect.origin.x) { $0.rect.origin.x = $1 }
                    field("Y", value: s.rect.origin.y) { $0.rect.origin.y = $1 }
                    field("Largeur", value: s.rect.width, minValue: 1) { $0.rect.size.width = $1 }
                    field("Hauteur", value: s.rect.height, minValue: 1) { $0.rect.size.height = $1 }
                }
            } else if store.selection.isEmpty {
                Section("Document") {
                    LabeledContent("Formes", value: "\(store.doc.shapes.count)")
                    LabeledContent("Connecteurs", value: "\(store.doc.connectors.count)")
                    LabeledContent("Zoom", value: "\(Int((store.zoom * 100).rounded())) %")
                }
            } else {
                Section("Sélection") {
                    Text("\(store.selection.count) éléments sélectionnés")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ label: String, value: CGFloat, minValue: CGFloat = -1_000_000,
                       apply: @escaping (inout Shape, CGFloat) -> Void) -> some View {
        TextField(label, value: Binding<Double>(
            get: { Double(value) },
            set: { newValue in
                guard newValue.isFinite else { return }
                let v = min(max(CGFloat(newValue), minValue), 1_000_000)
                store.editSelectedShape(key: label) { apply(&$0, v) }
            }),
                  format: .number.precision(.fractionLength(0...1)))
    }
}
