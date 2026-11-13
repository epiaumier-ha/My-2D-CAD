import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Image d'arrière-plan d'une page (modèle)

/// Rognage, en fraction de l'image d'origine retirée de chaque côté (repère de l'image, avant retournement).
struct CropInsets: Codable, Equatable {
    var left: Double = 0
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0

    static let none = CropInsets()
    /// Part minimale de l'image qui reste visible dans chaque direction.
    static let minimumVisible = 0.01

    var isNone: Bool { self == .none }

    var isValid: Bool {
        let v = [left, top, right, bottom]
        return v.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 1 }
            && left + right <= 1 - Self.minimumVisible + 1e-9
            && top + bottom <= 1 - Self.minimumVisible + 1e-9
    }
}

/// Poignées du cadre de l'image : coins et milieux des côtés, en fraction du cadre (0, ½, 1).
enum BackgroundHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        }
    }

    var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }
}

/// Mode d'édition de l'image d'arrière-plan sur le canevas.
enum BackgroundEditMode: Equatable {
    /// Déplacer et redimensionner (poignées).
    case adjust
    /// Rogner (poignées de rognage, image entière en transparence).
    case crop
    /// Étalonner l'échelle : deux points de l'image, puis leur distance réelle.
    case calibrate
}

/// Image posée sous le dessin d'une page (comme un arrière-plan de Visio) : toujours sous les formes,
/// jamais sélectionnée par un clic. Les octets (PNG ou JPEG) sont incorporés au fichier .cad2d.
struct BackgroundImage: Codable {
    /// Identifiant des octets : il change à chaque nouvelle image (cache de décodage, comparaison rapide).
    var imageID = UUID()
    /// Image encodée (PNG ou JPEG), orientée.
    var data: Data
    /// Nom du fichier d'origine (information).
    var name = ""
    /// Taille de l'image entière à sa résolution d'origine, en points du papier (« Taille d'origine »).
    var naturalSize: CGSize
    /// Cadre de la partie visible (après rognage), avant rotation, en coordonnées monde.
    var frame: CGRect
    var crop = CropInsets.none
    /// Rotation en degrés (sens horaire à l'écran) autour du centre du cadre.
    var rotation: Double = 0
    var flipHorizontal = false
    var flipVertical = false
    /// Transparence : 0 = opaque, 1 = invisible.
    var transparency: Double = 0
    var visible = true
    /// Incluse dans l'export PDF / PNG / SVG et l'impression.
    var printable = true
    /// Verrouillée : ni déplacement, ni redimensionnement, ni rognage.
    var locked = false
    /// Redimensionnement proportionnel (champs du volet et poignées d'angle).
    var keepAspectRatio = true

    enum CodingKeys: String, CodingKey {
        case imageID, data, name, naturalSize, frame, crop, rotation, flipHorizontal, flipVertical
        case transparency, visible, printable, locked, keepAspectRatio
    }

    init(data: Data, name: String = "", naturalSize: CGSize, frame: CGRect) {
        self.data = data
        self.name = name
        self.naturalSize = naturalSize
        self.frame = frame
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageID = try c.decodeIfPresent(UUID.self, forKey: .imageID) ?? UUID()
        data = try c.decode(Data.self, forKey: .data)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        frame = try c.decode(CGRect.self, forKey: .frame)
        naturalSize = try c.decodeIfPresent(CGSize.self, forKey: .naturalSize) ?? frame.size
        crop = try c.decodeIfPresent(CropInsets.self, forKey: .crop) ?? .none
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        transparency = try c.decodeIfPresent(Double.self, forKey: .transparency) ?? 0
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        printable = try c.decodeIfPresent(Bool.self, forKey: .printable) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        keepAspectRatio = try c.decodeIfPresent(Bool.self, forKey: .keepAspectRatio) ?? true
    }
}

