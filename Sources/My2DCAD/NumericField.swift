import SwiftUI
import AppKit

// Champ numérique de saisie, comme les champs de Visio : la saisie reste libre (on peut tout effacer,
// taper « 2,5 » ou « 2.5 ») et n'est appliquée qu'à la validation — Entrée, Tab ou clic ailleurs.
// Échap rétablit la valeur. Une saisie vide ou invalide est refusée (bip) et la valeur est rétablie.
//
// Pourquoi pas TextField(value:format:) : sous macOS, ce champ réécrit le texte dès qu'il ne se lit plus
// comme un nombre (impossible d'effacer le dernier chiffre) et applique chaque frappe — pour l'échelle,
// taper « 50 » après avoir effacé « 100 » redimensionnait le dessin à 1:10, puis 1:1, puis 1:5, puis 1:50.

struct NumericField: View {
    let title: String
    /// Valeur actuelle, affichée quand le champ n'est pas en cours de saisie.
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

    @State private var text = ""
    @State private var dirty = false
    @State private var editContext: AnyHashable?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: Binding(
            get: { text },
            set: { newText in
                if !dirty { editContext = context }
                text = newText
                dirty = true
            }))
            .focused($focused)
            .onSubmit(apply)
            .onExitCommand(perform: revert)
            .onAppear { text = Self.format(value, fractionDigits: fractionDigits) }
            .onChange(of: value) { _, newValue in
                if !dirty { text = Self.format(newValue, fractionDigits: fractionDigits) }
            }
            .onChange(of: fractionDigits) { _, digits in
                if !dirty { text = Self.format(value, fractionDigits: digits) }
            }
            .onChange(of: context) { _, _ in
                // Autre objet : la saisie en cours ne le concerne pas.
                if dirty { revert() }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { apply() }
            }
    }

    private func apply() {
        guard dirty else { return }
        defer {
            dirty = false
            // Valeur affichée avant validation : si elle est acceptée, onChange(of: value) affichera la nouvelle.
            text = Self.format(value, fractionDigits: fractionDigits)
        }
        guard editContext == context else { return }
        guard let v = Self.parse(text), v.isFinite, isValid(v) else {
            NSSound.beep()
            return
        }
        if v != value { commit(v) }
    }

    private func revert() {
        dirty = false
        text = Self.format(value, fractionDigits: fractionDigits)
    }

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
