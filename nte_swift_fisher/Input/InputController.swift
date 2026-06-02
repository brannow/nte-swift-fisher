//
//  InputController.swift
//  nte_swift_fisher
//
//  Synthesises keyboard input for the game. Keyboard-only: f / a / d / esc.
//
//  Two hard rules from testing the real game:
//   • Every press must be held ≥60ms — taps ≤50ms get dropped. Discrete taps
//     (F/Esc) hold a RANDOM duration in `tapHoldMs` (default 70–90ms) so our
//     cadence isn't a fixed fingerprint. The a/d minigame floor is separate
//     (`dirMinHoldMs`): control wants a predictable floor, not jitter.
//   • During the minigame only ONE of a/d is held at a time; we always release
//     the current direction before pressing the other.
//
//  Events are posted directly to the game's process id (CGEventPostToPid) so the
//  bot doesn't need to steal keyboard focus. A global-tap fallback is available
//  if the game ignores per-pid posts. Requires Accessibility permission.
//

import CoreGraphics
import ApplicationServices
import AppKit
import Combine

enum GameKey {
    case f, a, d, esc

    /// Carbon virtual key codes.
    var code: CGKeyCode {
        switch self {
        case .f: 0x03   // kVK_ANSI_F
        case .a: 0x00   // kVK_ANSI_A
        case .d: 0x02   // kVK_ANSI_D
        case .esc: 0x35 // kVK_Escape
        }
    }
}

/// Left/right control for the minigame (maps to the game's a/d).
enum Direction { case left, right }

@MainActor
final class InputController: ObservableObject {
    /// Game process id to post to. When nil, falls back to the global HID tap.
    var targetPID: pid_t?
    /// Post to the focused app via the global tap instead of the pid.
    var useGlobalTap = false

    /// Hold range (ms) for discrete taps (F / Esc), sampled RANDOMLY per press so
    /// the cadence isn't a fixed fingerprint. UE5 drops ≤50ms; 70–90 sits safely
    /// above. Tunable live from the overlay.
    var tapHoldMs: ClosedRange<UInt64> = 70...90

    /// Minimum hold (ms) before a minigame direction (a/d) switch is allowed.
    /// SEPARATE from tap jitter on purpose: direction control wants a predictable
    /// floor that prevents a same-tick reversal from being dropped, not human-like
    /// randomness. Tuned in M3.
    var dirMinHoldMs: UInt64 = 70

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var heldDirection: Direction?

    /// Whether we're allowed to post events.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Trigger the system Accessibility prompt (and deep-link to Settings). No-op
    /// once granted. Lets the overlay nudge the user instead of failing silently.
    static func requestAccessibility() {
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    }

    // MARK: - Discrete presses

    /// Press and release a key, holding a random duration within `tapHoldMs`.
    ///
    /// `global`: post via the global HID tap (`cghidEventTap`) instead of
    /// `postToPid`. Needed for **Escape** — Cocoa intercepts Esc in the app's
    /// event queue (where `postToPid` delivers) before the game's input layer
    /// sees it, so we inject it like a physical key. The caller must `focusTarget`
    /// first so the HID event lands in the game.
    func tap(_ key: GameKey, global: Bool = false) async {
        keyDown(key.code, global: global)
        let hold = UInt64.random(in: tapHoldMs)
        try? await Task.sleep(for: .milliseconds(hold))
        keyUp(key.code, global: global)
    }

    /// Left-click at a global screen point (top-left origin, CG coords). Used to
    /// dismiss the loot screen ("Press empty area to close"). Harmless at idle, so
    /// unlike Esc it can be sent unconditionally. Posts via the HID tap — focus
    /// the game first. Warps the cursor to `point`.
    func click(at point: CGPoint) async {
        func ev(_ type: CGEventType) -> CGEvent? {
            CGEvent(mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: point, mouseButton: .left)
        }
        ev(.mouseMoved)?.post(tap: .cghidEventTap)
        ev(.leftMouseDown)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(UInt64.random(in: tapHoldMs)))
        ev(.leftMouseUp)?.post(tap: .cghidEventTap)
        Log.msg("🖱️ click at \(Int(point.x)),\(Int(point.y))")
    }

    // MARK: - Minigame direction control (mutual exclusion)

    /// Set the held direction (or nil to release). Guarantees only one of a/d is
    /// down and that each press lasts ≥ minHoldMs before it can be switched.
    func setDirection(_ dir: Direction?) async {
        guard dir != heldDirection else { return }
        // Release whatever is currently held.
        if let current = heldDirection {
            keyUp(key(for: current).code)
            heldDirection = nil
        }
        guard let dir else { return }
        keyDown(key(for: dir).code)
        heldDirection = dir
        // Enforce the minimum hold so a same-tick reversal can't drop the press.
        try? await Task.sleep(for: .milliseconds(dirMinHoldMs))
    }

    /// Brief directional TAP for FINE minigame corrections (vs the sustained
    /// `setDirection` hold that covers distance). Releases any held direction
    /// first. NOTE: the game drops presses ≤~50ms, so `ms` below that may not
    /// register — the finer control lever is the cadence between taps, not `ms`.
    func pulse(_ dir: Direction, ms: UInt64) async {
        releaseAll()
        let code = key(for: dir).code
        keyDown(code)
        try? await Task.sleep(for: .milliseconds(ms))
        keyUp(code)
    }

    /// Release any held direction (e.g. when the minigame ends).
    func releaseAll() {
        if let current = heldDirection {
            keyUp(key(for: current).code)
            heldDirection = nil
        }
    }

    private func key(for dir: Direction) -> GameKey {
        dir == .left ? .a : .d
    }

    // MARK: - Low-level posting

    private func keyDown(_ code: CGKeyCode, global: Bool = false) { post(code, down: true, global: global) }
    private func keyUp(_ code: CGKeyCode, global: Bool = false) { post(code, down: false, global: global) }

    private func post(_ code: CGKeyCode, down: Bool, global: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: code, keyDown: down) else { return }
        let edge = down ? "DOWN" : "UP  "
        if global || useGlobalTap {
            event.post(tap: .cghidEventTap)
            Log.msg("⌨️ \(edge) \(Self.keyName(code)) → hid-tap")
        } else if let pid = targetPID {
            event.postToPid(pid)            // direct to the game; focus-independent
            Log.msg("⌨️ \(edge) \(Self.keyName(code)) → pid \(pid)")
        } else {
            // No PID and not explicitly global: refuse to post, so a stray press
            // can't land in whatever app is frontmost (e.g. our own overlay).
            Log.msg("⌨️ \(edge) \(Self.keyName(code)) → DROPPED (no target)")
            return
        }
    }

    private static func keyName(_ code: CGKeyCode) -> String {
        switch code {
        case 0x03: "F"; case 0x00: "A"; case 0x02: "D"; case 0x35: "ESC"
        default: "0x" + String(code, radix: 16)
        }
    }

    // MARK: - Focus

    /// Bring the target game app to the foreground. `postToPid` is focus-
    /// independent, but some UE builds only honour synthesized input while
    /// frontmost — so we activate just before a press as a guarantee. No-op if
    /// the pid is unknown. Returns whether activation was issued.
    @discardableResult
    func focusTarget() -> Bool {
        guard let pid = targetPID,
              let app = NSRunningApplication(processIdentifier: pid) else {
            Log.msg("🎯 focus: no target pid"); return false
        }
        let ok = app.activate()
        Log.msg("🎯 focus game pid \(pid): \(ok)")
        return ok
    }
}
