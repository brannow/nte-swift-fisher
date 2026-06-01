//
//  ScreenCapturer.swift
//  nte_swift_fisher
//
//  Live window capture via ScreenCaptureKit. Streams the NTE window, converts
//  each sample buffer to a CGImage, and publishes the latest frame + the real
//  window geometry needed for the three coordinate spaces (see Geometry.swift).
//
//  Concurrency note: SCStreamOutput callbacks arrive on a background queue, so
//  the frame handler is a separate `nonisolated` class. It hands frames to the
//  (MainActor) capturer via a Sendable box, which hops back to the main actor.
//

import ScreenCaptureKit
import CoreImage
import AppKit
import Combine
import ApplicationServices

/// Immutable carrier so a CGImage can cross the actor boundary safely.
/// CGImage is an immutable, thread-safe value in practice.
struct FrameBox: @unchecked Sendable {
    let image: CGImage
    let pixelSize: CGSize
}

/// Background-thread receiver of SCStream sample buffers.
nonisolated final class FrameHandler: NSObject, SCStreamOutput {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: @Sendable (FrameBox) -> Void

    init(onFrame: @escaping @Sendable (FrameBox) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        onFrame(FrameBox(image: cg, pixelSize: size))
    }
}

/// Receives stream lifecycle callbacks (on a background queue). The OS can tear
/// a stream down on its own — `didStopWithError` is how we learn about it.
nonisolated final class StreamDelegate: NSObject, SCStreamDelegate {
    private let onStop: @Sendable (Error) -> Void
    init(onStop: @escaping @Sendable (Error) -> Void) { self.onStop = onStop }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop(error) }
}

@MainActor
final class ScreenCapturer: ObservableObject {
    @Published private(set) var latestFrame: CGImage?
    @Published private(set) var pixelSize: CGSize = .zero
    @Published private(set) var windowFramePoints: CGRect = .zero
    @Published private(set) var backingScale: CGFloat = 2
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Idle — press Start"
    @Published private(set) var candidates: [WindowCandidate] = []
    @Published private(set) var isFullscreen = false
    /// Process id of the captured game window — input is posted here.
    @Published private(set) var gamePID: pid_t?

    private var stream: SCStream?
    private var handler: FrameHandler?
    private var streamDelegate: StreamDelegate?
    private var lastFrameAt = Date.distantPast
    private let outputQueue = DispatchQueue(label: "de.rannow.nte.capture")
    private var watchTask: Task<Void, Never>?
    /// User intent to be capturing. Distinct from `isRunning` (actual state) so a
    /// transient SCStream failure can be retried by the watcher.
    private var shouldCapture = false

    /// Refresh the list of on-screen windows (for the manual picker / diagnostics).
    func scanCandidates() async {
        candidates = (try? await WindowLocator.listCandidates()) ?? []
    }

    /// Auto-locate the NTE window and start (with self-healing watcher).
    func start() async {
        shouldCapture = true
        startWatcher()
        await attemptStart(window: nil)
    }

    /// Start capturing a specific window (manual picker).
    func start(window: SCWindow) async {
        shouldCapture = true
        startWatcher()
        await attemptStart(window: window)
    }

