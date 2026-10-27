import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let nodes: [(CGFloat, CGFloat, CGFloat)] = [
    (500, 515, 66), (280, 675, 35), (716, 714, 43), (775, 405, 34),
    (540, 255, 39), (239, 366, 43), (417, 814, 23)
]
let edges = [(0,1),(0,2),(0,3),(0,4),(0,5),(1,6),(2,6),(3,4),(1,5)]

for pointSize in [16,32,128,256,512] {
    for scale in [1,2] {
        let size = pointSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        let base = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 206, yRadius: 206)
        NSGradient(starting: NSColor(srgbRed: 0.14, green: 0.20, blue: 0.21, alpha: 1),
                   ending: NSColor(srgbRed: 0.065, green: 0.082, blue: 0.09, alpha: 1))!.draw(in: base, angle: -75)
        NSColor(srgbRed: 0.34, green: 0.48, blue: 0.47, alpha: 0.8).setStroke()
        for (a,b) in edges {
            let path = NSBezierPath()
            path.lineWidth = 10
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: nodes[a].0, y: nodes[a].1))
            path.line(to: NSPoint(x: nodes[b].0, y: nodes[b].1))
            path.stroke()
        }
        for (index,node) in nodes.enumerated() {
            let color = index == 0 ? NSColor(srgbRed: 0.65, green: 0.88, blue: 0.81, alpha: 1)
                                  : NSColor(srgbRed: 0.48, green: 0.69, blue: 0.65, alpha: 1)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: node.0-node.2, y: node.1-node.2, width: node.2*2, height: node.2*2)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
