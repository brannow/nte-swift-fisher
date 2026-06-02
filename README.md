# NTE Fisher

A macOS app that auto-plays the fishing minigame in **NTE** (`/Applications/NTE.app`).
It watches the game window with ScreenCaptureKit, figures out the current fishing
stage from a couple of tiny screen regions, and plays it with synthesized **keyboard**
input. No mouse, no memory reading, no touching the game's files.

> Built with SwiftUI for macOS 26.5. App Sandbox is off (needed to capture another
> app's window and send it keys).

## How it works

Two screens share one engine (one capture stream, one input controller):

- **Operator window:** Start/Stop, live state, the minigame bar, a cast counter.
- **Config window:** calibration and tuning (opens from the toolbar button).

Detection is kept deliberately tiny. Only **two** things are ever looked at:

| Region | Tells us | Technique |
|--------|----------|-----------|
| `eButton` | We're **idle** (ready to cast) | template match (NCC) on the E glyph, background-independent |
| `topBar` | We're **in the minigame** | per-column green/yellow profile gives bubble and marker positions |

Everything else (waiting for a bite, the reward screen) is derived from those two
plus timers. Fewer detectors means fewer things to calibrate.

## The loop

```
IDLE --F--> WAIT --spam F--> MINIGAME --a/d track--> bubble gone --> REWARD --> IDLE
 (E glyph)                   (green bar)              (wait 4s)      (click)      back to start
```

The minigame is the interesting bit. The green bubble is a *moving target*. It drifts
randomly, changes direction every ~0.5s, sometimes sits still, and you only need to
keep the yellow marker *inside* it. Chasing its current position always lags, so the
controller (`MinigameTracker`):

1. estimates the bubble's **velocity** from recent frames,
2. aims where it **will be** ~150ms ahead, which cancels input lag,
3. **rests** once the marker is safely inside, so no twitching and no overshoot.

The input layer is deterministic and non-blocking, so it never stalls the control loop.

## Build and run

```sh
xcodebuild -project nte_swift_fisher.xcodeproj \
  -scheme nte_swift_fisher -configuration Debug \
  -destination 'platform=macOS' build
```

Or just open the project in Xcode and hit Run.

## First-time setup

1. Grant **Screen Recording** and **Accessibility** (System Settings, Privacy and
   Security). Relaunch after granting.
2. Open **Config**, then capture the **E glyph** template once on a clean idle frame
   (two clicks). It's saved between launches. Re-grab it if the game UI changes.
3. Back on the operator window, press **Start fishing**.

## Tuning (Config window)

Sensible defaults are baked in, so you rarely need these. The most useful knobs:

- **lookahead:** how far ahead the bubble is predicted (roughly the input lag, ~150ms).
- **rest x band:** how deep inside the bubble counts as "good enough".
- **invert a/d:** flip if it steers the wrong way.
- **debug log:** per-tick control trace to the console (leave off for normal runs).

## Safety

- **Kill switch:** the Stop button releases all keys and halts immediately.
- `esc` on the reward screen is intentionally avoided. A mistimed `esc` leaves the
  minigame, so the loop dismisses loot with a harmless center click instead.

Design rationale (why relative regions, template matching, the three coordinate
spaces, and so on) lives in `CLAUDE.md`.
