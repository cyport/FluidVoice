//
//  LiveCaptionsSyphonPublisher.swift
//  Fluid
//
//  Publishes the live captions text — no background, alpha channel intact —
//  as a Syphon video source, so other apps on the same Mac (OBS via its
//  Syphon plugin, VDMX, Resolume, etc.) can composite it directly. Renders
//  the same LiveCaptionsTextContentView used by the on-screen window, via
//  ImageRenderer, so the two outputs always match.
//

import Metal
import MetalKit
import SwiftUI

@MainActor
final class LiveCaptionsSyphonPublisher {
    static let shared = LiveCaptionsSyphonPublisher()

    /// 15fps is plenty for text that updates a few times a second at most.
    private let publishInterval: TimeInterval = 1.0 / 15.0

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureLoader: MTKTextureLoader?
    private var server: SyphonMetalServer?
    private var publishTimer: Timer?
    private let renderer: ImageRenderer<LiveCaptionsTextContentView>

    private init() {
        self.renderer = ImageRenderer(content: LiveCaptionsTextContentView())
        self.renderer.isOpaque = false
        self.renderer.scale = 2
    }

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
        self.textureLoader = MTKTextureLoader(device: device)
        self.server = SyphonMetalServer(name: "FluidVoice Live Captions", device: device, options: nil)

        self.publishTimer?.invalidate()
        let timer = Timer(timeInterval: self.publishInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.publishTimer = timer
    }

    private func stop() {
        self.publishTimer?.invalidate()
        self.publishTimer = nil
        self.server?.stop()
        self.server = nil
        self.textureLoader = nil
        self.commandQueue = nil
        self.device = nil
    }

    private func publishFrame() {
        guard let server = self.server,
              let commandQueue = self.commandQueue,
              let textureLoader = self.textureLoader
        else { return }

        // Re-point at a fresh value (not a fresh ImageRenderer) so the
        // hosted view's @State — the scroll-offset animation — carries
        // forward between ticks instead of resetting every frame.
        self.renderer.content = LiveCaptionsTextContentView()

        guard let cgImage = self.renderer.cgImage else { return }
        guard let texture = try? textureLoader.newTexture(cgImage: cgImage, options: [.SRGB: false]) else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let region = NSRect(x: 0, y: 0, width: texture.width, height: texture.height)
        server.publishFrameTexture(texture, on: commandBuffer, imageRegion: region, flipped: true)
        commandBuffer.commit()
    }
}