extension BackgroundImage: Equatable {
    /// Les octets ne sont pas comparés un à un (l'historique compare le document à chaque action) :
    /// `imageID` change avec chaque nouvelle image.
    static func == (a: BackgroundImage, b: BackgroundImage) -> Bool {
        a.imageID == b.imageID && a.data.count == b.data.count && a.name == b.name
            && a.naturalSize == b.naturalSize && a.frame == b.frame && a.crop == b.crop
            && a.rotation == b.rotation && a.flipHorizontal == b.flipHorizontal && a.flipVertical == b.flipVertical
            && a.transparency == b.transparency && a.visible == b.visible && a.printable == b.printable
            && a.locked == b.locked && a.keepAspectRatio == b.keepAspectRatio
    }
}

// MARK: - Géométrie

extension BackgroundImage {
    /// Taille minimale du cadre (unités monde).
    static let minimumSize: CGFloat = 2

    var angle: CGFloat { CGFloat(rotation) * .pi / 180 }
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Repère local (cadre non pivoté) → monde.
    func toWorld(_ p: CGPoint) -> CGPoint { rotation == 0 ? p : p.rotated(by: angle, around: center) }
    /// Monde → repère local (cadre non pivoté).
    func toLocal(_ p: CGPoint) -> CGPoint { rotation == 0 ? p : p.rotated(by: -angle, around: center) }

