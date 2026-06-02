//
//  FishingBot.swift
//  nte_swift_fisher
//
//  The orchestrator. Owns the capture stream + input controller and runs the
//  fishing state machine, publishing what the UI needs (`state`, `status`, the
//  latest minigame `reading`). Both the operator view (MainBotView) and the
//  config view (CalibrationView) observe ONE instance, so they share a single
//  SCStream and a single source of truth.
//
//  Config (regions, template, thresholds, timings) lives in UserDefaults, edited
//  by the Config tab's @AppStorage controls. The bot snapshots it via
//  `Config.load()` at start — so the calibration view stays the source of truth
//  and we don't duplicate or rebind a pile of @Published settings.
//
//  Scope today: IDLE → cast → spam-F → halt when the minigame bar appears. No a/d
//  control (M3) and no esc/reward (M4) yet — without control we always fail, which
//  auto-returns to IDLE, so the dangerous esc path is never reached.
//

import SwiftUI
import Combine

/// Coarse phase of the fishing loop, for the operator's state indicator.
enum BotState: Equatable {
    case stopped, seekingIdle, casting, waiting, minigame, reward

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .seekingIdle: "Seeking IDLE"
        case .casting: "Casting"
        case .waiting: "Waiting for bite"
        case .minigame: "Minigame"
        case .reward: "Reward"
        }
    }

    var color: Color {
        switch self {
        case .stopped: .gray
        case .seekingIdle: .blue
        case .casting: .teal
        case .waiting: .orange
        case .minigame: .green
        case .reward: .purple
        }
    }
}

@MainActor
final class FishingBot: ObservableObject {
    let capturer: ScreenCapturer
    let input = InputController()

    @Published private(set) var running = false
    @Published private(set) var state: BotState = .stopped {
        didSet { if oldValue != state { Log.msg("🔄 state: \(oldValue.label) → \(state.label)") } }
    }
    @Published private(set) var status = "stopped"
    /// Latest minigame bar read, for the live indicator (nil outside the bar).
    @Published private(set) var reading: BarReading?
    /// Casts made this session (each lure-out). Resets on start.
    @Published private(set) var casts = 0
    /// Self-stop after this many casts (0 = unlimited). Live-editable (even mid-
    /// run — applies at the next loop tick) and persisted automatically.
    @Published var castLimit = 0 {
        didSet { UserDefaults.standard.set(castLimit, forKey: "castLimit") }
    }

    private var task: Task<Void, Never>?
    private let pollMs: UInt64 = 250

    init() {
        capturer = ScreenCapturer()
        castLimit = UserDefaults.standard.object(forKey: "castLimit") as? Int ?? 50
    }

    /// Whether the E glyph template has been captured — the bot can't read IDLE
    /// without it, so the operator UI gates Start on this.
    var isConfigured: Bool { !Config.loadTemplate().isEmpty }

    // MARK: - Control

    /// Begin fishing: ensures capture is live, focuses the game, runs the loop.
    func start() {
        guard !running else { return }
        Log.msg("▶️ bot start")
        running = true
        casts = 0
        state = .seekingIdle
        status = "starting…"
        reading = nil
        task = Task { [weak self] in await self?.run() }
    }

    /// Stop fishing (kill switch). Leaves capture running so the views keep
    /// showing live frames.
    func stop() {
        Log.msg("⏹ bot stop")
        running = false
        task?.cancel()
        task = nil
        input.releaseAll()
        state = .stopped
        status = "stopped"
        reading = nil
    }

    func toggle() { running ? stop() : start() }

    // MARK: - Loop

    private func run() async {
        if !capturer.isRunning { await capturer.start() }
        let cfg = Config.load()
        input.targetPID = capturer.gamePID
        input.tapHoldMs = cfg.holdRange
        input.focusTarget()
        await loop(cfg)
    }

