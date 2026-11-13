import SwiftUI

// MARK: - Interface de l'image d'arrière-plan

/// Commandes de l'image d'arrière-plan pour le menu contextuel du canevas et la barre de menus.
struct BackgroundImageMenuItems: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        let bg = store.doc.backgroundImage
        Menu("Image d'arrière-plan") {
            Button(bg == nil ? "Insérer une image…" : "Remplacer l'image…") { store.chooseBackgroundImage() }
            if let bg {
                Divider()
                Button("Ajuster (déplacer, redimensionner)") { store.toggleBackgroundMode(.adjust) }
                    .disabled(bg.locked)
                Button("Rogner") { store.toggleBackgroundMode(.crop) }.disabled(bg.locked)
                Button("Étalonner l'échelle…") { store.toggleBackgroundMode(.calibrate) }.disabled(bg.locked)
                Divider()
                Toggle("Afficher", isOn: Binding(get: { bg.visible }, set: { v in
                    store.editBackground(key: "visible", allowLocked: true) { $0.visible = v }
                }))
                Toggle("Verrouiller", isOn: Binding(get: { bg.locked }, set: { v in
                    store.editBackground(key: "locked", allowLocked: true) { $0.locked = v }
                }))
                Divider()
                Button("Supprimer l'image") { store.removeBackgroundImage() }
            }
        }
    }
}

/// Groupe « Image d'arrière-plan » du ruban (onglet Création).
struct BackgroundImageRibbonGroup: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        let bg = store.doc.backgroundImage
        let editable = store.canEditBackground
        RibbonGroup(title: "Image d'arrière-plan") {
            RibbonLargeButton(title: bg == nil ? "Insérer une image" : "Remplacer l'image", symbol: "photo.on.rectangle",
                              help: "Placer une image sous le dessin de la page (plan scanné, photo…)") {
                store.chooseBackgroundImage()
            }
            VStack(alignment: .leading, spacing: 1) {
                RibbonSmallButton(title: "Ajuster", symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                                  help: "Déplacer et redimensionner l'image (Échap pour terminer)",
                                  active: store.backgroundMode == .adjust) { store.toggleBackgroundMode(.adjust) }
                    .disabled(!editable)
                RibbonSmallButton(title: "Rogner", symbol: "crop", help: "Rogner l'image avec les poignées (Échap pour terminer)",
                                  active: store.backgroundMode == .crop) { store.toggleBackgroundMode(.crop) }
                    .disabled(!editable)
                RibbonSmallButton(title: "Étalonner", symbol: "ruler",
                                  help: "Mettre l'image à l'échelle : glisser entre deux points connus, puis taper leur distance réelle",
                                  active: store.backgroundMode == .calibrate) { store.toggleBackgroundMode(.calibrate) }
                    .disabled(!editable)
            }
            VStack(alignment: .leading, spacing: 1) {
                RibbonSmallButton(title: bg?.locked == true ? "Déverrouiller" : "Verrouiller",
                                  symbol: bg?.locked == true ? "lock.open" : "lock",
                                  help: "Empêcher de déplacer, redimensionner ou rogner l'image") {
                    store.editBackground(key: "locked", allowLocked: true) { $0.locked.toggle() }
                }
                .disabled(bg == nil)
                RibbonSmallButton(title: bg?.visible == false ? "Afficher" : "Masquer",
                                  symbol: bg?.visible == false ? "eye" : "eye.slash") {
                    store.editBackground(key: "visible", allowLocked: true) { $0.visible.toggle() }
                }
                .disabled(bg == nil)
                RibbonSmallButton(title: "Supprimer", symbol: "trash") { store.removeBackgroundImage() }
                    .disabled(bg == nil)
            }
        }
    }
}

