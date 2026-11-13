// Génère l'icône de My2DCAD (PNG 1024 × 1024) : feuille quadrillée sur fond bleu, avec un
// rectangle, une ellipse, un connecteur et une cote, dans l'esprit de Visio.
// Usage : swift scripts/make-icon.swift <fichier.png>

import AppKit
import CoreGraphics

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("contexte graphique indisponible")
}
// Repère avec l'origine en haut à gauche, comme dans l'application.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Fond : carré arrondi (grille des icônes macOS : 824 px centrés, rayon ≈ 185 px), dégradé bleu.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x2B579A))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x3C78D8), color(0x1F4E8C)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.restoreGState()

// Feuille blanche quadrillée.
let sheet = CGRect(x: 210, y: 220, width: 604, height: 600)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: color(0x000000, 0.3))
ctx.setFillColor(color(0xFFFFFF))
ctx.fill(sheet)
ctx.restoreGState()
ctx.setStrokeColor(color(0x9DB7DE, 0.55))
ctx.setLineWidth(2)
var x = sheet.minX + 40
while x < sheet.maxX { ctx.move(to: CGPoint(x: x, y: sheet.minY)); ctx.addLine(to: CGPoint(x: x, y: sheet.maxY)); x += 40 }
var y = sheet.minY + 40
while y < sheet.maxY { ctx.move(to: CGPoint(x: sheet.minX, y: y)); ctx.addLine(to: CGPoint(x: sheet.maxX, y: y)); y += 40 }
ctx.strokePath()

// Rectangle (processus) et ellipse, reliés par un connecteur orthogonal fléché.
let box = CGRect(x: 270, y: 300, width: 220, height: 140)
ctx.setFillColor(color(0xDDEBFD))
ctx.fill(box)
ctx.setStrokeColor(color(0x2B579A))
ctx.setLineWidth(10)
ctx.stroke(box)
let circle = CGRect(x: 560, y: 520, width: 190, height: 190)
ctx.setFillColor(color(0xFCE4C4))
ctx.fillEllipse(in: circle)
ctx.setStrokeColor(color(0xD9822B))
ctx.strokeEllipse(in: circle)

ctx.setStrokeColor(color(0x333333))
ctx.setLineWidth(8)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: box.maxX, y: box.midY))
ctx.addLine(to: CGPoint(x: circle.midX, y: box.midY))
ctx.addLine(to: CGPoint(x: circle.midX, y: circle.minY - 26))
ctx.strokePath()
ctx.setFillColor(color(0x333333))
ctx.move(to: CGPoint(x: circle.midX, y: circle.minY - 2))
ctx.addLine(to: CGPoint(x: circle.midX - 22, y: circle.minY - 40))
ctx.addLine(to: CGPoint(x: circle.midX + 22, y: circle.minY - 40))
ctx.closePath()
ctx.fillPath()

// Cote horizontale sous le rectangle.
let dimY: CGFloat = 520
ctx.setStrokeColor(color(0xC0392B))
ctx.setLineWidth(6)
ctx.move(to: CGPoint(x: box.minX, y: box.maxY + 20)); ctx.addLine(to: CGPoint(x: box.minX, y: dimY + 30))
ctx.move(to: CGPoint(x: box.maxX, y: box.maxY + 20)); ctx.addLine(to: CGPoint(x: box.maxX, y: dimY + 30))
ctx.move(to: CGPoint(x: box.minX, y: dimY)); ctx.addLine(to: CGPoint(x: box.maxX, y: dimY))
ctx.strokePath()
ctx.setFillColor(color(0xC0392B))
for (tip, dir) in [(box.minX, CGFloat(1)), (box.maxX, CGFloat(-1))] {
    ctx.move(to: CGPoint(x: tip, y: dimY))
    ctx.addLine(to: CGPoint(x: tip + dir * 30, y: dimY - 13))
    ctx.addLine(to: CGPoint(x: tip + dir * 30, y: dimY + 13))
    ctx.closePath()
    ctx.fillPath()
}

// Équerre en bas à gauche.
ctx.setFillColor(color(0xF2C94C, 0.9))
ctx.setStrokeColor(color(0x8A6D1F))
ctx.setLineWidth(6)
let square = CGMutablePath()
square.move(to: CGPoint(x: 260, y: 770))
square.addLine(to: CGPoint(x: 260, y: 600))
square.addLine(to: CGPoint(x: 430, y: 770))
square.closeSubpath()
square.move(to: CGPoint(x: 295, y: 735))
square.addLine(to: CGPoint(x: 295, y: 685))
square.addLine(to: CGPoint(x: 345, y: 735))
square.closeSubpath()
ctx.addPath(square)
ctx.drawPath(using: .eoFillStroke)

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("image impossible à produire")
}
try png.write(to: URL(fileURLWithPath: output))
print("Icône écrite : \(output)")
