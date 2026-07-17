//
//  LiveCaptionsSyphonPublisher.swift
//  Fluid
//
//  Publishes the live captions text — no background, alpha channel intact —
//  as a Syphon video source, so other apps on the same Mac (OBS via its
//  Syphon plugin, VDMX, Resolume, QLab, etc.) can composite it directly.
//
//  Renders LiveCaptionsSyphonContentView (a separate, static view type from
//  the live on-screen window's LiveCaptionsTextContentView) via ImageRenderer,
//  only when the caption text actually changes rather than on a fixed timer —
//  publishing unchanged frames at a fixed rate was found to starve the
//  on-screen NSHostingView's own SwiftUI render pass (the window would stop
//  showing text while Syphon was active), since both were polling/rendering
//  concurrently on the main actor.
//

import Combine
import Metal
import MetalKit
import SwiftUI

@MainActor
final class LiveCaptionsSyphonPublisher {
    static let shared = LiveCaptionsSyphonPublisher()

    /// Coalesces rapid word-by-word updates into one render instead of one per word.
    private let publishDebounce: TimeInterval = 0.12

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureLoader: MTKTextureLoader?
    private var server: SyphonMetalServer?
    private var textChangeSubscription: AnyCancellable?
    private let renderer: ImageRenderer<LiveCaptionsSyphonContentView>

    private init() {
        self.renderer = ImageRenderer(content: LiveCaptionsSyphonContentView())
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
        self.textureLoader = nil
        self.commandQueue = nil
        self.device = nil
    }

    private func publishFrame() {
        guard let server = self.server,
              let commandQueue = self.commandQueue,
              let textureLoader = self.textureLoader
        else { return }

        self.renderer.content = LiveCaptionsSyphonContentView()

        guard let cgImage = self.renderer.cgImage else { return }
        guard let texture = try? textureLoader.newTexture(cgImage: cgImage, options: [.SRGB: false]) else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let region = NSRect(x: 0, y: 0, width: texture.width, height: texture.height)
        server.publishFrameTexture(texture, on: commandBuffer, imageRegion: region, flipped: true)
        commandBuffer.commit()
    }
}
