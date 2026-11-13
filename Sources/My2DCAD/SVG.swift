import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Export SVG

/// Export vectoriel d'une page en SVG (1 unité du dessin = 1 pt). Calques masqués ou non imprimables exclus.
@MainActor
enum SVGExporter {
    static func svg(for page: Diagram) -> String {
        let painter = DiagramPainter(diagram: page, zoom: 1, offset: .zero, forExport: true)
        let content = DiagramExporter.contentBounds(page) ?? CGRect(x: 0, y: 0, width: 200, height: 150)
        let m = DiagramExporter.margin
        let w = ceil(content.width + 2 * m), h = ceil(content.height + 2 * m)
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(n(w))pt" height="\(n(h))pt" viewBox="0 0 \(n(w)) \(n(h))">
        <title>\(escape(page.name))</title>
        <rect width="100%" height="100%" fill="#ffffff"/>
        <g transform="translate(\(n(m - content.minX)) \(n(m - content.minY)))" font-family="Helvetica, Arial, sans-serif">

        """
        if let bg = painter.drawnBackground { out += backgroundElement(bg) }
        // Formes et connecteurs dans l'ordre de superposition.
        page.forEachInStackOrder(shape: { s in
            if painter.isDrawn(s) { out += shapeElement(s, painter: painter) }
        }, connector: { c in
            guard painter.isDrawn(c), let pts = page.connectorPoints(c, context: painter.routing), pts.count > 1 else { return }
            var path = Path()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            out += pathElement(path, fill: nil, stroke: c.line)
            if let next = pts.dropFirst().first(where: { $0.distance(to: pts[0]) > 0.5 }) {
                out += arrow(c.line.beginArrow, tip: pts[0], from: next, style: c.line)
            }
            let tip = pts[pts.count - 1]
            if let prev = pts.dropLast().last(where: { $0.distance(to: tip) > 0.5 }) {
                out += arrow(c.line.endArrow, tip: tip, from: prev, style: c.line)
            }
        })
        out += "</g>\n</svg>\n"
        return out
    }

    /// Image d'arrière-plan incorporée (data URI) : rotation et retournements par transformation,
    /// rognage par la zone affichée d'un <svg> imbriqué, transparence par l'opacité.
    static func backgroundElement(_ bg: BackgroundImage) -> String {
        guard let img = BackgroundImageCache.shared.image(bg) else { return "" }
        let pw = CGFloat(img.width), ph = CGFloat(img.height), c = bg.crop
        let w = bg.frame.width, h = bg.frame.height
        var t = "translate(\(n(bg.frame.midX)) \(n(bg.frame.midY)))"
        if bg.rotation != 0 { t += " rotate(\(n(bg.rotation)))" }
        if bg.flipHorizontal || bg.flipVertical { t += " scale(\(bg.flipHorizontal ? -1 : 1) \(bg.flipVertical ? -1 : 1))" }
        let opacity = bg.transparency > 0 ? " opacity=\"\(n(1 - bg.transparency))\"" : ""
        let view = "\(n(CGFloat(c.left) * pw)) \(n(CGFloat(c.top) * ph)) \(n(CGFloat(1 - c.left - c.right) * pw)) \(n(CGFloat(1 - c.top - c.bottom) * ph))"
        return """
        <g transform="\(t)"\(opacity)><svg x="\(n(-w / 2))" y="\(n(-h / 2))" width="\(n(w))" height="\(n(h))" viewBox="\(view)" preserveAspectRatio="none"><image width="\(n(pw))" height="\(n(ph))" href="data:\(BackgroundImageIO.mimeType(bg.data));base64,\(bg.data.base64EncodedString())"/></svg></g>

        """
    }

    private static func shapeElement(_ s: Shape, painter: DiagramPainter) -> String {
        var out = ""
        if let l = s.dimensionLayout {
            if s.line.dash != .none {
                var p = Path()
                for (a, b) in l.extensionLines {
                    p.move(to: a)
                    p.addLine(to: b)
                }
                if let first = l.line.first {
                    p.move(to: first)
                    for q in l.line.dropFirst() { p.addLine(to: q) }
                }
                out += pathElement(p, fill: nil, stroke: s.line)
            }
            if let b = l.begin { out += arrow(s.line.beginArrow, tip: b.tip, from: b.from, style: s.line) }
            if let e = l.end { out += arrow(s.line.endArrow, tip: e.tip, from: e.from, style: s.line) }
            let anchor = l.labelAnchor
            let angle = l.labelAngle * 180 / .pi
            out += "<g transform=\"rotate(\(n(angle)) \(n(anchor.x)) \(n(anchor.y)))\">"
            out += textElement(painter.dimensionText(s), style: s.textStyle, anchor: "middle",
                               x: anchor.x + s.textOffset.x, firstBaseline: anchor.y - 3 + s.textOffset.y)
            out += "</g>\n"
            return out
        }
        if s.kind.isPath {
            let pts = s.worldPoints
            out += pathElement(painter.screenPath(kind: s.kind, points: pts), fill: nil, stroke: s.line)
            if pts.count >= 2 {
                let beforeEnd = s.kind == .curve && pts.count == 3 ? pts[1] : pts[pts.count - 2]
                out += arrow(s.line.beginArrow, tip: pts[0], from: pts[1], style: s.line)
                out += arrow(s.line.endArrow, tip: pts[pts.count - 1], from: beforeEnd, style: s.line)
            }
            if !s.text.isEmpty {
                let mid = s.pathMidpoint
                out += textElement(s.text, style: s.textStyle, anchor: "middle", x: mid.x + s.textOffset.x,
                                   firstBaseline: mid.y + s.textOffset.y - CGFloat(s.textStyle.size) * 0.3)
            }
            return out
        }

        let r = s.rect
        out += s.rotation != 0 ? "<g transform=\"rotate(\(n(s.rotation)) \(n(r.midX)) \(n(r.midY)))\">\n" : "<g>\n"
        if s.kind != .text {
            let parts = s.paths(in: r)
            if !parts.fill.isEmpty {
                out += pathElement(parts.fill, fill: s.noFill ? nil : (s.fill, 1 - s.fillTransparency), stroke: s.line,
                                   evenOdd: s.evenOdd)
            }
            if !parts.stroke.isEmpty { out += pathElement(parts.stroke, fill: nil, stroke: s.line) }
        }
        if !s.text.isEmpty {
            let ts = s.textStyle
            let size = CGFloat(ts.size)
            let lines = CGFloat(s.text.split(separator: "\n", omittingEmptySubsequences: false).count)
            let off = s.textOffset
            if s.kind.labelPlacement == .below {
                out += textElement(s.text, style: ts, anchor: "middle", x: r.midX + off.x,
                                   firstBaseline: r.maxY + 4 + size * 0.9 + off.y)
            } else {
                let half = s.textBlockWidthValue / 2
                let (anchor, x): (String, CGFloat) = {
                    switch ts.alignment {
                    case .left: return ("start", r.midX - half)
                    case .center: return ("middle", r.midX)
                    case .right: return ("end", r.midX + half)
                    }
                }()
                let first = r.midY - (lines - 1) * size * 0.6 + size * 0.35
                out += textElement(s.text, style: ts, anchor: anchor, x: x + off.x, firstBaseline: first + off.y)
            }
        }
        out += "</g>\n"
        return out
    }

    // MARK: Éléments

    private static func pathElement(_ path: Path, fill: (RGBA, Double)?, stroke l: LineStyle,
                                    evenOdd: Bool = false) -> String {
        var attrs = "d=\"\(pathData(path))\""
        if evenOdd { attrs += " fill-rule=\"evenodd\"" }
        if let f = fill {
            let (c, opacity) = f
            attrs += " fill=\"\(hex(c))\""
            let o = opacity * c.a
            if o < 1 { attrs += " fill-opacity=\"\(n(CGFloat(o)))\"" }
        } else {
            attrs += " fill=\"none\""
        }
        attrs += strokeAttributes(l)
        return "<path \(attrs)/>\n"
    }

    private static func strokeAttributes(_ l: LineStyle) -> String {
        guard l.dash != .none else { return " stroke=\"none\"" }
        var a = " stroke=\"\(hex(l.color))\" stroke-width=\"\(n(CGFloat(l.width)))\" stroke-linejoin=\"round\""
        let cap: String = { switch l.cap { case .round: return "round"; case .square: return "square"; case .flat: return "butt" } }()
        a += " stroke-linecap=\"\(cap)\""
        let o = (1 - l.transparency) * l.color.a
        if o < 1 { a += " stroke-opacity=\"\(n(CGFloat(o)))\"" }
        let dash = l.strokeStyle(zoom: 1).dash
        if !dash.isEmpty { a += " stroke-dasharray=\"\(dash.map { n($0) }.joined(separator: " "))\"" }
        return a
    }

    private static func arrow(_ type: ArrowHead, tip: CGPoint, from: CGPoint, style l: LineStyle) -> String {
        guard let head = arrowHead(type, tip: tip, from: from, size: l.arrowLength(zoom: 1)) else { return "" }
        if head.filled {
            return "<path d=\"\(pathData(head.path))\" fill=\"\(hex(l.color))\" stroke=\"none\"/>\n"
        }
        var solid = l
        solid.dash = .solid
        return pathElement(head.path, fill: nil, stroke: solid)
    }

    private static func textElement(_ text: String, style ts: TextStyle, anchor: String,
                                    x: CGFloat, firstBaseline: CGFloat) -> String {
        let size = CGFloat(ts.size)
        var a = "x=\"\(n(x))\" y=\"\(n(firstBaseline))\" font-size=\"\(n(size))\" fill=\"\(hex(ts.color))\""
        a += " text-anchor=\"\(anchor)\""
        if ts.bold { a += " font-weight=\"bold\"" }
        if ts.italic { a += " font-style=\"italic\"" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out = "<text \(a)>"
        for (i, line) in lines.enumerated() {
            out += "<tspan x=\"\(n(x))\" dy=\"\(i == 0 ? "0" : n(size * 1.2))\">\(escape(String(line)))</tspan>"
        }
        return out + "</text>\n"
    }

    // MARK: Outils

    static func pathData(_ path: Path) -> String {
        var d = ""
        path.forEach { e in
            switch e {
            case .move(let p): d += "M\(n(p.x)) \(n(p.y)) "
            case .line(let p): d += "L\(n(p.x)) \(n(p.y)) "
            case .quadCurve(let p, let c): d += "Q\(n(c.x)) \(n(c.y)) \(n(p.x)) \(n(p.y)) "
            case .curve(let p, let c1, let c2):
                d += "C\(n(c1.x)) \(n(c1.y)) \(n(c2.x)) \(n(c2.y)) \(n(p.x)) \(n(p.y)) "
            case .closeSubpath: d += "Z "
            }
        }
        return d.trimmingCharacters(in: .whitespaces)
    }

    static func n(_ v: CGFloat) -> String {
        guard v.isFinite else { return "0" }
        var s = String(format: "%.2f", Double(v))
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func n(_ v: Double) -> String { n(CGFloat(v)) }

    static func hex(_ c: RGBA) -> String {
        func h(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", h(c.r), h(c.g), h(c.b))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Import SVG

enum SVGImportError: LocalizedError {
    case tooLarge
    case invalid(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Le fichier SVG est trop volumineux."
        case .invalid(let m): return "Fichier SVG invalide : \(m)"
        case .empty: return "Aucune forme reconnue dans ce fichier SVG."
        }
    }
}

/// Style SVG hérité (fill, stroke, texte).
private struct SVGStyle {
    enum Paint { case none, color(RGBA) }
    var fill: Paint = .color(RGBA(r: 0, g: 0, b: 0, a: 1))
    var stroke: Paint = .none
    var strokeWidth: CGFloat = 1
    var opacity: Double = 1
    var fillOpacity: Double = 1
    var strokeOpacity: Double = 1
    var dashed = false
    var fontSize: CGFloat = 16
    var bold = false
    var italic = false
    var anchor = "start"
}

/// Lecture d'un SVG (fichier non fiable) : rect, circle, ellipse, line, polyline, polygon, path, text,
/// groupes, transformations et styles. Les éléments non pris en charge (images, dégradés…) sont ignorés.
final class SVGImporter: NSObject, XMLParserDelegate {
    static let maxFileSize = 20 * 1024 * 1024
    static let maxShapes = 5000
    static let maxDepth = 64

    private var result: [Shape] = []
    private var styles: [SVGStyle] = [SVGStyle()]
    private var transforms: [CGAffineTransform] = [.identity]
    private var ignoredDepth = 0
    private var depth = 0
    private var sawRoot = false
    // Texte en cours
    private var textOrigin: CGPoint?
    private var textBuffer = ""
    private var textStyle = SVGStyle()
    private var textTransform = CGAffineTransform.identity
    private var inText = false

    static func shapes(from data: Data) throws -> [Shape] {
        guard data.count <= maxFileSize else { throw SVGImportError.tooLarge }
        let importer = SVGImporter()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = importer
        guard parser.parse() || !importer.result.isEmpty else {
            throw SVGImportError.invalid(parser.parserError?.localizedDescription ?? "XML illisible")
        }
        guard importer.sawRoot else { throw SVGImportError.invalid("élément <svg> absent") }
        guard !importer.result.isEmpty else { throw SVGImportError.empty }
        return importer.result
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        depth += 1
        let name = elementName.lowercased()
        let ignored = ["defs", "clippath", "mask", "symbol", "marker", "pattern", "style", "title", "desc",
                       "metadata", "lineargradient", "radialgradient", "filter", "script", "foreignobject"]
        if ignoredDepth > 0 || ignored.contains(name) || depth > Self.maxDepth || result.count >= Self.maxShapes {
            ignoredDepth += 1
            return
        }
        var style = styles.last ?? SVGStyle()
        apply(attributes, to: &style)
        var ctm = transforms.last ?? .identity
        if name == "svg" {
            ctm = viewportTransform(attributes).concatenating(ctm)
            sawRoot = true
        }
        if let t = attributes["transform"] { ctm = parseTransform(t).concatenating(ctm) }
        styles.append(style)
        transforms.append(ctm)

        switch name {
        case "rect":
            let x = num(attributes["x"]), y = num(attributes["y"])
            let w = num(attributes["width"]), h = num(attributes["height"])
            guard w > 0, h > 0 else { return }
            let rx = num(attributes["rx"] ?? attributes["ry"])
            let r = CGRect(x: x, y: y, width: w, height: h)
            if rx <= 0, isAxisAligned(ctm) {
                addShape(kind: .rectangle, rect: r.applying(ctm), style: style, ctm: ctm)
            } else {
                addFreeform(rx > 0 ? Path(roundedRect: r, cornerRadius: min(rx, w / 2, h / 2)) : Path(r),
                            style: style, ctm: ctm)
            }
        case "circle", "ellipse":
            let cx = num(attributes["cx"]), cy = num(attributes["cy"])
            let rx = name == "circle" ? num(attributes["r"]) : num(attributes["rx"])
            let ry = name == "circle" ? rx : num(attributes["ry"])
            guard rx > 0, ry > 0 else { return }
            let r = CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)
            if isAxisAligned(ctm) {
                addShape(kind: .ellipse, rect: r.applying(ctm), style: style, ctm: ctm)
            } else {
                addFreeform(Path(ellipseIn: r), style: style, ctm: ctm)
            }
        case "line":
            let a = CGPoint(x: num(attributes["x1"]), y: num(attributes["y1"])).applying(ctm)
            let b = CGPoint(x: num(attributes["x2"]), y: num(attributes["y2"])).applying(ctm)
            guard valid(a), valid(b), a != b else { return }
            var s = Shape(kind: .line, rect: .zero)
            s.setWorldPoints([a, b])
            s.line = lineStyle(style, ctm: ctm) ?? { var l = LineStyle.pathDefault; l.dash = .none; return l }()
            result.append(s)
        case "polyline", "polygon":
            let values = numbers(attributes["points"] ?? "")
            guard values.count >= 4 else { return }
            var p = Path()
            p.move(to: CGPoint(x: values[0], y: values[1]))
            var i = 2
            while i + 1 < values.count { p.addLine(to: CGPoint(x: values[i], y: values[i + 1])); i += 2 }
            if name == "polygon" { p.closeSubpath() }
            addFreeform(p, style: style, ctm: ctm)
        case "path":
            if let p = SVGPathParser.parse(attributes["d"] ?? "") { addFreeform(p, style: style, ctm: ctm) }
        case "text":
            inText = true
            textBuffer = ""
            textStyle = style
            textTransform = ctm
            textOrigin = CGPoint(x: firstNumber(attributes["x"]), y: firstNumber(attributes["y"]))
        case "tspan":
            if inText, !textBuffer.isEmpty, attributes["x"] != nil || attributes["dy"] != nil { textBuffer += "\n" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText, ignoredDepth == 0, textBuffer.count < DiagramIO.maxTextLength else { return }
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        depth -= 1
        if ignoredDepth > 0 { ignoredDepth -= 1; return }
        if elementName.lowercased() == "text" {
            finishText()
            inText = false
        }
        if styles.count > 1 { styles.removeLast() }
        if transforms.count > 1 { transforms.removeLast() }
    }

    // MARK: Formes

    private func valid(_ p: CGPoint) -> Bool {
        p.x.isFinite && p.y.isFinite && abs(p.x) <= DiagramIO.maxCoordinate / 2 && abs(p.y) <= DiagramIO.maxCoordinate / 2
    }

    private func isAxisAligned(_ t: CGAffineTransform) -> Bool { abs(t.b) < 1e-9 && abs(t.c) < 1e-9 }

    /// Facteur d'échelle moyen d'une transformation (pour l'épaisseur des traits et la taille du texte).
    private func scaleFactor(_ t: CGAffineTransform) -> CGFloat { sqrt(abs(t.a * t.d - t.b * t.c)) }

    private func lineStyle(_ st: SVGStyle, ctm: CGAffineTransform) -> LineStyle? {
        guard case .color(let c) = st.stroke else { return nil }
        var l = LineStyle()
        l.color = RGBA(r: c.r, g: c.g, b: c.b, a: 1)
        l.width = Double(min(max(st.strokeWidth * scaleFactor(ctm), 0), CGFloat(LineStyle.maxWidth)))
        l.transparency = min(max(1 - st.opacity * st.strokeOpacity * c.a, 0), 1)
        l.dash = st.dashed ? .dash : .solid
        return l
    }

    private func applyStyle(_ st: SVGStyle, ctm: CGAffineTransform, to s: inout Shape) {
        if case .color(let c) = st.fill {
            s.fill = RGBA(r: c.r, g: c.g, b: c.b, a: 1)
            s.fillTransparency = min(max(1 - st.opacity * st.fillOpacity * c.a, 0), 1)
        } else {
            s.noFill = true
        }
        if let l = lineStyle(st, ctm: ctm) {
            s.line = l
        } else {
            s.line.dash = .none
        }
    }

    private func addShape(kind: ShapeKind, rect: CGRect, style: SVGStyle, ctm: CGAffineTransform) {
        let r = rect.standardized
        guard valid(r.origin), valid(CGPoint(x: r.maxX, y: r.maxY)), r.width > 0, r.height > 0 else { return }
        var s = Shape(kind: kind, rect: r)
        applyStyle(style, ctm: ctm, to: &s)
        result.append(s)
    }

    private func addFreeform(_ path: Path, style: SVGStyle, ctm: CGAffineTransform) {
        let world = path.applying(ctm)
        let box = world.cgPath.boundingBoxOfPath
        guard valid(box.origin), valid(CGPoint(x: box.maxX, y: box.maxY)), var s = Shape.freeform(from: world) else { return }
        applyStyle(style, ctm: ctm, to: &s)
        result.append(s)
    }

    private func finishText() {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let origin = textOrigin else { return }
        let scale = max(scaleFactor(textTransform), 0.01)
        let size = min(max(textStyle.fontSize * scale, CGFloat(TextStyle.sizeRange.lowerBound)),
                       CGFloat(TextStyle.sizeRange.upperBound))
        let p = origin.applying(textTransform)
        guard valid(p) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = CGFloat(lines.map(\.count).max() ?? 1)
        let w = max(longest * size * 0.6 + 8, 20), h = CGFloat(lines.count) * size * 1.2 + 4
        let x: CGFloat
        var align = TextAlign.left
        switch textStyle.anchor {
        case "middle": x = p.x - w / 2; align = .center
        case "end": x = p.x - w + 4; align = .right
        default: x = p.x - 4
        }
        var s = Shape(kind: .text, rect: CGRect(x: x, y: p.y - size * 0.9 - 2, width: w, height: h),
                      text: String(text.prefix(DiagramIO.maxTextLength)))
        s.textStyle.size = Double(size)
        s.textStyle.bold = textStyle.bold
        s.textStyle.italic = textStyle.italic
        s.textStyle.alignment = align
        if case .color(let c) = textStyle.fill { s.textStyle.color = RGBA(r: c.r, g: c.g, b: c.b, a: 1) }
        result.append(s)
    }

    // MARK: Attributs

    private func apply(_ attributes: [String: String], to style: inout SVGStyle) {
        var props = attributes
        if let inline = attributes["style"] {
            for decl in inline.split(separator: ";") {
                let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { props[kv[0].lowercased()] = kv[1] }
            }
        }
        if let f = props["fill"], let p = paint(f) { style.fill = p }
        if let s = props["stroke"], let p = paint(s) { style.stroke = p }
        if let w = props["stroke-width"] { style.strokeWidth = max(num(w), 0) }
        if let o = props["opacity"] { style.opacity *= clamp01(num(o, default: 1)) }
        if let o = props["fill-opacity"] { style.fillOpacity = clamp01(num(o, default: 1)) }
        if let o = props["stroke-opacity"] { style.strokeOpacity = clamp01(num(o, default: 1)) }
        if let d = props["stroke-dasharray"] { style.dashed = d.trimmingCharacters(in: .whitespaces) != "none" }
        if let fs = props["font-size"] { style.fontSize = max(num(fs, default: 16), 1) }
        if let fw = props["font-weight"] { style.bold = fw == "bold" || fw == "bolder" || (Int(fw) ?? 400) >= 600 }
        if let fst = props["font-style"] { style.italic = fst == "italic" || fst == "oblique" }
        if let a = props["text-anchor"] { style.anchor = a }
    }

    private func clamp01(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }

    private func paint(_ value: String) -> SVGStyle.Paint? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if v == "none" || v == "transparent" { return SVGStyle.Paint.none }
        if v.hasPrefix("url(") { return SVGStyle.Paint.color(RGBA(r: 0.7, g: 0.7, b: 0.7, a: 1)) }   // dégradé : gris
        if v == "currentcolor" { return .color(RGBA(r: 0, g: 0, b: 0, a: 1)) }
        if v.hasPrefix("#") {
            let hex = String(v.dropFirst())
            let full = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            guard full.count == 6, let n = Int(full, radix: 16) else { return nil }
            return .color(RGBA(r: Double((n >> 16) & 255) / 255, g: Double((n >> 8) & 255) / 255,
                               b: Double(n & 255) / 255, a: 1))
        }
        if v.hasPrefix("rgb") {
            let parts = numbers(String(v.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })))
            guard parts.count >= 3 else { return nil }
            let pct = v.contains("%")
            func comp(_ x: CGFloat) -> Double { Double(min(max(pct ? x / 100 : x / 255, 0), 1)) }
            let alpha = parts.count >= 4 ? Double(min(max(parts[3], 0), 1)) : 1
            return .color(RGBA(r: comp(parts[0]), g: comp(parts[1]), b: comp(parts[2]), a: alpha))
        }
        let named: [String: (Double, Double, Double)] = [
            "black": (0, 0, 0), "white": (1, 1, 1), "red": (1, 0, 0), "green": (0, 0.5, 0), "lime": (0, 1, 0),
            "blue": (0, 0, 1), "yellow": (1, 1, 0), "orange": (1, 0.65, 0), "purple": (0.5, 0, 0.5),
            "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5), "silver": (0.75, 0.75, 0.75),
            "navy": (0, 0, 0.5), "teal": (0, 0.5, 0.5), "maroon": (0.5, 0, 0), "cyan": (0, 1, 1),
            "magenta": (1, 0, 1), "brown": (0.65, 0.16, 0.16), "pink": (1, 0.75, 0.8),
            "lightgray": (0.83, 0.83, 0.83), "lightgrey": (0.83, 0.83, 0.83), "darkgray": (0.66, 0.66, 0.66),
        ]
        if let c = named[v] { return .color(RGBA(r: c.0, g: c.1, b: c.2, a: 1)) }
        return nil
    }

    /// Transformation de la zone d'affichage (width / height / viewBox) vers les points du dessin.
    private func viewportTransform(_ a: [String: String]) -> CGAffineTransform {
        let vb = numbers(a["viewBox"] ?? "")
        guard vb.count == 4, vb[2] > 0, vb[3] > 0 else { return .identity }
        let w = length(a["width"]) ?? vb[2], h = length(a["height"]) ?? vb[3]
        let sx = w / vb[2], sy = h / vb[3]
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return .identity }
        return CGAffineTransform(translationX: -vb[0], y: -vb[1]).concatenating(CGAffineTransform(scaleX: sx, y: sy))
    }

    /// Longueur avec unité, convertie en points (px et sans unité : 1 pour 1).
    private func length(_ s: String?) -> CGFloat? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, !s.hasSuffix("%") else { return nil }
        let units: [(String, CGFloat)] = [("mm", 72 / 25.4), ("cm", 72 / 2.54), ("in", 72), ("pt", 1), ("pc", 12), ("px", 1)]
        for (u, f) in units where s.hasSuffix(u) {
            guard let v = Double(s.dropLast(u.count)) else { return nil }
            return CGFloat(v) * f
        }
        return Double(s).map { CGFloat($0) }
    }

    private func parseTransform(_ s: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n")).lowercased()
            let v = numbers(String(rest[rest.index(after: open)..<close]))
            var t = CGAffineTransform.identity
            switch name {
            case "translate" where v.count >= 1:
                t = CGAffineTransform(translationX: v[0], y: v.count > 1 ? v[1] : 0)
            case "scale" where v.count >= 1:
                t = CGAffineTransform(scaleX: v[0], y: v.count > 1 ? v[1] : v[0])
            case "rotate" where v.count >= 1:
                let a = v[0] * .pi / 180
                if v.count >= 3 {
                    t = CGAffineTransform(translationX: -v[1], y: -v[2])
                        .concatenating(CGAffineTransform(rotationAngle: a))
                        .concatenating(CGAffineTransform(translationX: v[1], y: v[2]))
                } else {
                    t = CGAffineTransform(rotationAngle: a)
                }
            case "matrix" where v.count >= 6:
                t = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            case "skewx" where v.count >= 1:
                t = CGAffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy" where v.count >= 1:
                t = CGAffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                break
            }
            // Liste « A B » : B s'applique d'abord, puis A.
            result = t.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        let values = [result.a, result.b, result.c, result.d, result.tx, result.ty]
        return values.allSatisfy(\.isFinite) ? result : .identity
    }

    private func num(_ s: String?, default d: CGFloat = 0) -> CGFloat {
        guard let s else { return d }
        return length(s) ?? d
    }

    private func firstNumber(_ s: String?) -> CGFloat { numbers(s ?? "").first ?? 0 }

    private func numbers(_ s: String) -> [CGFloat] { SVGPathParser.numbers(s) }
}

// MARK: - Données de tracé SVG (attribut d)

enum SVGPathParser {
    static let maxCommands = 50_000
    /// Coordonnée maximale d'un tracé (unités SVG, avant transformation) : protège les calculs.
    static let maxCoordinate: CGFloat = 1e9

    private enum Token { case command(Character), number(CGFloat) }

    /// Nombres d'une liste SVG (séparateurs : espaces, virgules, signes, « 1.5.5 »).
    static func numbers(_ s: String) -> [CGFloat] {
        tokenize(s).compactMap { if case .number(let v) = $0 { return v } else { return nil } }
    }

    private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s.utf8)
        var i = 0
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        while i < chars.count && tokens.count < maxCommands * 8 {
            let c = chars[i]
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122), c != 101, c != 69 {
                tokens.append(.command(Character(UnicodeScalar(c)))); i += 1; continue
            }
            if isDigit(c) || c == 46 || c == 45 || c == 43 {
                var j = i
                if chars[j] == 45 || chars[j] == 43 { j += 1 }
                var sawDot = false, sawDigit = false
                while j < chars.count {
                    if isDigit(chars[j]) { sawDigit = true; j += 1 }
                    else if chars[j] == 46 && !sawDot { sawDot = true; j += 1 }
                    else { break }
                }
                if j < chars.count && (chars[j] == 101 || chars[j] == 69) {
                    var k = j + 1
                    if k < chars.count && (chars[k] == 45 || chars[k] == 43) { k += 1 }
                    if k < chars.count && isDigit(chars[k]) {
                        j = k
                        while j < chars.count && isDigit(chars[j]) { j += 1 }
                    }
                }
                if sawDigit, let str = String(bytes: chars[i..<j], encoding: .utf8), let v = Double(str), v.isFinite {
                    tokens.append(.number(CGFloat(v)))
                }
                i = max(j, i + 1)
                continue
            }
            i += 1
        }
        return tokens
    }

    /// Tracé SwiftUI à partir de l'attribut d (M L H V C S Q T A Z, absolus et relatifs).
    static func parse(_ d: String) -> Path? {
        let tokens = tokenize(d)
        var path = Path()
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var commands = 0

        func next() -> CGFloat? {
            guard i < tokens.count, case .number(let v) = tokens[i] else { return nil }
            i += 1
            return v
        }
        /// Point dans les limites (fichier non fiable) : au-delà, le tracé s'arrête là.
        func bounded(_ p: CGPoint) -> CGPoint? {
            p.x.isFinite && p.y.isFinite && abs(p.x) <= maxCoordinate && abs(p.y) <= maxCoordinate ? p : nil
        }
        func point(_ rel: Bool) -> CGPoint? {
            guard let x = next(), let y = next() else { return nil }
            return bounded(rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y))
        }

        while i < tokens.count && commands < maxCommands {
            if case .command(let c) = tokens[i] { cmd = c; i += 1 }
            commands += 1
            let rel = cmd.isLowercase
            switch cmd.uppercased().first! {
            case "M":
                guard let p = point(rel) else { return path.isEmpty ? nil : path }
                path.move(to: p); cur = p; start = p
                cmd = rel ? "l" : "L"   // coordonnées suivantes : lignes
                lastCubic = nil; lastQuad = nil
            case "L":
                guard let p = point(rel) else { return path.isEmpty ? nil : path }
                path.addLine(to: p); cur = p; lastCubic = nil; lastQuad = nil
            case "H":
                guard let x = next(), let p = bounded(CGPoint(x: rel ? cur.x + x : x, y: cur.y)) else {
                    return path.isEmpty ? nil : path
                }
                cur = p; path.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case "V":
                guard let y = next(), let p = bounded(CGPoint(x: cur.x, y: rel ? cur.y + y : y)) else {
                    return path.isEmpty ? nil : path
                }
                cur = p; path.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case "C":
                guard let c1 = point(rel), let c2 = point(rel), let p = point(rel) else { return path.isEmpty ? nil : path }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastCubic = c2; lastQuad = nil
            case "S":
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let c2 = point(rel), let p = point(rel) else { return path.isEmpty ? nil : path }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastCubic = c2; lastQuad = nil
            case "Q":
                guard let c = point(rel), let p = point(rel) else { return path.isEmpty ? nil : path }
                path.addQuadCurve(to: p, control: c); cur = p; lastQuad = c; lastCubic = nil
            case "T":
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let p = point(rel) else { return path.isEmpty ? nil : path }
                path.addQuadCurve(to: p, control: c); cur = p; lastQuad = c; lastCubic = nil
            case "A":
                guard let rx = next(), let ry = next(), let rot = next(), let large = next(), let sweep = next(),
                      let p = point(rel) else { return path.isEmpty ? nil : path }
                for (c1, c2, q) in arcToBeziers(from: cur, rx: rx, ry: ry, rotation: rot,
                                                largeArc: large != 0, sweep: sweep != 0, to: p) {
                    path.addCurve(to: q, control1: c1, control2: c2)
                }
                cur = p; lastCubic = nil; lastQuad = nil
            case "Z":
                path.closeSubpath(); cur = start; lastCubic = nil; lastQuad = nil
                // Après Z, un nombre isolé n'a pas de sens : on avance.
                if i < tokens.count, case .number = tokens[i] { i += 1 }
            default:
                i += 1
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Arc elliptique SVG converti en courbes de Bézier cubiques (au plus 90° chacune).
    static func arcToBeziers(from p0: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rotation: CGFloat,
                             largeArc: Bool, sweep: Bool, to p: CGPoint) -> [(CGPoint, CGPoint, CGPoint)] {
        var rx = abs(rx0), ry = abs(ry0)
        guard rx > 0, ry > 0, p0 != p else { return [(p0, p, p)] }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx2 = (p0.x - p.x) / 2, dy2 = (p0.y - p.y) / 2
        let x1 = cosP * dx2 + sinP * dy2, y1 = -sinP * dx2 + cosP * dy2
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = max(rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1, 0)
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (largeArc == sweep ? -1 : 1) * (den > 0 ? sqrt(num / den) : 0)
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        // Valeurs extrêmes (dépassement de capacité) : l'arc est remplacé par un segment droit.
        guard [rx, ry, cx, cy, theta1, delta].allSatisfy(\.isFinite) else { return [(p0, p, p)] }
        let count = max(Int(ceil(abs(delta) / (.pi / 2))), 1)
        let step = delta / CGFloat(count)
        let t = 4 / 3 * tan(step / 4)
        func pt(_ th: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(th) * cosP - ry * sin(th) * sinP, y: cy + rx * cos(th) * sinP + ry * sin(th) * cosP)
        }
        func der(_ th: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(th) * cosP - ry * cos(th) * sinP, y: -rx * sin(th) * sinP + ry * cos(th) * cosP)
        }
        var result: [(CGPoint, CGPoint, CGPoint)] = []
        for k in 0..<count {
            let a = theta1 + CGFloat(k) * step, b = a + step
            let pa = pt(a), pb = k == count - 1 ? p : pt(b)
            let da = der(a), db = der(b)
            result.append((CGPoint(x: pa.x + t * da.x, y: pa.y + t * da.y),
                           CGPoint(x: pb.x - t * db.x, y: pb.y - t * db.y), pb))
        }
        return result
    }
}

// MARK: - Commandes

@MainActor
extension DocumentStore {
    func exportSVG() {
        if editingShapeID != nil { commitTextEditing() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Sans titre"
        panel.nameFieldStringValue = base + (document.pages.count > 1 ? " - " + doc.name : "") + ".svg"
        panel.message = "La page affichée est exportée (calques visibles et imprimables)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(SVGExporter.svg(for: doc).utf8).write(to: url, options: .atomic)
        } catch {
            showError("Impossible d'exporter en SVG", error)
        }
    }

    func importSVG() {
        if editingShapeID != nil { commitTextEditing() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.allowsMultipleSelection = false
        panel.message = "Le dessin est ajouté à la page affichée, regroupé et centré dans la vue."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > SVGImporter.maxFileSize { throw SVGImportError.tooLarge }
            try importSVG(data: Data(contentsOf: url))
        } catch {
            showError("Impossible d'importer le fichier SVG", error)
        }
    }

    /// Ajoute les formes d'un SVG à la page : un seul groupe, centré dans la vue, une étape d'annulation.
    func importSVG(data: Data) throws {
        var shapes = try SVGImporter.shapes(from: data)
        guard let first = shapes.first else { throw SVGImportError.empty }
        let bounds = shapes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let target = visibleCenter
        let dx = target.x - bounds.midX, dy = target.y - bounds.midY
        let group = shapes.count > 1 ? UUID() : nil
        for i in shapes.indices {
            shapes[i].rect = shapes[i].rect.offsetBy(dx: dx, dy: dy)
            shapes[i].groupID = group
            shapes[i].layerID = doc.activeLayerID
        }
        guard insertFragment(ClipboardFragment(shapes: shapes, connectors: []), offset: 0) else {
            throw SVGImportError.invalid("trop de formes ou valeurs hors limites")
        }
    }
}