/// Section « Image d'arrière-plan » du volet (page sans sélection).
struct BackgroundImageInspector: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        if let bg = store.doc.backgroundImage {
            content(bg)
        } else {
            Button("Insérer une image…") { store.chooseBackgroundImage() }
            Text("Plan scanné, photo ou croquis placé sous le dessin, pour le décalquer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(_ bg: BackgroundImage) -> some View {
        let d = store.doc
        let editable = !bg.locked
        if !bg.name.isEmpty { LabeledContent("Fichier", value: bg.name).lineLimit(1).truncationMode(.middle) }
        Toggle("Afficher", isOn: binding(bg.visible, key: "visible") { $0.visible = $1 })
        Toggle("Inclure à l'export et à l'impression", isOn: binding(bg.printable, key: "printable") { $0.printable = $1 })
        Toggle("Verrouiller", isOn: binding(bg.locked, key: "locked") { $0.locked = $1 })
        LabeledContent("Transparence") {
            HStack {
                Slider(value: Binding(get: { bg.transparency * 100 }, set: { v in
                    store.editBackground(key: "transparency", allowLocked: true) { $0.transparency = min(max(v / 100, 0), 1) }
                }), in: 0...100)
                Text("\(Int((bg.transparency * 100).rounded())) %").monospacedDigit().frame(width: 42, alignment: .trailing)
            }
        }

        Group {
            HStack {
                modeButton("Ajuster", "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", .adjust)
                modeButton("Rogner", "crop", .crop)
                modeButton("Étalonner", "ruler", .calibrate)
            }
            measureField("X", bg.frame.minX) { b, v in b.frame.origin.x = v }
            measureField("Y", bg.frame.minY) { b, v in b.frame.origin.y = v }
            measureField("Largeur", bg.frame.width, positive: true) { b, v in
                let h = b.keepAspectRatio ? b.frame.height * v / b.frame.width : b.frame.height
                b = b.withSize(CGSize(width: v, height: h))
            }
            measureField("Hauteur", bg.frame.height, positive: true) { b, v in
                let w = b.keepAspectRatio ? b.frame.width * v / b.frame.height : b.frame.width
                b = b.withSize(CGSize(width: w, height: v))
            }
            Toggle("Conserver les proportions", isOn: binding(bg.keepAspectRatio, key: "aspect") { $0.keepAspectRatio = $1 })
            HStack {
                Button("Ajuster à la feuille") { store.fitBackgroundToSheet() }
                Button("Taille d'origine") { store.resetBackgroundSize() }
                    .help("Taille de l'image selon sa résolution (\(Diagram.format(d.measure(bg.naturalSize.width), decimals: d.precision)) × \(Diagram.format(d.measure(bg.naturalSize.height), decimals: d.precision)) \(d.unit.symbol) non rognée)")
            }
            NumericField(title: "Rotation (°)", value: bg.rotation, fractionDigits: 1, context: d.id,
                         isValid: { $0.isFinite && abs($0) <= 3600 }) { v in
                store.editBackground(key: "rotation") { $0.rotation = normalizedAngle(v) }
            }
            HStack {
                Button { store.rotateBackground(by: -90) } label: { Label("90° à gauche", systemImage: "rotate.left") }
                Button { store.rotateBackground(by: 90) } label: { Label("90° à droite", systemImage: "rotate.right") }
            }
            HStack {
                Button { store.editBackground(key: "flipH-\(UUID())") { $0.flipHorizontal.toggle() } } label: {
                    Label("Retourner horizontalement", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Miroir gauche-droite")
                Button { store.editBackground(key: "flipV-\(UUID())") { $0.flipVertical.toggle() } } label: {
                    Label("Verticalement", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Miroir haut-bas")
            }
            cropField("Rogner à gauche (%)", bg.crop.left) { $0.left = $1 }
            cropField("Rogner en haut (%)", bg.crop.top) { $0.top = $1 }
            cropField("Rogner à droite (%)", bg.crop.right) { $0.right = $1 }
            cropField("Rogner en bas (%)", bg.crop.bottom) { $0.bottom = $1 }
            if !bg.crop.isNone { Button("Rétablir l'image entière") { store.resetBackgroundCrop() } }
        }
        .disabled(!editable)
        Button("Supprimer l'image", role: .destructive) { store.removeBackgroundImage() }
        Text(bg.locked ? "Image verrouillée : déverrouillez-la pour la modifier."
             : "Rognage : côtés de l'image d'origine. Étalonner : glissez entre deux points de distance connue (Maj : horizontale ou verticale), puis tapez leur distance réelle.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func binding(_ value: Bool, key: String, _ set: @escaping (inout BackgroundImage, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { v in store.editBackground(key: key, allowLocked: true) { set(&$0, v) } })
    }

    private func modeButton(_ title: String, _ symbol: String, _ mode: BackgroundEditMode) -> some View {
        Button { store.toggleBackgroundMode(mode) } label: { Label(title, systemImage: symbol) }
            .buttonStyle(.bordered)
            .tint(store.backgroundMode == mode ? .accentColor : nil)
    }

    /// Champ de mesure (unité et échelle de la page).
    private func measureField(_ label: String, _ value: CGFloat, positive: Bool = false,
                              apply: @escaping (inout BackgroundImage, CGFloat) -> Void) -> some View {
        let d = store.doc
        return NumericField(title: "\(label) (\(d.unit.symbol))", value: Double(d.measure(value)),
                            fractionDigits: max(d.precision, 1), context: d.id,
                            isValid: { v in
                                let w = d.worldLength(forMeasure: v)
                                return w.isFinite && abs(w) <= DiagramIO.maxCoordinate / 2 && (!positive || w >= BackgroundImage.minimumSize)
                            }) { v in
            store.editBackground(key: label) { apply(&$0, d.worldLength(forMeasure: v)) }
        }
    }

    /// Rognage d'un côté, en pourcentage de l'image d'origine (l'image ne bouge pas).
    private func cropField(_ label: String, _ value: Double, _ set: @escaping (inout CropInsets, Double) -> Void) -> some View {
        NumericField(title: label, value: value * 100, fractionDigits: 1, context: store.doc.id,
                     isValid: { (0..<99).contains($0) }) { v in
            store.editBackground(key: label) { b in
                var c = b.crop
                set(&c, v / 100)
                guard c.isValid else { NSSound.beep(); return }
                b = b.withCrop(c)
            }
        }
    }
}