    private func loop(_ cfg: Config) async {
        while running && !Task.isCancelled {
            if castLimit > 0, casts >= castLimit {
                status = "reached \(castLimit)-cast limit — stopped"
                running = false; break
            }
            input.targetPID = capturer.gamePID

            guard let img = capturer.latestFrame, let geo = geometry(cfg) else {
                state = .seekingIdle; status = "no frame — is capture running?"; reading = nil
                try? await Task.sleep(for: .milliseconds(pollMs)); continue
            }

            // 1) Wait for IDLE, then cast.
            guard isIdle(cfg, img, geo) == true else {
                state = .seekingIdle
                status = isIdle(cfg, img, geo) == nil ? "no read (template?)" : "waiting for IDLE…"
                reading = nil
                try? await Task.sleep(for: .milliseconds(pollMs)); continue
            }
            state = .casting
            casts += 1
            status = "cast #\(casts) (F)"
            input.focusTarget()
            await input.tap(.f)
            try? await Task.sleep(for: .seconds(cfg.castSecs))

            // 2) Spam F until the minigame bar appears, or give up and recast.
            state = .waiting
            input.focusTarget()
            let waitStart = Date()
            var hooked = false
            while running && !Task.isCancelled {
                if let f = capturer.latestFrame, let g = geometry(cfg) {
                    let r = readBar(cfg, f, g)
                    reading = r
                    if r?.greenBand != nil { hooked = true; break }
                }
                let elapsed = Date().timeIntervalSince(waitStart)
                if elapsed > cfg.biteTimeoutSecs {
                    status = "no bite in \(Int(cfg.biteTimeoutSecs))s → recast"; break
                }
                status = "casting line — spam F (\(Int(elapsed))s)"
                await input.tap(.f)
                try? await Task.sleep(for: .milliseconds(UInt64(cfg.spamMs)))
            }
            guard hooked else { continue }   // timed out → seek IDLE + recast

            // 3) MINIGAME — steer a/d to keep the yellow marker inside the moving
            //    green bubble until the bar disappears (win or fail). The bubble is
            //    a MOVING target, so MinigameTracker predicts where it's heading and
            //    aims there, resting once safely contained (see that file). A fresh
            //    tracker per round so last round's velocity estimate can't leak in.
            state = .minigame
            input.releaseAll()
            let tracker = MinigameTracker()
            let tuning = MinigameTracker.Tuning(lookaheadSecs: cfg.lookaheadSecs,
                                                velAlpha: cfg.velAlpha,
                                                deadzoneFrac: cfg.deadzone,
                                                invert: cfg.invertControl)
            let mgStart = Date()
            var lost = 0
            while running && !Task.isCancelled {
                guard let f = capturer.latestFrame, let g = geometry(cfg) else {
                    try? await Task.sleep(for: .milliseconds(UInt64(cfg.controlPollMs))); continue
                }
                let r = readBar(cfg, f, g)
                reading = r

                if Date().timeIntervalSince(mgStart) > cfg.maxStruggleSecs {
                    status = "minigame > \(Int(cfg.maxStruggleSecs))s — abort"
                    input.setDirection(nil); break
                }
                guard let band = r?.greenBand else {
                    // Bar (maybe briefly) gone — debounce before declaring it ended.
                    input.setDirection(nil)
                    lost += 1
                    if lost >= 3 { break }
                    try? await Task.sleep(for: .milliseconds(UInt64(cfg.controlPollMs))); continue
                }
                lost = 0

                guard let m = r?.marker else {
                    input.setDirection(nil)            // marker not found — don't flail
                    try? await Task.sleep(for: .milliseconds(UInt64(cfg.controlPollMs))); continue
                }

                let center = (band.lowerBound + band.upperBound) / 2
                // Half-band width — bubble size varies per fish, so the deadband
                // scales with it (auto-adapts each round).
                let hb = max((band.upperBound - band.lowerBound) / 2, 0.02)
                let now = Date().timeIntervalSinceReferenceDate
                let d = tracker.step(now: now, center: center, marker: m,
                                     halfBand: hb, tuning: tuning)
                input.setDirection(d.direction)

                let act = d.direction.map { $0 == .right ? "D" : "A" } ?? "rest"
                status = String(format: "minigame: %@ (e%+.3f v%+.2f)", act, d.error, d.velocity)
                // Per-tick instrumentation: with these we can identify the marker
                // plant + true loop latency from a few rounds, and tune lookahead.
                Log.msg(String(format: "🎯 dt=%4.0fms m=%.3f c=%.3f v=%+.3f pc=%.3f e=%+.3f → %@",
                               d.dtMs, d.marker, d.center, d.velocity, d.predicted, d.error, act))
                try? await Task.sleep(for: .milliseconds(UInt64(cfg.controlPollMs)))
            }
            input.releaseAll()
            if !running || Task.isCancelled { break }

            // 4) Bar gone — WIN or FAIL. Do NOT run idle detection during the
            //    settle (the loot screen reads ambiguously). Just wait, then click
            //    the centre to dismiss the loot screen — harmless on a FAIL (already
            //    back at idle), so no esc-at-idle danger — pause, then resume.
            state = .reward
            status = "bar gone — settling \(Int(cfg.rewardSettleSecs))s…"
            try? await Task.sleep(for: .seconds(cfg.rewardSettleSecs))
            if let geo = geometry(cfg) {
                let p = geo.globalPoint(normX: cfg.clickX, normY: cfg.clickY)
                status = "dismiss loot → click center"
                Log.msg("🎣 settle done → click \(String(format: "%.2f,%.2f", cfg.clickX, cfg.clickY)) to dismiss")
                input.focusTarget()
                try? await Task.sleep(for: .milliseconds(150))   // game frontmost
                await input.click(at: p)
                try? await Task.sleep(for: .milliseconds(UInt64(cfg.postClickMs)))
            }
            continue
        }
        running = false
        if state != .reward { state = .stopped }
    }

