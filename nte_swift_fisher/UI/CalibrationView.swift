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
    @StateObject private var capturer = ScreenCapturer()

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

    @State private var showRegions = true
    @State private var showContent = true
    @State private var selectedRegion: RegionID = .fButton

    /// Whether regions should use their FULLSCREEN y-offsets (else windowed).
    /// Fixtures behave like windowed.
    private var fullscreenLayout: Bool { mode == .live && capturer.isFullscreen }

    /// Title-bar CROP (reduces viewport height): windowed only.
    /// Fixtures already cropped; fullscreen has no chrome.
    private var effectiveTitleBarPoints: Double {
        (mode == .live && !capturer.isFullscreen) ? windowedTitleBarPoints : 0
    }

    // The image + pixel size currently being displayed, depending on mode.
    private var displayImage: CGImage? {
        mode == .live ? capturer.latestFrame : fixtureImage
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
    CalibrationView().frame(width: 1100, height: 760)
}
