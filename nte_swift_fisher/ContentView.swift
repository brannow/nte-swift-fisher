//
//  ContentView.swift
//  nte_swift_fisher
//
//  App root: owns the single FishingBot (and thus the single capture stream) and
//  hosts the two screens. The window auto-resizes per tab — compact for the
//  operator view, large for the config/calibration view.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var bot = FishingBot()

    enum Tab { case bot, config }
    @State private var tab: Tab = .bot
    @State private var window: NSWindow?

    private func contentSize(for tab: Tab) -> CGSize {
        switch tab {
        case .bot: CGSize(width: 480, height: 600)
        case .config: CGSize(width: 1180, height: 820)
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            MainBotView(bot: bot, capturer: bot.capturer)
                .tabItem { Label("Bot", systemImage: "figure.fishing") }
                .tag(Tab.bot)
            // `isActive` gates the Config view's expensive per-frame detection so
            // it does zero image work while the tab is hidden.
            CalibrationView(bot: bot, capturer: bot.capturer, isActive: tab == .config)
                .tabItem { Label("Config", systemImage: "slider.horizontal.3") }
                .tag(Tab.config)
        }
        .background(WindowAccessor { w in
            guard window == nil else { return }   // capture once
            window = w
            w.minSize = NSSize(width: 440, height: 520)
            resize(w, to: contentSize(for: tab), animate: false)
        })
        .onChange(of: tab) { _, newTab in
            resize(window, to: contentSize(for: newTab), animate: true)
        }
    }

    /// Resize the window to a content size, keeping the top-left corner fixed
    /// (macOS frames are bottom-left origin, so we adjust y by the height delta).
    ///
    /// Always dispatched async: calling `setFrame` synchronously from inside a
    /// SwiftUI update/layout pass (e.g. `.onChange`) re-enters NSHostingView's
    /// layout and triggers the "laid out reentrantly" warning + a skipped pass.
    /// Deferring runs the resize after the current pass completes.
    private func resize(_ window: NSWindow?, to content: CGSize, animate: Bool) {
        guard let window else { return }
        DispatchQueue.main.async {
            let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
            var frame = window.frame
            let topEdge = frame.maxY
            frame.size = target.size
            frame.origin.y = topEdge - target.height
            window.setFrame(frame, display: true, animate: animate)
        }
    }
}

/// Bridges to the hosting NSWindow so we can drive its size from SwiftUI.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}

#Preview {
    ContentView()
}
