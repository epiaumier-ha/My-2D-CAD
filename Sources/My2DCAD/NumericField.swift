import SwiftUI
import AppKit

// Champ numérique de saisie, comme les champs de Visio : la saisie reste libre (on peut tout effacer,
// taper « 2,5 » ou « 2.5 ») et n'est appliquée qu'à la validation — Entrée, Tab, ou clic n'importe où
// ailleurs (dessin, ruban, volet). Échap rétablit la valeur. Une saisie vide ou invalide est refusée (bip)
// et la valeur du document est rétablie.
//
// Le champ est un NSTextField natif plutôt qu'un TextField SwiftUI :
// - TextField(value:format:) réécrit le texte dès qu'il ne se lit plus comme un nombre (impossible
//   d'effacer le dernier chiffre) et applique chaque frappe (l'échelle passait par 1:10, 1:1, 1:5… en tapant 50) ;
// - TextField(text:) + @FocusState signale la perte du focus en différé — après que le clic sur le dessin
//   a déjà changé la sélection —, ne la signale pas quand on clique sur le ruban, et n'actualise pas
//   toujours le texte d'un champ qui a le focus.
// Avec AppKit, la fin de saisie est notifiée immédiatement et le texte affiché suit toujours le document.

struct NumericField: View {
    let title: String
    /// Valeur actuelle, affichée quand aucune saisie n'est en cours.
    let value: Double
    /// Décimales affichées au plus.
    var fractionDigits = 2
    /// Objet modifié (forme, page…) : si la sélection ou la page change pendant la saisie, la saisie
    /// est abandonnée au lieu d'être appliquée au nouvel objet.
    var context: AnyHashable? = nil
    /// Valeurs acceptées (dans l'unité affichée).
    var isValid: (Double) -> Bool = { _ in true }
    /// Application d'une valeur validée.
    let commit: (Double) -> Void

    var body: some View {
        // Libellé à gauche dans le volet (Form), masqué dans le ruban avec .labelsHidden().
        LabeledContent {
            NumericFieldRepresentable(field: self)
        } label: {
            Text(title)
        }
    }

    var formattedValue: String { Self.format(value, fractionDigits: fractionDigits) }

    // MARK: Lecture et écriture des nombres

    /// Nombre saisi : virgule ou point décimal, espaces (séparateurs de milliers) ignorés. nil si invalide.
    nonisolated static func parse(_ text: String) -> Double? {
        var s = text.filter { !$0.isWhitespace && $0 != "\u{202F}" && $0 != "\u{00A0}" }
        guard !s.isEmpty, s.count <= 32 else { return nil }
        s = s.replacingOccurrences(of: ",", with: ".")
        s = s.replacingOccurrences(of: "\u{2212}", with: "-")   // signe moins typographique
        guard s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E") }),
              let v = Double(s), v.isFinite else { return nil }
        return v
    }

    /// Nombre affiché dans la langue de l'utilisateur, sans séparateur de milliers (plus simple à modifier).
    nonisolated static func format(_ value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return "" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...max(fractionDigits, 0))))
    }
}

/// NSTextField des champs numériques, reconnu par le moniteur d'événements (clic hors du champ = validation).
final class NumericTextField: NSTextField {}

private struct NumericFieldRepresentable: NSViewRepresentable {
    let field: NumericField

    func makeCoordinator() -> Coordinator { Coordinator(field: field) }

    func makeNSView(context: Context) -> NumericTextField {
        let f = NumericTextField(string: field.formattedValue)
        f.delegate = context.coordinator
        f.isEditable = true
        f.isSelectable = true
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.usesSingleLineMode = true
        f.lineBreakMode = .byClipping
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.alignment = .right
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.setAccessibilityLabel(field.title)
        return f
    }

    func updateNSView(_ f: NumericTextField, context: Context) {
        let c = context.coordinator
        c.field = field
        let size: NSControl.ControlSize
        switch context.environment.controlSize {
        case .mini: size = .mini
        case .small: size = .small
        case .large: size = .large
        default: size = .regular
        }
        if f.controlSize != size || f.font == nil {
            f.controlSize = size
            f.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        }
        f.isEnabled = context.environment.isEnabled
        f.placeholderString = field.title
        c.refresh(f)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NumericTextField, context: Context) -> CGSize? {
        var width = proposal.width ?? 80
        if !width.isFinite { width = 80 }
        return CGSize(width: min(max(width, 40), 200), height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: NumericField
        /// Texte modifié par l'utilisateur et pas encore validé.
        private var dirty = false
        /// Objet concerné par la saisie en cours.
        private var editContext: AnyHashable?

        init(field: NumericField) { self.field = field }

        /// Affiche la valeur du document, sauf pendant une saisie en cours sur le même objet.
        func refresh(_ f: NSTextField) {
            if dirty {
                guard editContext != field.context else { return }
                dirty = false   // autre forme ou autre page : la saisie ne la concerne pas
            }
            show(field.formattedValue, in: f)
        }

        private func show(_ text: String, in f: NSTextField) {
            if let editor = f.currentEditor() {
                guard editor.string != text else { return }
                editor.string = text
                editor.selectAll(nil)
            } else if f.stringValue != text {
                f.stringValue = text
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            if !dirty { editContext = field.context }
            dirty = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Tab, clic ailleurs, fermeture du volet…
            guard let f = obj.object as? NSTextField else { return }
            apply(f)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let f = control as? NSTextField else { return false }
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                // Échap : abandon de la saisie, la valeur du document est rétablie.
                dirty = false
                show(field.formattedValue, in: f)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Entrée : validation ; le champ garde le focus, valeur sélectionnée.
                apply(f)
                return true
            default:
                return false
            }
        }

        private func apply(_ f: NSTextField) {
            guard dirty else { return }
            dirty = false
            let text = f.currentEditor()?.string ?? f.stringValue
            // Valeur du document avant validation ; si la nouvelle est acceptée, SwiftUI l'affichera.
            show(field.formattedValue, in: f)
            guard editContext == field.context else { return }
            guard let v = NumericField.parse(text), field.isValid(v) else {
                NSSound.beep()
                return
            }
            if v != field.value { field.commit(v) }
        }
    }
}

extension NumericTextField {
    /// Clic hors du champ numérique en cours de saisie : la saisie est validée avant que le clic
    /// n'agisse (sélection d'une autre forme, bouton du ruban…), comme dans Visio.
    @MainActor
    static func endEditingIfClickedOutside(_ event: NSEvent) {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              // Le délégué de l'éditeur de champ est le NSTextField en cours d'édition.
              let delegate = editor.delegate,
              let field = (delegate as AnyObject) as? NumericTextField else { return }
        let p = field.convert(event.locationInWindow, from: nil)
        if !field.bounds.contains(p) { window.makeFirstResponder(nil) }
    }
}