    // MARK: - Detection (live)

    /// Live window geometry from the capture stream (nil until a frame lands).
    private func geometry(_ cfg: Config) -> WindowGeometry? {
        guard capturer.windowFramePoints != .zero, capturer.pixelSize != .zero else { return nil }
        let titleBar = capturer.isFullscreen ? 0 : cfg.titleBarPoints
        return WindowGeometry(framePoints: capturer.windowFramePoints,
                              pixelSize: capturer.pixelSize, titleBarPoints: titleBar)
    }

    private func pixelRect(_ id: RegionID, _ cfg: Config, _ geo: WindowGeometry) -> CGRect {
        geo.pixelRect(cfg.regions.rect(id, fullscreen: capturer.isFullscreen))
    }

    private func isIdle(_ cfg: Config, _ img: CGImage, _ geo: WindowGeometry) -> Bool? {
        let px = pixelRect(.eButton, cfg, geo)
        guard let grid = FrameAnalyzer.featureGrid(of: img, in: px, n: Config.templateN),
              let score = cfg.eTemplate.ncc(grid) else { return nil }
        // The E glyph must MATCH (shape) AND be BRIGHT. The loot overlay dims the
        // idle scene behind it; NCC is brightness-invariant so it still matches the
        // blurred E — but the brightness gate rejects that dimmed version.
        let bright = eBright(img, px)
        return score >= cfg.idleThreshold && bright >= cfg.idleMinBright
    }

    /// White-ish fraction of the eButton glyph — its brightness signature. Sharp
    /// idle ⇒ high; dimmed (loot overlay behind) ⇒ low. Used as a safety: if the
    /// click failed to dismiss the loot, seek-IDLE won't false-cast into it.
    private func eBright(_ img: CGImage, _ px: CGRect) -> Double {
        FrameAnalyzer.whiteishFraction(of: img, in: px, vMin: 0.6, sMax: 0.4)
    }

    private func readBar(_ cfg: Config, _ img: CGImage, _ geo: WindowGeometry) -> BarReading? {
        BarReader.read(of: img, in: pixelRect(.topBar, cfg, geo),
                       greenHue: cfg.greenHue, yellowHue: cfg.yellowHue,
                       sMin: cfg.sMin, vMin: cfg.vMin, presence: cfg.presence)
    }
}

