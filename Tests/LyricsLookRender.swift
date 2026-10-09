import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Renders the lyric view's layers with CARenderer, which draws what window
/// snapshots drop: blur filters, shadows and running symbol effects. Each
/// scene gets a fresh offscreen window; its layers are detached to render.
@MainActor
enum LyricsLook {
    /// Lines 0…7 repeat, line 5 being the instrumental gap. `current` is the
    /// line playing now; every line is an hour long so nothing changes.
    static func render(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scenes: [(String, current: Int, playing: Bool)] = [
            ("gap-current-paused", 5, false), ("gap-upcoming-paused", 4, false),
            ("gap-sung-paused", 6, false), ("gap-current-playing", 5, true),
        ]
        for scene in scenes {
            let player = PlayerModel(), lyrics = LyricsModel()
            player.isPlaying = scene.playing
            let now = player.positionMs(at: Date()) / 1_000
            lyrics.fixture(from: now - Double(scene.current) * 3_600 - 1, every: 3_600)
            player.seek(toMs: player.positionMs(at: Date()))
            let size = CGSize(width: 430, height: 760)
            let window = OffscreenWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: LyricsView().environment(player).environment(lyrics)
                .preferredColorScheme(.dark).background(Color(red: 0.04, green: 0.05, blue: 0.065)))
            window.contentView = host
            window.orderFrontRegardless()
            window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
            try? await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // Two moments 0.9 s apart (about half a breath): they differ only if the "…" breathes.
            let now2 = CACurrentMediaTime()
            let frames = [now2, now2 + 0.9].map { render(host.layer!, size: size, at: $0) }
            write(frames[0], to: directory.appendingPathComponent("\(scene.0).png"))
            if scene.playing { write(frames[1], to: directory.appendingPathComponent("\(scene.0)-later.png")) }
            let changed = zip(frames[0].bytes, frames[1].bytes).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            print("LOOK \(scene.0): \(changed) bytes differ between the two moments, "
                  + "\(animations(in: host.layer!)) Core Animation animations running")
            window.close()
        }
    }

    /// Animations Core Animation runs on its own, such as an AppKit symbol effect.
    static func animations(in layer: CALayer) -> Int {
        (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animations(in: $1) }
    }

    struct Frame {
        let width: Int, height: Int
        let bytes: [UInt8]
    }

    /// At 2x, so text and glows compare with the app's Retina renders.
    static func render(_ layer: CALayer, size: CGSize, at time: CFTimeInterval) -> Frame {
        let scale: CGFloat = 2
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor.black.cgColor
        root.isGeometryFlipped = true // AppKit hosts the view top-down
        let parent = layer.superlayer, frame = layer.frame
        layer.removeFromSuperlayer()
        layer.frame = root.bounds
        root.addSublayer(layer)
        root.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
        root.anchorPoint = .zero
        root.frame = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))

        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.flush()
        renderer.beginFrame(atTime: time, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let rowBytes = width * 4
        let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared)!
        let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                  destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let bytes = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self),
                                              count: buffer.length))
        layer.removeFromSuperlayer()
        layer.frame = frame
        parent?.addSublayer(layer)
        return Frame(width: width, height: height, bytes: bytes)
    }

    static func write(_ frame: Frame, to url: URL) {
        // BGRA from Metal; Core Graphics reads it as little-endian ARGB.
        var bytes = frame.bytes
        let image = bytes.withUnsafeMutableBytes { pointer -> CGImage? in
            CGContext(data: pointer.baseAddress, width: frame.width, height: frame.height, bitsPerComponent: 8,
                      bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
        guard let image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("[look] \(url.path)")
    }
}
