//
//  InputController.swift
//  nte_swift_fisher
//
//  Synthesises keyboard input for the game. Keyboard-only: f / a / d / esc.
//
//  Two hard rules from testing the real game:
//   • Every press must be held ≥60ms — taps ≤50ms get dropped.
//   • During the minigame only ONE of a/d is held at a time; we always release
//     the current direction before pressing the other.
//
//  Events are posted directly to the game's process id (CGEventPostToPid) so the
//  bot doesn't need to steal keyboard focus. A global-tap fallback is available
//  if the game ignores per-pid posts. Requires Accessibility permission.
//

import CoreGraphics
import ApplicationServices
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

    /// Minimum press duration; the game drops anything ≤50ms.
    var minHoldMs: UInt64 = 70

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var heldDirection: Direction?

    /// Whether we're allowed to post events.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    // MARK: - Discrete presses

    /// Press and release a key, holding ≥ minHoldMs.
    func tap(_ key: GameKey) async {
        keyDown(key.code)
        try? await Task.sleep(for: .milliseconds(minHoldMs))
        keyUp(key.code)
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
        try? await Task.sleep(for: .milliseconds(minHoldMs))
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

    private func keyDown(_ code: CGKeyCode) { post(code, down: true) }
    private func keyUp(_ code: CGKeyCode) { post(code, down: false) }

    private func post(_ code: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: code, keyDown: down) else { return }
        if let pid = targetPID, !useGlobalTap {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}