/// Snapshot of the calibration settings the bot needs, read from the same
/// UserDefaults keys the Config tab's @AppStorage writes — so there is exactly
/// one source of truth and no settings to keep in sync.
struct Config {
    static let templateN = 28

    var regions: GameRegions
    var titleBarPoints: Double
    var eTemplate: GlyphTemplate
    var idleThreshold: Double
    /// Min eButton brightness (white-ish fraction) to count as IDLE — rejects the
    /// dimmed E glyph behind the loot overlay. 0 = gate off.
    var idleMinBright: Double
    var greenHue: ClosedRange<Double>
    var yellowHue: ClosedRange<Double>
    var sMin, vMin, presence: Double
    var castSecs: Double
    var spamMs: Int
    var biteTimeoutSecs: Double
    var holdRange: ClosedRange<UInt64>
    // M3 minigame control (predictive tracking — see MinigameTracker)
    var controlPollMs: Int
    /// Rest when |marker − predicted bubble centre| ≤ this × half-band.
    var deadzone: Double
    /// Predict the bubble this far ahead (seconds) to cancel tracking lag +
    /// sense→act dead time. ≈ the measured loop latency.
    var lookaheadSecs: Double
    /// EMA weight (0…1) on the freshest bubble-velocity sample.
    var velAlpha: Double
    var invertControl: Bool
    var maxStruggleSecs: Double
    var rewardSettleSecs: Double
    // M4 loop closure — dismiss the loot screen with a centre click
    var clickX: Double
    var clickY: Double
    var postClickMs: Int

    // GameRegions / GlyphTemplate's RawRepresentable inits are MainActor-isolated
    // (project default isolation), and these loaders are only ever called from the
    // MainActor (FishingBot) — so mark them @MainActor rather than hopping actors.
    @MainActor
    static func loadTemplate() -> GlyphTemplate {
        UserDefaults.standard.string(forKey: "eTemplate")
            .flatMap(GlyphTemplate.init(rawValue:)) ?? GlyphTemplate()
    }

    @MainActor
    static func load() -> Config {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }

        let regions = d.string(forKey: "gameRegions").flatMap(GameRegions.init(rawValue:)) ?? GameRegions()
        let gLo = dbl("barHueLo", 140), gHi = dbl("barHueHi", 180)
        let yLo = dbl("markerHueLo", 45), yHi = dbl("markerHueHi", 70)
        let hMin = int("holdMinMs", 70), hMax = int("holdMaxMs", 90)

        return Config(
            regions: regions,
            titleBarPoints: dbl("windowedTitleBarPoints", 32),
            eTemplate: loadTemplate(),
            idleThreshold: dbl("idleMatchThreshold", 0.55),
            idleMinBright: dbl("idleMinBright", 0),
            greenHue: Swift.min(gLo, gHi)...Swift.max(gLo, gHi),
            yellowHue: Swift.min(yLo, yHi)...Swift.max(yLo, yHi),
            sMin: dbl("barSMin", 0.30), vMin: dbl("barVMin", 0.45),
            presence: dbl("barPresence", 0.35),
            castSecs: dbl("castAnimationSecs", 1.8),
            spamMs: int("spamIntervalMs", 400),
            biteTimeoutSecs: dbl("biteTimeoutSecs", 45),
            holdRange: UInt64(Swift.min(hMin, hMax))...UInt64(Swift.max(hMin, hMax)),
            controlPollMs: int("controlPollMs", 33),
            deadzone: dbl("deadzoneFrac", 0.5),     // × half-band
            lookaheadSecs: dbl("lookaheadSecs", 0.15),   // ≈ measured input dead time
            velAlpha: dbl("velAlpha", 0.5),
            invertControl: d.bool(forKey: "invertControl"),
            maxStruggleSecs: dbl("maxStruggleSecs", 120),
            rewardSettleSecs: dbl("rewardSettleSecs", 4),
            clickX: dbl("clickX", 0.5),
            clickY: dbl("clickY", 0.5),
            postClickMs: int("postClickMs", 100))
    }
}
