//
//  CalibrationView.swift
//  nte_swift_fisher
//
//  M0 debug overlay. Goal: SEE that our coordinate math is right before any
//  detection logic depends on it. Shows the captured frame (live or fixture),
//  draws the full window rect and the inner content boundary, overlays the
//  named normalized regions, and reads back each region's average colour to
//  prove the full capture → content-rect → region → pixels pipeline works.
//

import SwiftUI

enum CaptureMode: String, CaseIterable, Identifiable {
    case live = "Live"
    case fixture = "Fixture"
    var id: String { rawValue }
}

struct CalibrationView: View {
    /// Shared orchestrator + capture stream (owned by the app, shared with the
    /// operator window).
    @ObservedObject var bot: FishingBot
    @ObservedObject var capturer: ScreenCapturer
    /// True while the Config window is on screen. When false we skip ALL the heavy
    /// per-frame detection/visualisation (single choke point: displayImage). The
    /// window is torn down when closed, so this is effectively always true while
    /// the view exists — kept as a guard + for previews.
    var isActive: Bool = true

    @State private var mode: CaptureMode = .fixture
    @State private var fixtureName: String = ""
    @State private var fixtureImage: CGImage?

    // Persisted so calibration survives relaunches.
    @AppStorage("windowedTitleBarPoints") private var windowedTitleBarPoints: Double = 32
    @AppStorage("gameRegions") private var regions = GameRegions()
    /// Per-fixture content-rect insets (fractions) — each screenshot keeps its
    /// own set since cropToWindow heuristics differ per capture (windowed title
    /// bar vs fullscreen vs shadow border width).
    @AppStorage("fixtureInsets") private var fixtureInsets = FixtureInsetMap()

    // Detection (M1) — glyph TEMPLATE matching (background-independent). Capture
    // the E/F glyphs once, then IDLE = eButton NCC score over threshold. Templates
    // + threshold persist across relaunches.
    @AppStorage("eTemplate") private var eTemplate = GlyphTemplate()
    @AppStorage("idleMatchThreshold") private var idleMatchThreshold: Double = 0.55
    /// Min eButton brightness to count as IDLE — rejects the dimmed E behind the
    /// loot overlay (NCC alone matches the blurred glyph). 0 = gate off.
    @AppStorage("idleMinBright") private var idleMinBright: Double = 0

    // Detection (M3) — MINIGAME bar read as a 1-D signal: green TARGET band +
    // yellow MARKER. greenBand present ⇒ minigame active ⇒ also the "we hooked it"
    // signal for spam-F. Hue gates per colour; sMin/vMin shared; presence = the
    // per-column fraction a column needs to count toward band/marker.
    @AppStorage("barHueLo") private var barHueLo: Double = 140      // green
    @AppStorage("barHueHi") private var barHueHi: Double = 180
    @AppStorage("markerHueLo") private var markerHueLo: Double = 45 // yellow
    @AppStorage("markerHueHi") private var markerHueHi: Double = 70
    @AppStorage("barSMin") private var barSMin: Double = 0.30
    @AppStorage("barVMin") private var barVMin: Double = 0.45
    @AppStorage("barPresence") private var barPresence: Double = 0.35

    /// Template grid resolution. 28×28 = 784 cells — ample shape detail, trivial
    /// to correlate every frame. Template and live region must share this `n`.
    private let templateN = 28

    // Bot timing config (edited here, read by the FishingBot engine at start()).
    /// Post-press cooldown so we don't re-read IDLE mid-cast-animation and spam F.
    /// Borrowed default (1.8s) from a sibling bot — verify against live NTE.
    @AppStorage("castAnimationSecs") private var castAnimationSecs: Double = 1.8
    /// Blind F-spam cadence during WAIT (no bite detection — see CLAUDE.md loop).
    @AppStorage("spamIntervalMs") private var spamIntervalMs: Int = 400
    /// Give up waiting for a bite after this long and recast (borrowed default).
    @AppStorage("biteTimeoutSecs") private var biteTimeoutSecs: Double = 45
    /// Tap-hold JITTER range (ms) for F/Esc — sampled per press. UE5 drops ≤50ms;
    /// 70–90 is safe. a/d control is separate: deterministic + non-blocking.
    @AppStorage("holdMinMs") private var holdMinMs: Int = 70
    @AppStorage("holdMaxMs") private var holdMaxMs: Int = 90

