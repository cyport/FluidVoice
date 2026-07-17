//
//  LiveCaptionsSyphonPublisher.swift
//  Fluid
//
//  Publishes the live captions text — no background, alpha channel intact —
//  as a Syphon video source, so other apps on the same Mac (OBS via its
//  Syphon plugin, VDMX, Resolume, QLab, etc.) can composite it directly.
//
//  Renders LiveCaptionsTextContentView (the same content the on-screen
//  window uses) via ImageRenderer, only when the caption text actually
//  changes rather than on a fixed timer — publishing unchanged frames at a
//  fixed rate was found to starve the on-screen NSHostingView's own SwiftUI
//  render pass, since both were polling/rendering concurrently on the main
//  actor.
//
//  Converts the rendered CGImage to an MTLTexture by copying pixel bytes
//  directly via CGContext rather than MTKTextureLoader.newTexture(cgImage:) —
//  the latter reliably fails ("Image decoding failed") for SwiftUI-rendered
//  CGImages, a known rough edge of its CGImage decoder.
//
//  Creates a fresh ImageRenderer per publish rather than reusing one
//  instance and reassigning .content — reassigning content on a reused
//  renderer isn't guaranteed to be reflected the moment .cgImage is read
//  right after, which showed up as the Syphon output visibly lagging
//  behind the on-screen window. LiveCaptionsTextContentView holds no state
//  worth preserving across renders (it's purely computed from the text
//  model), so there's no downside to a fresh instance each time.
//

import Combine
import CoreGraphics
import Metal
import SwiftUI

@MainActor
final class LiveCaptionsSyphonPublisher {
    static let shared = LiveCaptionsSyphonPublisher()

    /// Coalesces rapid word-by-word updates into one render instead of one per word.
    private let publishDebounce: TimeInterval = 0.05

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var server: SyphonMetalServer?
    private var textChangeSubscription: AnyCancellable?

    private init() {}

    /// Starts or stops the Syphon server to match the current setting. Safe
    /// to call any time — app launch, or whenever the setting changes.
    func applyEnabledState() {
        if SettingsStore.shared.liveCaptionsSyphonEnabled {
            self.start()
        } else {
            self.stop()
        }
    }

    private func start() {
        guard self.server == nil else { return }

        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
            DebugLogger.shared.error("Live Captions Syphon: no usable Metal device", source: "LiveCaptionsSyphonPublisher")
            return
        }

        self.device = device
        self.commandQueue = commandQueue
        self.server = SyphonMetalServer(name: "FluidVoice Live Captions", device: device, options: nil)

        let textModel = LiveCaptionsTextModel.shared
        self.textChangeSubscription = textModel.$renderedCommittedText
            .combineLatest(textModel.$renderedPendingText)
            .debounce(for: .seconds(self.publishDebounce), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.publishFrame()
            }

        // Publish an initial (likely blank) frame immediately so clients see
        // a valid source right away rather than waiting for the first word.
        self.publishFrame()
    }

    private func stop() {
        self.textChangeSubscription?.cancel()
        self.textChangeSubscription = nil
        self.server?.stop()
        self.server = nil
        self.commandQueue = nil
        self.device = nil
    }

    private func publishFrame() {
        guard let server = self.server, let commandQueue = self.commandQueue, let device = self.device else { return }

        let renderer = ImageRenderer(content: LiveCaptionsTextContentView())
        renderer.isOpaque = false
        renderer.scale = 2

        guard let cgImage = renderer.cgImage,
              let texture = Self.makeTexture(from: cgImage, device: device)
        else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let region = NSRect(x: 0, y: 0, width: texture.width, height: texture.height)
        server.publishFrameTexture(texture, on: commandBuffer, imageRegion: region, flipped: true)
        commandBuffer.commit()
    }

    /// Copies a CGImage's pixel bytes directly into a new BGRA8 MTLTexture —
    /// the standard native macOS video pixel format (matches
    /// kCVPixelFormatType_32BGRA / most Syphon reference implementations),
    /// for the widest client compatibility.
    private static func makeTexture(from cgImage: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)

        // premultipliedFirst + byteOrder32Little is the standard idiom for a
        // native-BGRA 32-bit bitmap context on macOS.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: &rawData, bytesPerRow: bytesPerRow)

        return texture
    }
}
