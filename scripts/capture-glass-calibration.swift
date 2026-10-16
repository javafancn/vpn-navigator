import AppKit

// CI-only desktop fixtures, never copied into the application bundle.
// Different external colours must show through the same unchanged app UI.
let modes: [String: [NSColor]] = [
    "cool": [NSColor(calibratedRed: 0.24, green: 0.40, blue: 0.66, alpha: 1),
             NSColor(calibratedRed: 0.65, green: 0.78, blue: 0.90, alpha: 1)],
    "warm": [NSColor(calibratedRed: 0.67, green: 0.37, blue: 0.25, alpha: 1),
             NSColor(calibratedRed: 0.91, green: 0.72, blue: 0.57, alpha: 1)]
]
guard CommandLine.arguments.count == 3,
      let colours = modes[CommandLine.arguments[1]] else {
    fatalError("Usage: capture-glass-calibration.swift cool|warm OUTPUT_FOLDER")
}
let name = CommandLine.arguments[1]
let size = NSSize(width: 1600, height: 1000)
let image = NSImage(size: size)
image.lockFocus()
for row in 0..<5 {
    for column in 0..<8 {
        colours[(row + column) % 2].setFill()
        NSBezierPath(rect: NSRect(x: CGFloat(column * 200), y: CGFloat(row * 200), width: 200, height: 200)).fill()
    }
}
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode calibration wallpaper")
}
let path = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    .appendingPathComponent("VPNNavigator-wallpaper-\(name).png")
try png.write(to: path)
for screen in NSScreen.screens {
    try NSWorkspace.shared.setDesktopImageURL(path, for: screen, options: [:])
}
print("External desktop calibration: \(name)")
