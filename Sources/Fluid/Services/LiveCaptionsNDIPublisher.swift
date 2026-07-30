//
//  LiveCaptionsNDIPublisher.swift
//  Fluid
//
//  Publishes the live captions text — no background, alpha channel intact —
//  as an NDI video source, so other apps on the same network (OBS, vMix,
//  QLab, etc.) can composite it directly. Replaces the earlier Syphon
//  integration (removed after persistent client-compatibility issues).
//
//  NDI's SDK ships as headers + a dylib, no official Swift wrapper, and no
//  prebuilt xcframework — the standard integration pattern (matching NDI's
//  own Processing.NDI.DynamicLoad.h reference example) is to dlopen the
//  dylib at runtime and resolve NDIlib_v6_load via dlsym, rather than link
//  against it at build time. That also sidesteps needing to add a new
//  binary-linking build phase to the Xcode project (risky to hand-edit;
//  Xcode's synchronized-group auto-inclusion, which the rest of this
//  project's new files rely on, only auto-copies plain resources — a
//  vendored .dylib was confirmed NOT to get embedded that way).
//
//  Tries a path relative to the app bundle first (in case a future build
//  step embeds libndi.dylib inside Contents/Frameworks), then falls back
//  to the NDI SDK's own install location — present on this machine since
//  the SDK was installed directly from ndi.video. A machine without either
//  simply won't have NDI output available; the toggle silently no-ops.
//
//  Renders LiveCaptionsTextContentView (the same content the on-screen
//  window uses) via ImageRenderer, event-driven on text changes rather than
//  a continuous fixed-rate render loop — the same lesson learned from the
//  Syphon publisher, which found that starves the on-screen window's own
//  SwiftUI render pass. A low-rate heartbeat (heartbeatInterval) still
//  publishes on a timer even when text is static, so the NDI stream never
//  goes fully silent — see its doc comment for why that matters.
//