    /// Try to (re)establish capture. Tolerant of the transient SCStream "stream
    /// is nil" (CoreGraphics 1003) error seen during fullscreen↔window
    /// transitions — retries briefly; if it still fails the watcher will retry.
    private func attemptStart(window providedWindow: SCWindow?) async {
        await stopStream()
        for attempt in 0..<3 {
            do {
                let found: SCWindow?
                if let providedWindow {
                    found = providedWindow
                } else {
                    found = try await WindowLocator.findNTE()
                }
                guard let window = found else { throw WindowLocatorError.notFound }
                windowFramePoints = window.frame
                isFullscreen = await Self.detectFullscreen(window: window)
                gamePID = window.owningApplication?.processID
                // Backing scale of the screen the window is actually ON (a blanket
                // max() breaks when the window is on a 1× display while a 2× laptop
                // is connected — we'd request a 2× buffer it fills a quarter of).
                let scale = Self.backingScale(forWindowFrame: window.frame)
                backingScale = scale

                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                config.queueDepth = 3
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let handler = FrameHandler { [weak self] box in
                    Task { @MainActor in self?.ingest(box) }
                }
                let delegate = StreamDelegate { [weak self] error in
                    Task { @MainActor in self?.handleStreamStopped(error) }
                }
                let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
                try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: outputQueue)
                try await stream.startCapture()

                self.stream = stream
                self.handler = handler
                self.streamDelegate = delegate
                lastFrameAt = Date()
                isRunning = true
                let app = window.owningApplication?.applicationName ?? "?"
                let mode = isFullscreen ? "fullscreen" : "windowed"
                status = "Capturing “\(app)” \(Int(window.frame.width))×\(Int(window.frame.height)) pts @\(scale)× · \(mode)"
                return
            } catch {
                isRunning = false
                await stopStream()
                status = "Start failed (try \(attempt + 1)/3): \(error.localizedDescription)"
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        // Give up this round; the watcher will retry on its next tick.
    }

    /// User-facing stop: ends the watcher and the capture.
    func stop() async {
        shouldCapture = false
        watchTask?.cancel()
        watchTask = nil
        await stopStream()
        isRunning = false
        status = "Stopped"
    }

    /// Tears down just the stream (used internally before a restart on resize).
    private func stopStream() async {
        try? await stream?.stopCapture()
        stream = nil
        handler = nil
        streamDelegate = nil
    }

    private func ingest(_ box: FrameBox) {
        latestFrame = box.image
        pixelSize = box.pixelSize
        lastFrameAt = Date()
    }

    /// The OS stopped the stream out from under us. Mark not-running so the
    /// self-heal watcher re-establishes it (unless the user asked us to stop).
    private func handleStreamStopped(_ error: Error) {
        guard shouldCapture else { return }
        isRunning = false
        status = "Stream interrupted — recovering…"
    }

    /// Backing scale of the display the window mostly overlaps (1× or 2×).
    private static func backingScale(forWindowFrame frame: CGRect) -> CGFloat {
        var best: CGFloat = 2
        var bestArea: CGFloat = -1
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let bounds = CGDisplayBounds(num.uint32Value) // CG coords, top-left
            let inter = bounds.intersection(frame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea { bestArea = area; best = screen.backingScaleFactor }
        }
        return best
    }

    // MARK: - Resize / mode-switch handling

    /// Self-healing watcher: while capture is intended, (re)establishes it when
    /// it isn't running (transient SCStream failure) or when the window frame
    /// changed (resize, fullscreen↔window).
    private func startWatcher() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0))
                guard let self else { return }
                guard await self.shouldCapture else { continue }
                guard let window = try? await WindowLocator.findNTE() else { continue }
                let old = await self.windowFramePoints
                let running = await self.isRunning
                let f = window.frame
                let changed = abs(f.width - old.width) > 2 || abs(f.height - old.height) > 2
                    || abs(f.minX - old.minX) > 2 || abs(f.minY - old.minY) > 2
                // Watchdog: a stream can freeze silently (no error). If we're
                // "running" but no frame has arrived recently, treat it as dead.
                let last = await self.lastFrameAt
                let stale = running && Date().timeIntervalSince(last) > 2.5
                if !running || changed || stale {
                    await self.attemptStart(window: window)
                }
            }
        }
    }

    /// Is the window in fullscreen (no macOS title bar to strip)?
    ///
    /// Prefers the OS's own answer via the Accessibility `AXFullScreen` attribute
    /// (authoritative once Accessibility is granted). Falls back to comparing the
    /// window frame to its display — which also catches borderless fullscreen.
    private static func detectFullscreen(window: SCWindow) async -> Bool {
        if let pid = window.owningApplication?.processID,
           let ax = axFullscreen(pid: pid, frame: window.frame) {
            return ax
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return false }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) })
            ?? content.displays.first else { return false }
        return abs(display.frame.width - window.frame.width) < 3
            && abs(display.frame.height - window.frame.height) < 3
    }

    /// Ask the OS directly: read `AXFullScreen` on the matching window element.
    /// Returns nil if Accessibility isn't granted or the window can't be matched.
    private static func axFullscreen(pid: pid_t, frame: CGRect) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString,
                                            &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        func size(of w: AXUIElement) -> CGSize? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &v) == .success,
                  let axv = v, CFGetTypeID(axv) == AXValueGetTypeID() else { return nil }
            var s = CGSize.zero
            AXValueGetValue(axv as! AXValue, .cgSize, &s)
            return s
        }
        // Match the window whose size is closest to the captured frame.
        let target = windows.min { a, b in
            let da = size(of: a).map { abs($0.width - frame.width) + abs($0.height - frame.height) } ?? .infinity
            let db = size(of: b).map { abs($0.width - frame.width) + abs($0.height - frame.height) } ?? .infinity
            return da < db
        }
        guard let win = target else { return nil }
        var fsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef) == .success,
              let isFS = fsRef as? Bool else { return nil }
        return isFS
    }
}