    /// Coins du cadre dans le monde : haut-gauche, haut-droite, bas-droite, bas-gauche.
    var corners: [CGPoint] {
        [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
         CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)].map(toWorld)
    }

    /// Rectangle englobant (rotation comprise).
    var bounds: CGRect { Self.boundingBox(corners) }

    func contains(_ world: CGPoint) -> Bool { frame.contains(toLocal(world)) }

    /// Position d'une poignée dans le monde.
    func handlePoint(_ h: BackgroundHandle, in rect: CGRect? = nil) -> CGPoint {
        let r = rect ?? frame
        return toWorld(CGPoint(x: r.minX + h.unit.x * r.width, y: r.minY + h.unit.y * r.height))
    }

    /// Rognage vu à l'écran (gauche, haut, droite, bas du cadre affiché), retournements compris.
    var displayCrop: CropInsets {
        CropInsets(left: flipHorizontal ? crop.right : crop.left, top: flipVertical ? crop.bottom : crop.top,
                   right: flipHorizontal ? crop.left : crop.right, bottom: flipVertical ? crop.top : crop.bottom)
    }

    /// Rognage d'origine correspondant à un rognage vu à l'écran (opération inverse de `displayCrop`).
    func crop(fromDisplay d: CropInsets) -> CropInsets {
        CropInsets(left: flipHorizontal ? d.right : d.left, top: flipVertical ? d.bottom : d.top,
                   right: flipHorizontal ? d.left : d.right, bottom: flipVertical ? d.top : d.bottom)
    }

    /// Cadre de l'image entière (non rognée), dans le repère local.
    var uncroppedFrame: CGRect {
        let d = displayCrop
        let w = frame.width / CGFloat(1 - d.left - d.right)
        let h = frame.height / CGFloat(1 - d.top - d.bottom)
        return CGRect(x: frame.minX - CGFloat(d.left) * w, y: frame.minY - CGFloat(d.top) * h, width: w, height: h)
    }

    /// Nouveau cadre local `local` : le centre est recalculé pour que ce qui ne bouge pas reste en place
    /// malgré la rotation (comme le redimensionnement des formes).
    private func placing(_ local: CGRect) -> CGRect {
        let c = toWorld(CGPoint(x: local.midX, y: local.midY))
        return CGRect(x: c.x - local.width / 2, y: c.y - local.height / 2, width: local.width, height: local.height)
    }

    /// Rognage modifié sans déplacer l'image : seule la partie visible change.
    func withCrop(_ newCrop: CropInsets) -> BackgroundImage {
        guard newCrop.isValid else { return self }
        let full = uncroppedFrame
        var copy = self
        copy.crop = newCrop
        let d = copy.displayCrop
        let local = CGRect(x: full.minX + CGFloat(d.left) * full.width, y: full.minY + CGFloat(d.top) * full.height,
                           width: full.width * CGFloat(1 - d.left - d.right),
                           height: full.height * CGFloat(1 - d.top - d.bottom))
        copy.frame = placing(local)
        return copy
    }

    /// Redimensionnement à la poignée `h` amenée en `pointer` (monde), le côté ou le coin opposé restant fixe.
    /// `proportional` : les poignées d'angle conservent les proportions.
    func resized(handle h: BackgroundHandle, to pointer: CGPoint, proportional: Bool) -> BackgroundImage {
        let q = toLocal(pointer)
        let r = frame
        let m = Self.minimumSize
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if h.unit.x == 0 { minX = min(q.x, maxX - m) } else if h.unit.x == 1 { maxX = max(q.x, minX + m) }
        if h.unit.y == 0 { minY = min(q.y, maxY - m) } else if h.unit.y == 1 { maxY = max(q.y, minY + m) }
        var w = maxX - minX, ht = maxY - minY
        if proportional && h.isCorner && r.width > 0 && r.height > 0 {
            let s = max(w / r.width, ht / r.height)
            w = max(r.width * s, m); ht = max(r.height * s, m)
            if h.unit.x == 0 { minX = maxX - w } else { maxX = minX + w }
            if h.unit.y == 0 { minY = maxY - ht } else { maxY = minY + ht }
        }
        var copy = self
        copy.frame = placing(CGRect(x: minX, y: minY, width: w, height: ht))
        return copy
    }

    /// Rognage à la poignée `h` amenée en `pointer` (monde) : le bord suit le pointeur, sans sortir de l'image.
    func cropped(handle h: BackgroundHandle, to pointer: CGPoint) -> BackgroundImage {
        let q = toLocal(pointer)
        let full = uncroppedFrame
        guard full.width > 0, full.height > 0 else { return self }
        var d = displayCrop
        let keep = CropInsets.minimumVisible
        func fx(_ x: CGFloat) -> Double { Double((x - full.minX) / full.width) }
        func fy(_ y: CGFloat) -> Double { Double((y - full.minY) / full.height) }
        if h.unit.x == 0 { d.left = min(max(fx(q.x), 0), 1 - d.right - keep) }
        if h.unit.x == 1 { d.right = min(max(1 - fx(q.x), 0), 1 - d.left - keep) }
        if h.unit.y == 0 { d.top = min(max(fy(q.y), 0), 1 - d.bottom - keep) }
        if h.unit.y == 1 { d.bottom = min(max(1 - fy(q.y), 0), 1 - d.top - keep) }
        return withCrop(crop(fromDisplay: d))
    }

    /// Mise à l'échelle uniforme autour d'un point du monde (étalonnage) : ce point reste fixe.
    func scaled(by f: CGFloat, around p: CGPoint) -> BackgroundImage {
        guard f.isFinite, f > 0 else { return self }
        var copy = self
        let c = CGPoint(x: p.x + (center.x - p.x) * f, y: p.y + (center.y - p.y) * f)
        let w = frame.width * f, h = frame.height * f
        copy.frame = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        return copy
    }

    /// Nouvelle taille du cadre, centre conservé.
    func withSize(_ size: CGSize) -> BackgroundImage {
        var copy = self
        let w = max(size.width, Self.minimumSize), h = max(size.height, Self.minimumSize)
        copy.frame = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        return copy
    }

    /// Taille d'origine : résolution du fichier image (partie visible), centre conservé.
    var atNaturalSize: BackgroundImage {
        let d = crop
        return withSize(CGSize(width: naturalSize.width * CGFloat(1 - d.left - d.right),
                               height: naturalSize.height * CGFloat(1 - d.top - d.bottom)))
    }

    /// Ajustée à la feuille : la plus grande taille qui tient dans `sheet`, centrée, proportions conservées.
    func fitted(in sheet: CGRect) -> BackgroundImage {
        let b = bounds
        guard b.width > 0, b.height > 0, sheet.width > 0, sheet.height > 0 else { return self }
        let f = min(sheet.width / b.width, sheet.height / b.height)
        var copy = scaled(by: f, around: center)
        copy.frame = copy.frame.offsetBy(dx: sheet.midX - center.x, dy: sheet.midY - center.y)
        return copy
    }

    /// Agrandit ou réduit l'image autour de l'origine de la feuille (changement d'échelle de la page).
    func rescaled(by f: CGFloat) -> BackgroundImage {
        var copy = self
        copy.frame = CGRect(x: frame.minX * f, y: frame.minY * f, width: frame.width * f, height: frame.height * f)
        return copy
    }

    static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Lecture et contrôle des images