import Combine
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class LiveCaptionsNDIPublisher {
    static let shared = LiveCaptionsNDIPublisher()

    /// Coalesces rapid word-by-word updates into one send instead of one per word.
    private let publishDebounce: TimeInterval = 0.05
    /// A frame goes out at least this often even when caption text hasn't
    /// changed at all — including while captions are faded out/idle. Without
    /// this, publishFrame() only fires on text changes (see
    /// textChangeSubscription below), so any stretch where text is static —
    /// an inactivity fade, a pause between sentences, or just no one
    /// speaking — meant NDI simply stopped sending anything. NDI receivers
    /// like QLab appear to time a source out and drop it after a stretch
    /// with no frames at all, which is what looked like "the signal cuts
    /// out when captions fade" — the on-screen window's fade and NDI's own
    /// rendering are already two separate pipelines (NDI renders
    /// LiveCaptionsTextContentView directly, not the window), so it was
    /// never the window's opacity animation itself; it was this silence.
    private let heartbeatInterval: TimeInterval = 1.0

    private var libraryHandle: UnsafeMutableRawPointer?
    private var ndiLib: UnsafePointer<NDIlib_v6>?
    private var sender: NDIlib_send_instance_t?
    private var textChangeSubscription: AnyCancellable?
    private var heartbeatTimer: Timer?

    private init() {}

    /// Starts or stops the NDI sender to match the current setting. Safe to
    /// call any time — app launch, or whenever the setting changes.
    func applyEnabledState() {
        if SettingsStore.shared.liveCaptionsNDIEnabled {
            self.start()
        } else {
            self.stop()
        }
    }

    private func start() {
        guard self.sender == nil else { return }

        guard self.loadLibraryIfNeeded(), let ndiLib = self.ndiLib else {
            DebugLogger.shared.error("Live Captions NDI: could not load libndi.dylib", source: "LiveCaptionsNDIPublisher")
            return
        }

        guard ndiLib.pointee.initialize() else {
            DebugLogger.shared.error("Live Captions NDI: NDIlib_initialize failed (CPU may not support NDI)", source: "LiveCaptionsNDIPublisher")
            return
        }

        let created: NDIlib_send_instance_t? = "FluidVoice Live Captions".withCString { namePtr in
            var createSettings = NDIlib_send_create_t()
            createSettings.p_ndi_name = namePtr
            createSettings.p_groups = nil
            // Not clocking to either — captions publish sporadically as text
            // changes, not at a steady frame rate, and clocking would block
            // the calling thread trying to maintain one.
            createSettings.clock_video = false
            createSettings.clock_audio = false
            return ndiLib.pointee.send_create(&createSettings)
        }

        guard let created else {
            DebugLogger.shared.error("Live Captions NDI: send_create failed", source: "LiveCaptionsNDIPublisher")
            return
        }
        self.sender = created

        let textModel = LiveCaptionsTextModel.shared
        self.textChangeSubscription = Publishers.Merge(
            textModel.$renderedCommittedText.map { _ in () },
            textModel.$renderedPendingText.map { _ in () }
        )
        .debounce(for: .seconds(self.publishDebounce), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.publishFrame()
        }

        self.heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.heartbeatTimer = timer

        // Publish an initial (likely blank) frame immediately so clients see
        // a valid source right away rather than waiting for the first word.
        self.publishFrame()
    }

    private func stop() {
        self.textChangeSubscription?.cancel()
        self.textChangeSubscription = nil
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil

        if let sender, let ndiLib = self.ndiLib {
            ndiLib.pointee.send_destroy(sender)
        }
        self.sender = nil
        // Deliberately not calling ndiLib.pointee.destroy() or dlclose —
        // NDI's own examples call destroy() once at process exit, not on
        // every stop/restart, and repeated init/destroy cycles within one
        // process aren't a pattern their docs exercise. Re-enabling just
        // re-creates the sender against the already-initialized library.
    }

    private func loadLibraryIfNeeded() -> Bool {
        if self.ndiLib != nil { return true }

        let candidatePaths = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libndi.dylib").path,
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        ].compactMap { $0 }

        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let handle = dlopen(path, RTLD_LOCAL | RTLD_LAZY) else { continue }
            guard let loadSymbol = dlsym(handle, "NDIlib_v6_load") else {
                dlclose(handle)
                continue
            }

            typealias LoadFunction = @convention(c) () -> UnsafePointer<NDIlib_v6>?
            let load = unsafeBitCast(loadSymbol, to: LoadFunction.self)
            guard let lib = load() else {
                dlclose(handle)
                continue
            }

            self.libraryHandle = handle
            self.ndiLib = lib
            DebugLogger.shared.info("Live Captions NDI: loaded libndi.dylib from \(path)", source: "LiveCaptionsNDIPublisher")
            return true
        }

        return false
    }

    private func publishFrame() {
        guard let sender, let ndiLib = self.ndiLib else { return }

        let renderer = ImageRenderer(content: LiveCaptionsTextContentView())
        renderer.isOpaque = false
        renderer.scale = 2

        guard let cgImage = renderer.cgImage,
              let rawData = Self.makeBGRAPixelData(from: cgImage)
        else { return }

        var mutableData = rawData.bytes
        mutableData.withUnsafeMutableBufferPointer { buffer in
            var frame = NDIlib_video_frame_v2_t()
            frame.xres = Int32(rawData.width)
            frame.yres = Int32(rawData.height)
            frame.FourCC = NDIlib_FourCC_type_BGRA
            frame.frame_rate_N = 30000
            frame.frame_rate_D = 1001
            frame.picture_aspect_ratio = 0
            frame.frame_format_type = NDIlib_frame_format_type_progressive
            frame.timecode = NDIlib_send_timecode_synthesize
            frame.p_data = buffer.baseAddress
            frame.line_stride_in_bytes = Int32(rawData.bytesPerRow)
            frame.p_metadata = nil
            frame.timestamp = 0

            // Non-async: NDI copies the frame data before returning, so it's
            // safe for `mutableData` to go out of scope right after this call.
            ndiLib.pointee.send_send_video_v2(sender, &frame)
        }
    }

    /// Draws a CGImage into a raw BGRA, premultiplied-alpha byte buffer —
    /// the format NDI's BGRA FourCC expects, and (per NDI's own SDK docs)
    /// what compositors like QLab expect for alpha video specifically.
    private static func makeBGRAPixelData(from cgImage: CGImage) -> (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)

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

        return (rawData, width, height, bytesPerRow)
    }
}
