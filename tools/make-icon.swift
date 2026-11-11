import AppKit
// Ícone do app: quadrado arredondado preto, símbolo branco, aro finíssimo.
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSColor(white: 0.04, alpha: 1).setFill()
path.fill()
let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
ring.lineWidth = 3
NSColor(white: 1, alpha: 0.14).setStroke()
ring.stroke()
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .light).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
  let sz = sym.size
  sym.draw(in: NSRect(x: (s - sz.width)/2, y: (s - sz.height)/2, width: sz.width, height: sz.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