enum BackgroundImageError: LocalizedError {
    case unreadable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Ce fichier n'est pas une image lisible."
        case .tooLarge: return "L'image est trop volumineuse (25 Mo au plus une fois enregistrée)."
        }
    }
}

enum BackgroundImageIO {
    /// Taille maximale des octets incorporés (une image), et de toutes les images d'un document.
    static let maxBytes = 25 * 1024 * 1024
    static let maxTotalBytes = 120 * 1024 * 1024
    /// Côté maximal (pixels) : les images plus grandes sont réduites à l'import.
    static let maxPixelSide = 8192
    /// Nombre maximal de pixels d'une image incorporée (protection contre les images piégées).
    static let maxPixelCount = 80_000_000
    /// Formes acceptées dans un fichier .cad2d.
    static let storedTypes: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier]

    struct Info {
        var pixelWidth: Int
        var pixelHeight: Int
        var type: String
        /// Résolution (points par pouce), 72 si absente.
        var dpiX: Double
        var dpiY: Double
        var orientation: Int
        var hasAlpha: Bool
    }

    /// Lit l'en-tête de l'image sans la décoder.
    static func info(_ data: Data) -> Info? {
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) >= 1, let type = CGImageSourceGetType(src) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        func dpi(_ key: CFString) -> Double {
            guard let v = (props[key] as? NSNumber)?.doubleValue, v.isFinite, (1...10_000).contains(v) else { return 72 }
            return v
        }
        return Info(pixelWidth: w, pixelHeight: h, type: type, dpiX: dpi(kCGImagePropertyDPIWidth),
                    dpiY: dpi(kCGImagePropertyDPIHeight),
                    orientation: (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
                    hasAlpha: (props[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false)
    }

    /// Données d'image acceptables dans un document : PNG ou JPEG, dimensions raisonnables, orientation normale.
    static func isAcceptable(_ data: Data) -> Bool {
        guard data.count <= maxBytes, let i = info(data) else { return false }
        return storedTypes.contains(i.type) && i.pixelWidth <= maxPixelSide * 2 && i.pixelHeight <= maxPixelSide * 2
            && i.pixelWidth * i.pixelHeight <= maxPixelCount && i.orientation == 1
    }

    /// Prépare un fichier image pour l'incorporer : orientation appliquée, côté limité à 8 192 pixels,
    /// enregistrée en PNG (transparence) ou JPEG (photo). Les PNG et JPEG déjà conformes sont gardés tels quels.
    /// Retourne aussi la taille d'origine en points (selon la résolution du fichier).
    static func prepare(_ data: Data) throws -> (data: Data, naturalSize: CGSize) {
        guard data.count <= 200 * 1024 * 1024, let i = info(data) else { throw BackgroundImageError.unreadable }
        let rotated = (5...8).contains(i.orientation)
        // Taille d'origine (points) : pixels × 72 / dpi, orientation comprise.
        var natural = CGSize(width: Double(i.pixelWidth) * 72 / i.dpiX, height: Double(i.pixelHeight) * 72 / i.dpiY)
        if rotated { natural = CGSize(width: natural.height, height: natural.width) }
        let longest = max(i.pixelWidth, i.pixelHeight)
        if storedTypes.contains(i.type), i.orientation == 1, longest <= maxPixelSide,
           i.pixelWidth * i.pixelHeight <= maxPixelCount, data.count <= maxBytes {
            return (data, natural)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw BackgroundImageError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, maxPixelSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw BackgroundImageError.unreadable
        }
        let out = NSMutableData()
        let type = i.hasAlpha ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            throw BackgroundImageError.unreadable
        }
        let props: [CFString: Any] = i.hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BackgroundImageError.unreadable }
        let result = out as Data
        guard result.count <= maxBytes else { throw BackgroundImageError.tooLarge }
        return (result, natural)
    }

    /// Nouvelle image d'arrière-plan, ajustée à la feuille et centrée.
    static func makeBackground(from data: Data, name: String, sheet: CGRect) throws -> BackgroundImage {
        let prepared = try prepare(data)
        guard let i = info(prepared.data) else { throw BackgroundImageError.unreadable }
        // Proportions : celles des pixels, la résolution d'origine pouvant différer selon l'axe.
        let size = prepared.naturalSize.width > 0 && prepared.naturalSize.height > 0
            ? prepared.naturalSize : CGSize(width: i.pixelWidth, height: i.pixelHeight)
        let bg = BackgroundImage(data: prepared.data, name: String(name.prefix(DiagramIO.maxNameLength)),
                                 naturalSize: size, frame: CGRect(origin: .zero, size: size))
        return bg.fitted(in: sheet.insetBy(dx: sheet.width * 0.02, dy: sheet.height * 0.02))
    }

    static func mimeType(_ data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}

