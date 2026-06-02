//
//  Defaults.swift
//  nte_swift_fisher
//
//  Single source of truth for the bot's default settings. BOTH the Config
//  window's @AppStorage editors (initial value + the per-section "Reset to
//  default" buttons) AND the engine's `Config.load()` fallbacks read these, so a
//  default can't drift between the UI and the engine. (That drift was real: the
//  lookahead default once diverged, UI 0.12 vs engine 0.15.)
//
//  Only scalar settings live here. The richer persisted types (GameRegions,
//  FixtureInsetMap, GlyphTemplate) carry their own defaults / reset.
//

enum BotDefaults {
    // Content rect
    static let titleBarPoints = 32.0

    // Detection — IDLE
    static let idleThreshold = 0.55
    static let idleMinBright = 0.0

    // Detection — MINIGAME bar
    static let barHueLo = 140.0
    static let barHueHi = 180.0
    static let markerHueLo = 45.0
    static let markerHueHi = 70.0
    static let barSMin = 0.30
    static let barVMin = 0.45
    static let barPresence = 0.35

    // Cast / wait timing
    static let castSecs = 1.8
    static let spamMs = 400
    static let biteTimeoutSecs = 45.0
    static let holdMinMs = 70
    static let holdMaxMs = 90

    // Minigame control (M3)
    static let invertControl = false
    static let deadzone = 0.5
    static let lookaheadSecs = 0.15
    static let velAlpha = 0.5
    static let controlPollMs = 33
    static let debugControlLog = false
    static let maxStruggleSecs = 120.0
    static let rewardSettleSecs = 4.0

    // Loop closure (M4)
    static let clickX = 0.5
    static let clickY = 0.5
    static let postClickMs = 100
}
