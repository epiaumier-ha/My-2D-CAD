import SwiftUI
import AppKit

/// Demande d'enregistrer avant de fermer la fenêtre. Sans cela, « Annuler » laissait
/// l'application ouverte sans fenêtre. Le délégué SwiftUI d'origine reste en place :
/// tous les autres messages lui sont transmis.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: @MainActor () -> Bool

    func makeNSView(context: Context) -> GuardView {
        GuardView(shouldClose: shouldClose)
    }

    func updateNSView(_ nsView: GuardView, context: Context) {}

    final class GuardView: NSView {
        private let proxy: CloseProxy

        init(shouldClose: @escaping @MainActor () -> Bool) {
            proxy = CloseProxy(shouldClose: shouldClose)
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.delegate is CloseProxy) else { return }
            proxy.original = window.delegate
            window.delegate = proxy
        }
    }

    @MainActor
    final class CloseProxy: NSObject, NSWindowDelegate {
        nonisolated(unsafe) weak var original: NSWindowDelegate?
        private let shouldClose: @MainActor () -> Bool

        init(shouldClose: @escaping @MainActor () -> Bool) {
            self.shouldClose = shouldClose
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original, original.responds(to: aSelector) { return original }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