// MARK: - Cache des images décodées

/// Images décodées, par identifiant d'image : le décodage n'a lieu qu'une fois (canevas, export).
final class BackgroundImageCache: @unchecked Sendable {
    static let shared = BackgroundImageCache()

    private let lock = NSLock()
    private var images: [UUID: CGImage] = [:]
    private var order: [UUID] = []
    private var crops: [String: CGImage] = [:]
    private let capacity = 6

    func image(_ bg: BackgroundImage) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let img = images[bg.imageID] { return img }
        guard BackgroundImageIO.isAcceptable(bg.data),
              let src = CGImageSourceCreateWithData(bg.data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        images[bg.imageID] = img
        order.append(bg.imageID)
        if order.count > capacity {
            let evicted = order.removeFirst()
            images[evicted] = nil
            crops = crops.filter { !$0.key.hasPrefix(evicted.uuidString) }
        }
        return img
    }

    /// Partie visible de l'image (rognage appliqué), sans retournement.
    func croppedImage(_ bg: BackgroundImage) -> CGImage? {
        guard let full = image(bg) else { return nil }
        if bg.crop.isNone { return full }
        let c = bg.crop
        let key = "\(bg.imageID.uuidString)|\(c.left)|\(c.top)|\(c.right)|\(c.bottom)"
        lock.lock(); defer { lock.unlock() }
        if let img = crops[key] { return img }
        let w = CGFloat(full.width), h = CGFloat(full.height)
        let rect = CGRect(x: (CGFloat(c.left) * w).rounded(), y: (CGFloat(c.top) * h).rounded(),
                          width: max((CGFloat(1 - c.left - c.right) * w).rounded(), 1),
                          height: max((CGFloat(1 - c.top - c.bottom) * h).rounded(), 1))
        guard let img = full.cropping(to: rect) else { return nil }
        if crops.count > 24 { crops.removeAll() }
        crops[key] = img
        return img
    }
}

// MARK: - Dessin

extension DiagramPainter {
    /// L'image d'arrière-plan est-elle dessinée (visible ; à l'export : incluse à l'impression) ?
    var drawnBackground: BackgroundImage? {
        guard let bg = diagram.backgroundImage, bg.visible, !forExport || bg.printable else { return nil }
        return bg
    }

