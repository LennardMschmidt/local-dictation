// Draws the app icon as a 1024x1024 PNG in the look of the idle bar: a dark capsule with a faint
// light border and the white waveform symbol, on a dark rounded square. macOS 26 and later put an
// icon that does not fill the square onto a light grey plate, so the square is drawn here.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let output = CommandLine.arguments[1]
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset = size * 0.1
let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                        xRadius: size * 0.18, yRadius: size * 0.18)
NSGradient(starting: NSColor(white: 0.13, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))!.draw(in: tile, angle: -90)

let pill = NSRect(x: size * 0.18, y: size * 0.355, width: size * 0.64, height: size * 0.29)
let capsule = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
NSGradient(starting: NSColor(white: 0.22, alpha: 1), ending: NSColor(white: 0.14, alpha: 1))!.draw(in: capsule, angle: -90)
capsule.lineWidth = size * 0.008
NSColor(white: 1, alpha: 0.35).setStroke()
capsule.stroke()

let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.18, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: pill.midY - s.height / 2, width: s.width, height: s.height))
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
