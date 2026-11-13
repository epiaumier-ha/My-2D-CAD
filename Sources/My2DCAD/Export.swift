import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case cannotCreate
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .cannotCreate: return "Impossible de créer le fichier."
        case .renderingFailed: return "Le rendu de la page a échoué."
        }
    }
}

/// Export des pages : PDF vectoriel (toutes les pages), PNG haute résolution (page courante), impression.
/// Seuls les calques visibles et imprimables sont exportés.
@MainActor
enum DiagramExporter {
    static let margin: CGFloat = 24
    /// Côté maximal d'une image PNG, en pixels.
    static let maxPixels: CGFloat = 16_384

    /// Zone utile d'une page : formes et connecteurs exportés.
    static func contentBounds(_ page: Diagram) -> CGRect? {
        let painter = DiagramPainter(diagram: page, zoom: 1, offset: .zero, forExport: true)
        // Image d'arrière-plan incluse à l'impression.
        var bounds: CGRect? = painter.drawnBackground?.bounds
        for s in page.shapes where painter.isDrawn(s) {
            var b = s.bounds
            // Bloc de texte (éventuellement déplacé hors de la forme).
            if !s.text.isEmpty || s.kind.isDimension, let tf = page.textFrame(s) { b = b.union(tf.bounds) }
            bounds = bounds.map { $0.union(b) } ?? b
        }
        for c in page.connectors where painter.isDrawn(c) {
            for p in page.connectorPoints(c, context: painter.routing) ?? [] {
                let r = CGRect(origin: p, size: .zero)
                bounds = bounds.map { $0.union(r) } ?? r
            }
        }
        return bounds
    }

    /// Vue d'une page et sa taille en points (zoom 1), marges comprises : le dessin seul (PNG).
    static func pageView(_ page: Diagram) -> (ExportPageView, CGSize) {
        let content = contentBounds(page) ?? CGRect(x: 0, y: 0, width: 200, height: 150)
        let size = CGSize(width: ceil(content.width + 2 * margin), height: ceil(content.height + 2 * margin))
        let painter = DiagramPainter(diagram: page, zoom: 1,
                                     offset: CGSize(width: margin - content.minX, height: margin - content.minY),
                                     forExport: true)
        return (ExportPageView(painter: painter, size: size), size)
    }

    /// Vue de la feuille entière, à sa taille (PDF et impression) : ce qui dépasse n'est pas imprimé.
    static func sheetView(_ page: Diagram) -> (ExportPageView, CGSize) {
        let size = page.sheetRect.size
        let painter = DiagramPainter(diagram: page, zoom: 1, offset: .zero, forExport: true)
        return (ExportPageView(painter: painter, size: size), size)
    }

    /// PDF vectoriel : une page PDF par page du dessin, au format de sa feuille.
    static func writePDF(_ document: CADDocument, to url: URL) throws {
        var defaultBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(url as CFURL, mediaBox: &defaultBox, nil) else { throw ExportError.cannotCreate }
        for page in document.pages {
            let (view, size) = sheetView(page)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(size)
            var box = CGRect(origin: .zero, size: size)
            renderer.render { _, draw in
                pdf.beginPage(mediaBox: &box)
                draw(pdf)
                pdf.endPage()
            }
        }
        pdf.closePDF()
    }

    /// PNG de la page, en double résolution (réduite si l'image dépasse 16 384 pixels).
    static func pngData(_ page: Diagram) throws -> Data {
        let (view, size) = pageView(page)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = min(2, maxPixels / max(size.width, size.height, 1))
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ExportError.renderingFailed
        }
        return data
    }
}

@MainActor
extension DocumentStore {
    private var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Sans titre"
    }

    func exportPDF() {
        if editingShapeID != nil { commitTextEditing() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = baseName + ".pdf"
        panel.message = "Toutes les pages sont exportées au format de leur feuille (calques visibles et imprimables)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagramExporter.writePDF(document, to: url)
        } catch {
            showError("Impossible d'exporter en PDF", error)
        }
    }

    func exportPNG() {
        if editingShapeID != nil { commitTextEditing() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let suffix = document.pages.count > 1 ? " - " + doc.name : ""
        panel.nameFieldStringValue = baseName + suffix + ".png"
        panel.message = "La page affichée est exportée en haute résolution."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagramExporter.pngData(doc).write(to: url, options: .atomic)
        } catch {
            showError("Impossible d'exporter en PNG", error)
        }
    }

    /// Impression : le document est rendu en PDF puis imprimé (une page imprimée par page, ajustée).
    func printDocument() {
        if editingShapeID != nil { commitTextEditing() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("My2DCAD-impression-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try DiagramExporter.writePDF(document, to: url)
            guard let pdf = PDFDocument(url: url),
                  let operation = pdf.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit,
                                                     autoRotate: true) else { throw ExportError.renderingFailed }
            operation.jobTitle = baseName
            operation.run()
        } catch {
            showError("Impossible d'imprimer", error)
        }
    }
}