    /// Image d'arrière-plan, sous la grille et les formes.
    func drawBackground(_ ctx: inout GraphicsContext) {
        guard let bg = drawnBackground else { return }
        if let viewport, !toScreen(bg.bounds).intersects(viewport) { return }
        drawBackgroundImage(bg, uncropped: false, opacity: 1 - bg.transparency, in: &ctx)
    }

    /// Dessine l'image (partie visible, ou image entière pour le rognage) avec rotation et retournements.
    func drawBackgroundImage(_ bg: BackgroundImage, uncropped: Bool, opacity: Double, in ctx: inout GraphicsContext) {
        let cache = BackgroundImageCache.shared
        guard opacity > 0, let img = uncropped ? cache.image(bg) : cache.croppedImage(bg) else { return }
        let r = toScreen(bg.frame)
        let local = uncropped ? bg.uncroppedFrame : bg.frame
        // Rectangle à dessiner, relatif au centre du cadre (repère pivoté).
        let target = CGRect(x: (local.minX - bg.frame.midX) * zoom, y: (local.minY - bg.frame.midY) * zoom,
                            width: local.width * zoom, height: local.height * zoom)
        var c = ctx
        c.opacity = opacity
        c.translateBy(x: r.midX, y: r.midY)
        if bg.rotation != 0 { c.rotate(by: .radians(Double(bg.angle))) }
        c.translateBy(x: target.midX, y: target.midY)
        c.scaleBy(x: bg.flipHorizontal ? -1 : 1, y: bg.flipVertical ? -1 : 1)
        c.draw(Image(decorative: img, scale: 1),
               in: CGRect(x: -target.width / 2, y: -target.height / 2, width: target.width, height: target.height))
    }
}

// MARK: - Commandes

@MainActor
extension DocumentStore {
    var hasBackgroundImage: Bool { doc.backgroundImage != nil }

    /// Image présente et modifiable (non verrouillée).
    var canEditBackground: Bool { doc.backgroundImage.map { !$0.locked } ?? false }

    /// Insertion > Image d'arrière-plan : choisir un fichier image (remplace l'image existante).
    func chooseBackgroundImage() {
        if editingShapeID != nil { commitTextEditing() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = hasBackgroundImage
            ? "L'image choisie remplace l'image d'arrière-plan de la page (position et réglages conservés)."
            : "L'image est placée sous le dessin de la page affichée, ajustée à la feuille."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > 200 * 1024 * 1024 { throw BackgroundImageError.tooLarge }
            try setBackgroundImage(data: Data(contentsOf: url), name: url.lastPathComponent)
        } catch {
            showError("Impossible d'insérer l'image", error)
        }
    }

    /// Pose (ou remplace) l'image d'arrière-plan de la page affichée. Une image remplacée garde sa position,
    /// sa rotation et ses réglages ; la nouvelle tient dans la largeur de l'ancienne, sans rognage.
    func setBackgroundImage(data: Data, name: String) throws {
        var bg = try BackgroundImageIO.makeBackground(from: data, name: name, sheet: doc.sheetRect)
        if let old = doc.backgroundImage {
            let size = bg.naturalSize
            let w = old.frame.width, h = w * size.height / max(size.width, 1e-9)
            bg.frame = CGRect(x: old.center.x - w / 2, y: old.center.y - h / 2, width: w, height: h)
            bg.rotation = old.rotation
            bg.flipHorizontal = old.flipHorizontal
            bg.flipVertical = old.flipVertical
            bg.transparency = old.transparency
            bg.printable = old.printable
            bg.keepAspectRatio = old.keepAspectRatio
        }
        var updated = doc
        updated.backgroundImage = bg
        var check = document
        check.pages[currentPage] = updated
        try DiagramIO.validate(check)
        let result = bg
        perform { $0.backgroundImage = result }
    }

    func removeBackgroundImage() {
        backgroundMode = nil
        perform { $0.backgroundImage = nil }
    }