    // M3 minigame control (read by the engine at start()).
    @AppStorage("invertControl") private var invertControl = false
    @AppStorage("deadzoneFrac") private var controlDeadzone: Double = 0.5
    @AppStorage("lookaheadSecs") private var lookaheadSecs: Double = 0.12
    @AppStorage("velAlpha") private var velAlpha: Double = 0.5
    @AppStorage("controlPollMs") private var controlPollMs: Int = 33
    @AppStorage("maxStruggleSecs") private var maxStruggleSecs: Double = 120
    @AppStorage("rewardSettleSecs") private var rewardSettleSecs: Double = 4

    // M4 loop closure — dismiss the loot screen with a centre click (harmless at
    // idle, unlike esc). Click point is normalized to the game viewport.
    @AppStorage("clickX") private var clickX: Double = 0.5
    @AppStorage("clickY") private var clickY: Double = 0.5
    @AppStorage("postClickMs") private var postClickMs: Int = 100

    /// The persisted jitter range, clamped so min ≤ max.
    private var tapHoldRange: ClosedRange<UInt64> {
        let lo = min(holdMinMs, holdMaxMs), hi = max(holdMinMs, holdMaxMs)
        return UInt64(lo)...UInt64(hi)
    }

    @State private var showRegions = true
    @State private var showContent = true
    @State private var selectedRegion: RegionID = .eButton

    /// Filename of the most recent zone snapshot, shown as confirmation.
    @State private var lastSnapshot: String?

    /// Short context tag baked into snapshot filenames so a folder of samples is
    /// self-describing (which source / window mode produced each crop).
    private var snapshotModeTag: String {
        mode == .live ? (capturer.isFullscreen ? "live_fs" : "live_win") : "fixture"
    }

    /// Whether regions should use their FULLSCREEN y-offsets (else windowed).
    /// Fixtures behave like windowed.
    private var fullscreenLayout: Bool { mode == .live && capturer.isFullscreen }

    /// Title-bar CROP (reduces viewport height): windowed only.
    /// Fixtures already cropped; fullscreen has no chrome.
    private var effectiveTitleBarPoints: Double {
        (mode == .live && !capturer.isFullscreen) ? windowedTitleBarPoints : 0
    }

