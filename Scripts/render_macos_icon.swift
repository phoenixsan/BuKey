import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: render_macos_icon <input.png> <output.png>\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL

guard let source = CGImageSourceCreateWithURL(inputURL, nil),
      let input = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: 1024,
        height: 1024,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    fputs("Unable to create icon rendering context.\n", stderr)
    exit(1)
}

context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high

let inset: CGFloat = 64
let extent: CGFloat = 1024 - inset * 2
let center = CGPoint(x: 512, y: 512)
let radius = extent / 2
let exponent: CGFloat = 5.0
let steps = 512
let squircle = CGMutablePath()

for index in 0...steps {
    let angle = CGFloat(index) / CGFloat(steps) * .pi * 2
    let cosine = cos(angle)
    let sine = sin(angle)
    let x = center.x + radius * (cosine < 0 ? -1 : 1) * pow(abs(cosine), 2 / exponent)
    let y = center.y + radius * (sine < 0 ? -1 : 1) * pow(abs(sine), 2 / exponent)
    if index == 0 { squircle.move(to: CGPoint(x: x, y: y)) }
    else { squircle.addLine(to: CGPoint(x: x, y: y)) }
}
squircle.closeSubpath()

// A restrained shadow gives the legacy PNG the same optical lift as macOS icons.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -9), blur: 22,
                  color: CGColor(gray: 0, alpha: 0.22))
context.addPath(squircle)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(squircle)
context.clip()
context.draw(input, in: CGRect(x: inset, y: inset, width: extent, height: extent))
context.restoreGState()

guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("Unable to create PNG output.\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Unable to finalize PNG output.\n", stderr)
    exit(1)
}
