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
                    if let item = StencilCatalog.item(for: s.kind) {
                        LabeledContent("Type", value: item.name)
                    }
                    if s.kind.isPath {
                        LabeledContent("Type", value: s.kind == .line ? "Trait" : "Courbe")
                        ColorPicker("Couleur du trait", selection: Binding(
                            get: { s.fill.color },
                            set: { c in store.editSelectedShape(key: "fill") { $0.fill = RGBA(color: c) } }),
                                    supportsOpacity: false)
                    } else if s.kind != .text && !s.kind.isLineArt {
                        ColorPicker("Remplissage", selection: Binding(
                            get: { s.fill.color },
                            set: { c in store.editSelectedShape(key: "fill") { $0.fill = RGBA(color: c) } }),
                                    supportsOpacity: false)
                    }
                }
                Section("Position et taille") {
                    field("X", value: s.rect.origin.x) { $0.rect.origin.x = $1 }
                    field("Y", value: s.rect.origin.y) { $0.rect.origin.y = $1 }
                    if !s.kind.isPath {
                    field("Largeur", value: s.rect.width, minValue: 1) { $0.rect.size.width = $1 }
                    field("Hauteur", value: s.rect.height, minValue: 1) { $0.rect.size.height = $1 }
                    TextField("Rotation (°)", value: Binding<Double>(
                        get: { s.rotation },
                        set: { v in
                            guard v.isFinite else { return }
                            store.editSelectedShape(key: "rotation") { $0.rotation = normalizedAngle(v) }
                        }),
                              format: .number.precision(.fractionLength(0...1)))
                    }
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

            if !store.selectedShapes.isEmpty {
                arrangeSection
            }
        }
        .formStyle(.grouped)
    }

    private var arrangeSection: some View {
        let count = store.selectedShapes.count
        return Section("Disposition") {
            LabeledContent("Aligner") {
                HStack(spacing: 2) {
                    ForEach(ShapeAlignment.allCases, id: \.self) { a in
                        iconButton(a.symbol, help: "Aligner \(a.label.lowercased())") { store.align(a) }
                            .disabled(count < 2)
                    }
                }
            }
            LabeledContent("Répartir") {
                HStack(spacing: 2) {
                    iconButton("distribute.horizontal.center", help: "Répartir horizontalement") {
                        store.distribute(.horizontal)
                    }
                    iconButton("distribute.vertical.center", help: "Répartir verticalement") {
                        store.distribute(.vertical)
                    }
                }
                .disabled(count < 3)
            }
            LabeledContent("Pivoter") {
                HStack(spacing: 2) {
                    iconButton("rotate.left", help: "Faire pivoter de 90° à gauche") { store.rotateSelection(by: -90) }
                    iconButton("rotate.right", help: "Faire pivoter de 90° à droite") { store.rotateSelection(by: 90) }
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
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