    // The image + pixel size currently being displayed, depending on mode.
    // Gated on `isActive`: hidden tab ⇒ nil ⇒ every detection/visualisation
    // computed below short-circuits, so no big-image work runs off-screen.
    private var displayImage: CGImage? {
        guard isActive else { return nil }
        return mode == .live ? capturer.latestFrame : fixtureImage
    }
    private var displaySize: CGSize {
        mode == .live ? capturer.pixelSize
            : (fixtureImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero)
    }
    private var geometry: WindowGeometry {
        let size = displaySize
        // Live: real window frame (global points). Fixture: synthesize a frame at
        // half the pixel size so scale == 2 (reference screenshots are Retina 2×).
        let frame = (mode == .live && capturer.windowFramePoints != .zero)
            ? capturer.windowFramePoints
            : CGRect(origin: .zero, size: CGSize(width: size.width / 2,
                                                 height: size.height / 2))
        let insets = (mode == .fixture)
            ? fixtureInsets[fixtureName]
            : FractionalInsets()
        return WindowGeometry(framePoints: frame, pixelSize: size,
                              titleBarPoints: effectiveTitleBarPoints,
                              contentInsets: insets)
    }

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: 300)
                .padding()
                .background(.ultraThinMaterial)
            imagePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            zoneBuffers
        }
        .onAppear {
            if fixtureName.isEmpty, let first = FixtureLoader.available().first {
                fixtureName = first
                fixtureImage = FixtureLoader.load(first)
            }
        }
    }

    // MARK: - Controls panel

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("NTE Fisher — M0 Calibration")
                    .font(.headline)

                Picker("Source", selection: $mode) {
                    ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if mode == .live {
                    liveControls
                } else {
                    fixtureControls
                }

                Divider()

                Toggle("Show content boundary", isOn: $showContent)
                Toggle("Show regions", isOn: $showRegions)

                Divider()
                titleBarSlider

                Divider()
                regionEditor

                Divider()
                detection

                Divider()
                botPanel

                Divider()
                readouts
            }
        }
    }

    private var liveControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(capturer.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(capturer.isRunning ? "Stop" : "Auto-find NTE") {
                    Task {
                        if capturer.isRunning { await capturer.stop() }
                        else { await capturer.start() }
                    }
                }
                if capturer.isRunning { ProgressView().scaleEffect(0.6) }
            }

            // Manual picker / diagnostics — confirm we grabbed the GAME, not our
            // own editor window (whose title contains "nte").
            DisclosureGroup("Pick window manually") {
                Button("Scan windows") { Task { await capturer.scanCandidates() } }
                    .font(.caption)
                ForEach(capturer.candidates) { cand in
                    Button {
                        Task { await capturer.start(window: cand.window) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cand.appName).font(.caption.bold())
                            Text("\(cand.title.isEmpty ? "—" : cand.title) · \(Int(cand.frame.width))×\(Int(cand.frame.height))")
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.caption)
        }
    }

    private var fixtureControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Fixture", selection: $fixtureName) {
                ForEach(FixtureLoader.available(), id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: fixtureName) { _, new in
                fixtureImage = FixtureLoader.load(new)
            }
            Text("\(Int(displaySize.width))×\(Int(displaySize.height)) px")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var titleBarSlider: some View {
        let windowedActive = mode == .live && !capturer.isFullscreen
        return VStack(alignment: .leading, spacing: 6) {
            Text("Content rect").font(.subheadline.bold())
            Text("Title bar = windowed viewport crop. Fullscreen & fixtures = 0. Per-mode y nudges live per region below.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("Title bar").frame(width: 78, alignment: .leading)
                    .font(.caption).fontWeight(windowedActive ? .bold : .regular)
                Slider(value: $windowedTitleBarPoints, in: 0...60).disabled(!windowedActive)
                Text("\(Int(windowedTitleBarPoints)) pt")
                    .font(.caption.monospaced()).frame(width: 40)
            }
            if mode == .fixture {
                HStack {
                    Text("Fixture viewport insets")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(fixtureName).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.top, 2)
                fixtureInset("top", fixtureBinding(\.top))
                fixtureInset("bottom", fixtureBinding(\.bottom))
                fixtureInset("left", fixtureBinding(\.leading))
                fixtureInset("right", fixtureBinding(\.trailing))
                Button("Reset this fixture") {
                    fixtureInsets.reset(fixtureName)
                }
                .font(.caption2)
            }
        }
    }

    /// Two-way binding to a single field of the current fixture's insets.
    /// Uses `FixtureInsetMap.mutate` to avoid the value-type subscript trap:
    /// `fixtureInsets[name].top = v` silently mutates a copy — the setter never
    /// fires. `mutate` does the read-modify-write atomically.
    private func fixtureBinding(_ keyPath: WritableKeyPath<FractionalInsets, Double>) -> Binding<Double> {
        Binding<Double>(
            get: { fixtureInsets[fixtureName][keyPath: keyPath] },
            set: { fixtureInsets.mutate(fixtureName, keyPath, $0) }
        )
    }

    private func fixtureInset(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.monospaced()).frame(width: 44, alignment: .leading)
            Slider(value: value, in: -0.25...0.25)
            Stepper("", value: value, in: -0.25...0.25, step: 0.002).labelsHidden()
            Text(String(format: "%+.3f", value.wrappedValue))
                .font(.caption.monospaced()).frame(width: 48)
        }
    }

    // MARK: - Region editor (persisted to UserDefaults)

    private var regionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Regions").font(.subheadline.bold())
            Picker("Region", selection: $selectedRegion) {
                ForEach(RegionID.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            regionField("x", \.x, range: 0...1)
            regionField("y", \.y, range: 0...1)
            regionField("w", \.w, range: 0...1)
            regionField("h", \.h, range: 0...1)

            // Per-mode vertical nudges (the game scales UI differently windowed
            // vs fullscreen, so each region carries its own offset for each).
            yOffsetStepper("Win Δy", fullscreen: false)
            yOffsetStepper("FS Δy", fullscreen: true)

            HStack {
                Button("Reset all") { regions = GameRegions() }
                Spacer()
                Button("Copy Swift defaults") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(regions.swiftDefaults(), forType: .string)
                }
            }
            .font(.caption)
        }
    }

    /// One editable component (x/y/w/h) of the selected region: slider + exact value.
    private func regionField(_ label: String,
                             _ key: WritableKeyPath<NormRect, Double>,
                             range: ClosedRange<Double>) -> some View {
        let binding = Binding<Double>(
            get: { regions[selectedRegion][keyPath: key] },
            set: { regions[selectedRegion][keyPath: key] = $0 })
        return HStack(spacing: 6) {
            Text(label).font(.caption.monospaced()).frame(width: 14)
            Slider(value: binding, in: range)
            Stepper("", value: binding, in: range, step: 0.001).labelsHidden()
            Text(String(format: "%.3f", binding.wrappedValue))
                .font(.caption.monospaced()).frame(width: 44)
        }
    }

    /// Per-mode vertical offset stepper for the selected region (normalized).
    private func yOffsetStepper(_ label: String, fullscreen: Bool) -> some View {
        let binding = Binding<Double>(
            get: { regions.yOffset(selectedRegion, fullscreen: fullscreen) },
            set: { regions.setYOffset($0, for: selectedRegion, fullscreen: fullscreen) })
        let active = fullscreen == fullscreenLayout
        return HStack(spacing: 6) {
            Text(label).font(.caption.monospaced())
                .fontWeight(active ? .bold : .regular).frame(width: 48, alignment: .leading)
            Stepper("", value: binding, in: -0.2...0.2, step: 0.001).labelsHidden()
            Text(String(format: "%+.3f", binding.wrappedValue))
                .font(.caption.monospaced()).frame(width: 52)
            if active { Text("active").font(.caption2).foregroundStyle(.green) }
        }
    }

    // MARK: - Detection (M1): IDLE = eButton white-ish fraction over threshold

    private var detection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Detection — IDLE").font(.subheadline.bold())
                Spacer()
                idleBadge
            }
            Text("Glyph TEMPLATE match (NCC) — background-independent. Capture E once on a clean IDLE frame; IDLE = E-match over threshold.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button("Capture E") { captureTemplate(.eButton) }
                Spacer()
                if !eTemplate.isEmpty {
                    Button("Clear") { eTemplate = GlyphTemplate() }
                        .foregroundStyle(.red)
                }
            }
            .font(.caption).controlSize(.small)

            matchRow("E match", id: .eButton, template: eTemplate, decisive: true)
            HStack {
                Text("E bright").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let b = eBrightFraction() {
                    Text(String(format: "%.2f", b))
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(b >= idleMinBright ? .green : .orange)
                }
            }

            detectionSlider("thresh", $idleMatchThreshold, 0.0...1.0)
            detectionSlider("minBright", $idleMinBright, 0.0...0.5)
            Text("IDLE = E-match ≥ thresh AND E-bright ≥ minBright. Raise minBright above the loot-screen's E-bright to stop the dimmed E false-matching IDLE.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            HStack {
                Text("Detection — MINIGAME").font(.subheadline.bold())
                Spacer()
                minigameBadge
            }
            Text("1-D read: green target BAND + yellow MARKER, collapsed per column. greenBand present = hooked. error = marker − target → drives a/d (M3).")
                .font(.caption2).foregroundStyle(.secondary)

            if let r = barReading {
                barVisualizer(r).frame(height: 38)
                barReadout(r)
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary)
            }

            detectionSlider("presence", $barPresence, 0.0...1.0)
            DisclosureGroup("green / yellow gates") {
                detectionSlider("g hue lo", $barHueLo, 90...210, step: 1, decimals: 0)
                detectionSlider("g hue hi", $barHueHi, 90...210, step: 1, decimals: 0)
                detectionSlider("y hue lo", $markerHueLo, 20...110, step: 1, decimals: 0)
                detectionSlider("y hue hi", $markerHueHi, 20...110, step: 1, decimals: 0)
                detectionSlider("sMin", $barSMin, 0.0...1.0)
                detectionSlider("vMin", $barVMin, 0.0...1.0)
            }
            .font(.caption)
        }
    }

    /// Numeric band / marker / error readout.
    private func barReadout(_ r: BarReading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("target").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(r.targetCenter.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.caption2.monospaced())
            }
            HStack {
                Text("marker").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(r.marker.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.caption2.monospaced())
            }
            HStack {
                Text("error").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let e = r.error {
                    Text(String(format: "%+.2f %@", e, e < 0 ? "→push right" : "→push left"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(r.inBand ? .green : .orange)
                } else {
                    Text("—").font(.caption2.monospaced())
                }
            }
        }
    }

    /// Draws the two per-column profiles + the detected band span and marker line
    /// (shared with the operator view's minigame indicator).
    private func barVisualizer(_ r: BarReading) -> some View {
        BarIndicator(reading: r)
    }

    /// Live MINIGAME / not pill driven by the top-bar green fraction.
    @ViewBuilder private var minigameBadge: some View {
        switch isMinigame {
        case .some(true):
            Text("MINIGAME").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green, in: Capsule()).foregroundStyle(.black)
        case .some(false):
            Text("no bar").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.gray.opacity(0.3), in: Capsule())
        case .none:
            Text("—").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// One live NCC score row. `decisive` ones colour green once over threshold.
    @ViewBuilder
    private func matchRow(_ label: String, id: RegionID,
                          template: GlyphTemplate, decisive: Bool) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if template.isEmpty {
                Text("no template").font(.caption2).foregroundStyle(.secondary)
            } else if let s = matchScore(id, template) {
                Text(String(format: "%.2f", s))
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(decisive && s >= idleMatchThreshold ? .green : .primary)
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Live IDLE / not-IDLE pill driven by the eButton white-ish fraction.
    @ViewBuilder private var idleBadge: some View {
        switch isIdle {
        case .some(true):
            Text("IDLE").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green, in: Capsule()).foregroundStyle(.black)
        case .some(false):
            Text("not idle").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.gray.opacity(0.3), in: Capsule())
        case .none:
            Text("—").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func detectionSlider(_ label: String, _ value: Binding<Double>,
                                 _ range: ClosedRange<Double>,
                                 step: Double = 0.01, decimals: Int = 2) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.monospaced()).frame(width: 44, alignment: .leading)
            Slider(value: value, in: range)
            Stepper("", value: value, in: range, step: step).labelsHidden()
            Text(String(format: "%.\(decimals)f", value.wrappedValue))
                .font(.caption.monospaced()).frame(width: 36)
        }
    }

    // MARK: - Bot controls (thin — drives the shared FishingBot engine)

    private var botPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bot").font(.subheadline.bold())
                Spacer()
                Circle().fill(bot.state.color).frame(width: 8, height: 8)
                Text(bot.state.label).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Runs the live loop: IDLE → cast → spam F → halt at minigame. Timings below are read at Start.")
                .font(.caption2).foregroundStyle(.secondary)

            if !InputController.hasAccessibility {
                HStack(spacing: 6) {
                    Text("Needs Accessibility to send keys")
                        .font(.caption2).foregroundStyle(.orange)
                    Button("Grant") { InputController.requestAccessibility() }
                        .font(.caption2).controlSize(.small)
                }
            }

            HStack {
                Button(bot.running ? "Stop" : "Start") { bot.toggle() }
                    .font(.caption).controlSize(.small)
                    .disabled(!bot.running && eTemplate.isEmpty)
                Spacer()
                Button("Focus game") {
                    bot.input.targetPID = capturer.gamePID
                    bot.input.focusTarget()
                }
                .font(.caption).controlSize(.small)
                .disabled(capturer.gamePID == nil)
                Button("Press F once") {
                    bot.input.targetPID = capturer.gamePID
                    bot.input.tapHoldMs = tapHoldRange
                    Task { await bot.input.tap(.f) }
                }
                .font(.caption).controlSize(.small)
                .disabled(capturer.gamePID == nil)
                Button("Click pt") {
                    bot.input.targetPID = capturer.gamePID
                    let p = geometry.globalPoint(normX: clickX, normY: clickY)
                    Task {
                        bot.input.focusTarget()
                        try? await Task.sleep(for: .milliseconds(150))
                        await bot.input.click(at: p)
                    }
                }
                .font(.caption).controlSize(.small)
                .disabled(capturer.gamePID == nil || mode != .live)
            }

            HStack(spacing: 6) {
                Text("tap hold (jitter)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $holdMinMs, in: 50...150, step: 5) {
                    Text("\(holdMinMs)").font(.caption.monospaced())
                }
                Text("–").font(.caption).foregroundStyle(.secondary)
                Stepper(value: $holdMaxMs, in: 50...150, step: 5) {
                    Text("\(holdMaxMs) ms").font(.caption.monospaced())
                }
            }

            HStack(spacing: 6) {
                Text("cast cooldown").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $castAnimationSecs, in: 0...6, step: 0.1) {
                    Text(String(format: "%.1fs", castAnimationSecs))
                        .font(.caption.monospaced())
                }
            }

            HStack(spacing: 6) {
                Text("spam F every").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $spamIntervalMs, in: 150...1000, step: 50) {
                    Text("\(spamIntervalMs) ms").font(.caption.monospaced())
                }
            }

            Divider().padding(.vertical, 2)
            Text("Minigame control (M3)").font(.caption.bold())
            Toggle(isOn: $invertControl) {
                Text("invert a/d (flip if it steers wrong)").font(.caption)
            }
            .toggleStyle(.switch).controlSize(.small)
            Text("Predictive tracking: the marker is steered toward where the bubble WILL be (centre + velocity × lookahead), resting once inside (deadband × half-band; band size varies per fish). Lookahead ≈ loop latency cancels the chase lag; velocity smoothing tames marker jitter.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("rest ×band").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $controlDeadzone, in: 0...1.5, step: 0.05) {
                    Text(String(format: "%.2f", controlDeadzone)).font(.caption.monospaced())
                }
            }
            HStack(spacing: 6) {
                Text("lookahead").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $lookaheadSecs, in: 0...0.4, step: 0.01) {
                    Text(String(format: "%.0f ms", lookaheadSecs * 1000)).font(.caption.monospaced())
                }
            }
            HStack(spacing: 6) {
                Text("vel smoothing").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $velAlpha, in: 0.1...1, step: 0.05) {
                    Text(String(format: "%.2f", velAlpha)).font(.caption.monospaced())
                }
            }
            HStack(spacing: 6) {
                Text("control poll").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $controlPollMs, in: 16...200, step: 1) {
                    Text("\(controlPollMs) ms").font(.caption.monospaced())
                }
            }
            HStack(spacing: 6) {
                Text("max struggle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $maxStruggleSecs, in: 10...300, step: 10) {
                    Text("\(Int(maxStruggleSecs))s").font(.caption.monospaced())
                }
            }
            HStack(spacing: 6) {
                Text("reward settle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $rewardSettleSecs, in: 1...10, step: 0.5) {
                    Text(String(format: "%.1fs", rewardSettleSecs)).font(.caption.monospaced())
                }
            }

            Divider().padding(.vertical, 2)
            Text("Loop closure — click to dismiss loot (M4)").font(.caption.bold())
            Text("After the bar vanishes: wait reward-settle (no detection), click this point to close the loot, then after-click pause and resume. Use 'Click pt' to test the spot lands on empty area.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("click x").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $clickX, in: 0...1, step: 0.02) {
                    Text(String(format: "%.2f", clickX)).font(.caption.monospaced())
                }
            }
            HStack(spacing: 6) {
                Text("click y").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $clickY, in: 0...1, step: 0.02) {
                    Text(String(format: "%.2f", clickY)).font(.caption.monospaced())
                }
            }
            HStack(spacing: 6) {
                Text("after-click wait").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper(value: $postClickMs, in: 0...1000, step: 50) {
                    Text("\(postClickMs) ms").font(.caption.monospaced())
                }
            }

            Text(bot.status).font(.caption2).foregroundStyle(.secondary)
            if eTemplate.isEmpty {
                Text("Capture the E template first.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Geometry").font(.subheadline.bold())
            let g = geometry
            label("scale", String(format: "%.2f×", g.scale))
            label("content px", rectString(g.contentRectPixels))
            Text("Region avg colour").font(.subheadline.bold()).padding(.top, 4)
            if let img = displayImage {
                ForEach(regions.labelled(fullscreen: fullscreenLayout), id: \.id) { item in
                    let px = g.pixelRect(item.rect)
                    let rgb = FrameAnalyzer.averageColor(of: img, in: px)
                    Button { selectedRegion = item.id } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(rgb.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .gray)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(item.color, lineWidth: 1.5))
                            Text(item.id.rawValue).font(.caption.monospaced())
                                .fontWeight(item.id == selectedRegion ? .bold : .regular)
                            Spacer()
                            if let c = rgb {
                                Text("h\(Int(c.hue)) s\(Int(c.saturation * 100)) v\(Int(c.brightness * 100))")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No frame").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption.monospaced())
        }
    }

    private func rectString(_ r: CGRect) -> String {
        String(format: "%.0f,%.0f %.0f×%.0f", r.minX, r.minY, r.width, r.height)
    }

    // MARK: - Capture-zone buffers (the exact pixels detection will use)

    /// Live whiteness feature grid for a region (nil if no frame). Used both to
    /// capture a template and to score the live region against one.
    private func featureGrid(_ id: RegionID) -> [Double]? {
        guard let img = displayImage else { return nil }
        let px = geometry.pixelRect(regions.rect(id, fullscreen: fullscreenLayout))
        return FrameAnalyzer.featureGrid(of: img, in: px, n: templateN)
    }

    /// NCC of a region against a captured glyph template (nil if no frame or the
    /// template is uncaptured).
    private func matchScore(_ id: RegionID, _ template: GlyphTemplate) -> Double? {
        guard let grid = featureGrid(id) else { return nil }
        return template.ncc(grid)
    }

    /// Live eButton brightness (white-ish fraction) — the IDLE brightness gate.
    private func eBrightFraction() -> Double? {
        guard let img = displayImage else { return nil }
        let px = geometry.pixelRect(regions.rect(.eButton, fullscreen: fullscreenLayout))
        return FrameAnalyzer.whiteishFraction(of: img, in: px, vMin: 0.6, sMax: 0.4)
    }

    /// Capture the given region's grid as the E glyph template.
    private func captureTemplate(_ id: RegionID) {
        guard let grid = featureGrid(id) else { return }
        eTemplate = GlyphTemplate(n: templateN, features: grid)
    }

    /// IDLE decision: eButton matches the captured E glyph above threshold.
    /// nil when there's no frame or no template yet.
    private var isIdle: Bool? {
        matchScore(.eButton, eTemplate).map { $0 >= idleMatchThreshold }
    }

    /// Live 1-D read of the minigame top bar (green band + yellow marker).
    private var barReading: BarReading? {
        guard let img = displayImage else { return nil }
        let px = geometry.pixelRect(regions.rect(.topBar, fullscreen: fullscreenLayout))
        let green = min(barHueLo, barHueHi)...max(barHueLo, barHueHi)
        let yellow = min(markerHueLo, markerHueHi)...max(markerHueLo, markerHueHi)
        return BarReader.read(of: img, in: px, greenHue: green, yellowHue: yellow,
                              sMin: barSMin, vMin: barVMin, presence: barPresence)
    }

    /// MINIGAME decision: a coherent green target band is present in the top bar
    /// — i.e. we hooked the fish and the control minigame has started.
    private var isMinigame: Bool? {
        guard displayImage != nil else { return nil }
        return barReading?.greenBand != nil
    }

    /// Crop the current frame to a region's pixel rect (clamped to the image).
    private func regionCrop(_ id: RegionID) -> CGImage? {
        guard let img = displayImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let r = geometry.pixelRect(regions.rect(id, fullscreen: fullscreenLayout))
            .integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        return img.cropping(to: r)
    }

    private var zoneBuffers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Capture zones").font(.headline)
            Text("Exact pixels fed to detection")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button { ZoneSnapshot.revealFolder() } label: {
                    Label("Folder", systemImage: "folder").font(.caption2)
                }
                .controlSize(.small)
                if let lastSnapshot {
                    Text("saved \(lastSnapshot)")
                        .font(.caption2).foregroundStyle(.green)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(regions.labelled(fullscreen: fullscreenLayout), id: \.id) { item in
                        let crop = regionCrop(item.id)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Circle().fill(item.color).frame(width: 8, height: 8)
                                Text(item.id.rawValue).font(.caption.monospaced())
                                    .fontWeight(item.id == selectedRegion ? .bold : .regular)
                                Spacer()
                                if let c = crop {
                                    Text("\(c.width)×\(c.height)")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            if let c = crop {
                                Image(c, scale: 1, label: Text(item.id.rawValue))
                                    .resizable().interpolation(.none).scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: 64, alignment: .center)
                                    .background(Color.black)
                                // Freeze THIS zone's exact buffer to a PNG. New file
                                // every click (timestamped) — accumulates samples.
                                Button {
                                    if let url = ZoneSnapshot.save(c, zone: item.id.rawValue,
                                                                   mode: snapshotModeTag) {
                                        lastSnapshot = url.lastPathComponent
                                    }
                                } label: {
                                    Label("Snapshot", systemImage: "camera").font(.caption2)
                                        .frame(maxWidth: .infinity)
                                }
                                .controlSize(.small)
                            } else {
                                Text("no frame").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedRegion = item.id }
                    }
                }
            }
        }
        .frame(width: 240)
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Image pane with overlays

    private var imagePane: some View {
        GeometryReader { proxy in
            ZStack {
                if let img = displayImage {
                    Image(img, scale: 1, label: Text("frame"))
                        .resizable()
                        .scaledToFit()
                }
                overlayCanvas(in: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func overlayCanvas(in viewSize: CGSize) -> some View {
        Canvas { ctx, _ in
            let size = displaySize
            guard size.width > 0, size.height > 0 else { return }
            let fit = Geometry.aspectFitRect(
                imageSize: size,
                in: CGRect(origin: .zero, size: viewSize))
            // pixel-space rect -> on-screen view rect
            let k = fit.width / size.width
            func toView(_ r: CGRect) -> CGRect {
                CGRect(x: fit.minX + r.minX * k, y: fit.minY + r.minY * k,
                       width: r.width * k, height: r.height * k)
            }

            let g = geometry

            // Full window rect (the whole captured image).
            ctx.stroke(Path(toView(CGRect(origin: .zero, size: size))),
                       with: .color(.red), lineWidth: 1)

            if showContent {
                ctx.stroke(Path(toView(g.contentRectPixels)),
                           with: .color(.blue), lineWidth: 2)
            }

            if showRegions {
                for item in regions.labelled(fullscreen: fullscreenLayout) {
                    let vr = toView(g.pixelRect(item.rect))
                    let selected = item.id == selectedRegion
                    if selected {
                        ctx.fill(Path(vr), with: .color(item.color.opacity(0.18)))
                    }
                    ctx.stroke(Path(vr), with: .color(item.color),
                               lineWidth: selected ? 3 : 1.5)
                    ctx.draw(Text(item.id.rawValue).font(.caption2).foregroundColor(item.color),
                             at: CGPoint(x: vr.minX + 2, y: vr.minY - 8), anchor: .topLeading)
                }
            }
        }
    }
}

#Preview {
    let bot = FishingBot()
    return CalibrationView(bot: bot, capturer: bot.capturer).frame(width: 1100, height: 760)
}
