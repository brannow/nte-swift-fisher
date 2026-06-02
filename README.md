# 🎣 NTE Fisher

A macOS app that auto-plays the fishing minigame in **NTE** (`/Applications/NTE.app`).
It watches the game window with ScreenCaptureKit, figures out the current fishing
stage from a couple of tiny screen regions, and plays it with synthesized **keyboard**
input. No mouse, no memory reading, no touching the game's files.

> Built with SwiftUI for macOS 26.5. App Sandbox is off (needed to capture another
> app's window and send it keys).

---

## How it works

Two screens share one engine (one capture stream, one input controller):

- **Operator window** — Start/Stop, live state, the minigame bar, a cast counter.
- **Config window** — calibration & tuning (opens from the toolbar button).

Detection is kept deliberately tiny — only **two** things are ever looked at:

| Region | Tells us | Technique |
|--------|----------|-----------|
| `eButton` | We're **idle** (ready to cast) | template match (NCC) on the E glyph — background-independent |
| `topBar` | We're **in the minigame** | per-column green/yellow profile → bubble + marker positions |

Everything else (waiting for a bite, reward screen) is derived from those two plus
timers. Fewer detectors = fewer things to calibrate.

## The loop

```
IDLE ──F──▶ WAIT ──spam F──▶ MINIGAME ──a/d track──▶ bubble gone ──▶ REWARD ──▶ IDLE
 (E glyph)                    (green bar)              (wait 4s)      (click)      ↺
```

**The minigame is the interesting bit.** The green bubble is a *moving target* — it
drifts randomly, changes direction every ~0.5s, sometimes sits still — and you only
need to keep the yellow marker *inside* it. Chasing its current position always lags,
so the controller (`MinigameTracker`):

1. estimates the bubble's **velocity** from recent frames,
2. aims where it **will be** ~150ms ahead (cancels input lag),
3. **rests** once the marker is safely inside (no twitching, no overshoot).

The input layer is deterministic and non-blocking — it never stalls the control loop.

## Build & run

```sh
xcodebuild -project nte_swift_fisher.xcodeproj \
  -scheme nte_swift_fisher -configuration Debug \
  -destination 'platform=macOS' build
```

…or just open the project in Xcode and hit Run.

## First-time setup

1. Grant **Screen Recording** and **Accessibility** (System Settings → Privacy &
   Security). Relaunch after granting.
2. Open **Config** → capture the **E glyph** template once on a clean idle frame
   (two clicks). It's saved between launches; re-grab it if the game UI changes.
3. Back on the operator window → **Start fishing**.

## Tuning (Config window)

Sensible defaults are baked in; you rarely need these. Most useful knobs:

- **lookahead** — how far ahead the bubble is predicted (≈ input lag, ~150ms).
- **rest ×band** — how deep inside the bubble counts as "good enough".
- **invert a/d** — flip if it steers the wrong way.
- **debug log** — per-tick control trace to the console (leave off for normal runs).

## Safety

- **Kill switch:** the Stop button releases all keys and halts immediately.
- `esc` on the reward screen is intentionally avoided — a mistimed `esc` leaves the
  minigame, so the loop dismisses loot with a harmless center click instead.

---

*Design rationale (why relative regions, template matching, the three coordinate
spaces, etc.) lives in `CLAUDE.md`.*
