//
//  MinigameTracker.swift
//  nte_swift_fisher
//
//  Decides a/d each control tick: keep the yellow MARKER inside the green BUBBLE.
//
//  Why this is its own type, and why it isn't just "push toward the centre":
//  the bubble is a MOVING target. Its position does a random walk with piecewise-
//  constant velocity that can switch up to ~every 500ms (and can also sit still),
//  and we only need CONTAINMENT, not dead-centre. Chasing a moving target with
//  position-only bang-bang STRUCTURALLY LAGS it — you always trail a constant-
//  velocity target by a roughly fixed gap, no matter the gain, and that gap is the
//  "can't follow" feeling. The fix is two-fold:
//
//    1. Estimate the bubble's velocity from recent frames (EMA over a finite
//       difference) and aim where it WILL be one control-latency ahead. That lead
//       cancels both the structural tracking lag and our own sense→act dead time.
//    2. Use a deadband = inside the bubble and REST once safely contained. "Inside
//       is enough", and not fighting is precisely what stops the oscillation /
//       overshoot — fewer reversals, no flip-flop.
//
//  Kept separate from the state machine so the control law can be tuned or swapped
//  (e.g. add a marker-velocity brake / switching curve later) without touching the
//  loop, and so every decision carries debug fields we log for plant ID + tuning.
//

import Foundation

/// One tick's decision plus the internals behind it (logged for tuning / plant ID).
struct TrackDecision {
    var direction: Direction?   // a/d to hold this tick (nil = release / rest)
    var center: Double          // measured bubble centre (norm)
    var marker: Double          // measured marker (norm)
    var velocity: Double        // estimated bubble velocity (norm units / sec, smoothed)
    var predicted: Double       // aim point = centre + velocity·lookahead
    var error: Double           // marker − predicted (what we drive to zero-ish)
    var dtMs: Double            // measured interval since last tick (loop period)
}

/// Stateful — keep ONE instance per minigame round (the velocity estimate is
/// carried across ticks). `FishingBot` makes a fresh one each time the bar appears.
@MainActor
final class MinigameTracker {
    struct Tuning {
        var lookaheadSecs: Double   // predict the bubble this far ahead (≈ loop latency)
        var velAlpha: Double        // EMA weight on the freshest velocity sample (0…1)
        var deadzoneFrac: Double    // rest when |error| ≤ this × half-band
        var invert: Bool            // flip a/d if the mapping steers the wrong way
    }

    private var lastT: Double?
    private var lastCenter: Double?
    private var vel = 0.0            // smoothed bubble velocity (norm / sec)

    /// Feed one frame. Times in seconds, positions normalized [0,1], `halfBand` the
    /// bubble's half-width. Returns the direction to hold this tick.
    func step(now: Double, center: Double, marker: Double,
              halfBand: Double, tuning t: Tuning) -> TrackDecision {
        // 1) Bubble velocity from the last two centres, smoothed to tame the
        //    centroid jitter. On a REVERSAL (fresh sample opposes the estimate) the
        //    old estimate is stale — the target is piecewise-constant-velocity — so
        //    weight the fresh sample harder instead of lagging through the turn.
        //    This is the disciplined version of "wipe the stack on direction
        //    change": react fast without ever going blind.
        var dt = 0.0
        if let lt = lastT, let lc = lastCenter, now > lt {
            dt = now - lt
            let raw = (center - lc) / dt
            let a = (raw * vel < 0) ? max(t.velAlpha, 0.6) : t.velAlpha
            vel = a * raw + (1 - a) * vel
        }
        lastT = now
        lastCenter = center

        // 2) Aim where the bubble WILL be one latency ahead (kills the lag).
        let predicted = center + vel * t.lookaheadSecs
        let error = marker - predicted
        let deadband = max(t.deadzoneFrac * halfBand, 0.001)

        // 3) Bang-bang on the predicted error, but REST inside the deadband.
        var dir: Direction? = nil
        if abs(error) > deadband {
            var right = error < 0       // marker LEFT of target ⇒ push right (D)
            if t.invert { right.toggle() }
            dir = right ? .right : .left
        }
        return TrackDecision(direction: dir, center: center, marker: marker,
                             velocity: vel, predicted: predicted,
                             error: error, dtMs: dt * 1000)
    }
}
