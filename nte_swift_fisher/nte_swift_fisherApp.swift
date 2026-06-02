//
//  nte_swift_fisherApp.swift
//  nte_swift_fisher
//
//  App root. Owns the single FishingBot (and thus the single SCStream + input
//  controller) as a @StateObject and shares it across BOTH scenes:
//   • the main operator window (MainBotView) — always present, compact;
//   • a separate Config/calibration window (CalibrationView) — its own large
//     window, opened on demand from the operator window's Config button.
//
//  Why two scenes instead of a TabView: the calibration tool wants its own size
//  and to sit alongside the running bot, not swap places with it. The Config window
//  is suppressed at launch (`.defaultLaunchBehavior(.suppressed)`) so we start on
//  the operator screen and open Config only when asked.
//

import SwiftUI

/// Stable identifier for the Config window so MainBotView's button can open it.
enum ConfigWindow { static let id = "config" }

@main
struct nte_swift_fisherApp: App {
    @StateObject private var bot = FishingBot()

    var body: some Scene {
        WindowGroup {
            MainBotView(bot: bot, capturer: bot.capturer)
                .frame(minWidth: 440, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 480, height: 640)

        Window("NTE Fisher — Config", id: ConfigWindow.id) {
            // isActive defaults true: the window only exists while open (suppressed
            // at launch, torn down on close), so its per-frame detection runs only
            // when it's actually on screen.
            CalibrationView(bot: bot, capturer: bot.capturer)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .defaultSize(width: 1180, height: 820)
    }
}