    /// Modification de l'image depuis le volet ou le ruban (frappes successives regroupées).
    /// Une image verrouillée n'accepte que le déverrouillage et les réglages d'affichage.
    func editBackground(key: String, allowLocked: Bool = false, _ change: (inout BackgroundImage) -> Void) {
        guard var bg = doc.backgroundImage, allowLocked || !bg.locked else { return }
        change(&bg)
        guard (try? DiagramIO.validate(bg)) != nil else { NSSound.beep(); return }
        let result = bg
        editPage(key: "background-\(key)") { $0.backgroundImage = result }
        if result.locked { backgroundMode = nil }
    }

    /// Passe en mode d'édition de l'image (ou le quitte s'il est déjà actif).
    func toggleBackgroundMode(_ mode: BackgroundEditMode) {
        guard canEditBackground else { NSSound.beep(); return }
        if backgroundMode == mode { backgroundMode = nil; return }
        if editingShapeID != nil { commitTextEditing() }
        tool = .select
        selection = []
        if doc.backgroundImage?.visible == false { editBackground(key: "visible") { $0.visible = true } }
        backgroundMode = mode
    }

    func nudgeBackground(dx: CGFloat, dy: CGFloat) {
        editBackground(key: "nudge") { $0.frame = $0.frame.offsetBy(dx: dx, dy: dy) }
    }

    func rotateBackground(by degrees: Double) {
        editBackground(key: "rotate-\(UUID())") { $0.rotation = normalizedAngle($0.rotation + degrees) }
    }

    func fitBackgroundToSheet() {
        let sheet = doc.sheetRect
        editBackground(key: "fit-\(UUID())") { $0 = $0.fitted(in: sheet) }
    }

    func resetBackgroundSize() {
        editBackground(key: "natural-\(UUID())") { $0 = $0.atNaturalSize }
    }

    func resetBackgroundCrop() {
        editBackground(key: "uncrop-\(UUID())") { $0 = $0.withCrop(.none) }
    }

    // MARK: Étalonnage

    /// Point cliqué en mode Étalonner : au second point, la distance réelle est demandée.
    func addCalibrationPoint(_ p: CGPoint) {
        guard backgroundMode == .calibrate else { return }
        if calibrationPoints.isEmpty { calibrationPoints = [p]; return }
        let a = calibrationPoints[0]
        calibrationPoints = []
        guard a.distance(to: p) * zoom >= 3 else { NSSound.beep(); return }
        let d = doc
        let current = Diagram.format(d.measure(a.distance(to: p)), decimals: max(d.precision, 2))
        let alert = NSAlert()
        alert.messageText = "Étalonner l'image d'arrière-plan"
        alert.informativeText = "Distance actuelle entre les deux points : \(current) \(d.unit.symbol).\n"
            + "Tapez leur distance réelle (\(d.unit.label.lowercased()), échelle 1:\(Diagram.format(d.scale, decimals: 4)) comprise) : "
            + "l'image est agrandie ou réduite autour du premier point."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.placeholderString = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Étalonner")
        alert.addButton(withTitle: "Annuler")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = NumericField.parse(field.stringValue), calibrateBackground(from: a, to: p, measure: value) else {
            NSSound.beep(); return
        }
        backgroundMode = .adjust
    }

    /// Met l'image à l'échelle pour que la distance a–b vaille `measure` (unité et échelle de la page).
    @discardableResult
    func calibrateBackground(from a: CGPoint, to b: CGPoint, measure: Double) -> Bool {
        let current = a.distance(to: b)
        let target = doc.worldLength(forMeasure: measure)
        guard canEditBackground, current > 1e-9, measure > 0, target.isFinite, target > 0 else { return false }
        let f = target / current
        guard let bg = doc.backgroundImage, (try? DiagramIO.validate(bg.scaled(by: f, around: a))) != nil else { return false }
        editBackground(key: "calibrate-\(UUID())") { $0 = $0.scaled(by: f, around: a) }
        return true
    }
}
