import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Copies Codey's idle row out of the ChatGPT app bundle into Cadence's
/// support folder. The spritesheet stays in that app; nothing is committed.
enum CodeyFrames {
    static func installIfNeeded() -> Bool {
        let destination = WidgetStore.codeyURL
        if FileManager.default.fileExists(atPath: destination.path) { return false }
        guard let webp = spritesheetData(),
              let image = CGImageSourceCreateWithData(webp as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
              let png = idleStrip(from: image) else { return false }
        try? FileManager.default.createDirectory(at: WidgetStore.directory, withIntermediateDirectories: true)
        do {
            try png.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func spritesheetData() -> Data? {
        let asar = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/app.asar")
        guard let data = try? Data(contentsOf: asar, options: .mappedIfSafe), data.count > 16 else { return nil }
        let headerCount = intLE(data, 12)
        guard headerCount > 0, 16 + headerCount <= data.count else { return nil }
        let header = data.subdata(in: 16..<(16 + headerCount))
        guard let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
              let found = findSheet(json) else { return nil }
        let base = (16 + headerCount + 3) & ~3
        let start = base + found.offset
        let end = start + found.size
        guard start >= 0, end <= data.count, found.size > 0 else { return nil }
        return data.subdata(in: start..<end)
    }

    private static func findSheet(_ node: [String: Any]) -> (offset: Int, size: Int)? {
        var best: (offset: Int, size: Int)?
        func walk(_ node: [String: Any]) {
            guard let files = node["files"] as? [String: Any] else { return }
            for (name, value) in files {
                guard let child = value as? [String: Any] else { continue }
                if name.contains("codex-spritesheet"), name.hasSuffix(".webp"),
                   let offset = integer(child["offset"]), let size = integer(child["size"]),
                   size > (best?.size ?? 0) {
                    best = (offset, size)
                }
                if child["files"] != nil { walk(child) }
            }
        }
        walk(node)
        return best
    }

    private static func idleStrip(from image: CGImage) -> Data? {
        let columns = 8
        let frameWidth = image.width / columns
        let frameHeight = image.height >= frameWidth * 11 ? image.height / 11 : image.height
        let frames = 6
        guard frameWidth > 0, frameHeight > 0, image.width >= frameWidth * frames else { return nil }
        let width = frameWidth * frames
        guard let context = CGContext(
            data: nil, width: width, height: frameHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for index in 0..<frames {
            // CGImage rows start at the top. Idle is the first row.
            let rect = CGRect(x: CGFloat(index * frameWidth), y: 0, width: CGFloat(frameWidth), height: CGFloat(frameHeight))
            guard let crop = image.cropping(to: rect) else { return nil }
            context.draw(crop, in: CGRect(x: CGFloat(index * frameWidth), y: 0, width: CGFloat(frameWidth), height: CGFloat(frameHeight)))
        }
        guard let strip = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, strip, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func intLE(_ data: Data, _ offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}
