//
//  MainBotView.swift
//  nte_swift_fisher
//
//  The operator view: dead simple. A state indicator, a live minigame indicator,
//  one Start/Stop button (Start auto-focuses the game), and a status line. All
//  tuning lives in the Config tab — this screen is for running it.
//

import SwiftUI

struct MainBotView: View {
    @ObservedObject var bot: FishingBot
    @ObservedObject var capturer: ScreenCapturer

    var body: some View {
        VStack(spacing: 24) {
            Text("NTE Fisher").font(.largeTitle.bold())

            stateIndicator

            castCounter

            minigameIndicator

            startStop

            Text(bot.status)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .multilineTextAlignment(.center)

            Text(capturer.status)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 420)

            warnings
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - State indicator

    private var stateIndicator: some View {
        HStack(spacing: 10) {
            Circle().fill(bot.state.color).frame(width: 14, height: 14)
            Text(bot.state.label).font(.title2.bold())
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(bot.state.color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(bot.state.color.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Cast counter

    private var castCounter: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").foregroundStyle(.secondary)
            Text("\(bot.casts)").font(.title3.bold().monospacedDigit())
            Text("/").foregroundStyle(.secondary)
            // Live-editable limit (0 = ∞). Changeable even mid-run.
            Stepper(value: $bot.castLimit, in: 0...500, step: 5) {
                Text(bot.castLimit > 0 ? "\(bot.castLimit)" : "∞")
                    .font(.title3.monospacedDigit())
            }
            .fixedSize()
            Text("casts").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Minigame indicator

    private var minigameIndicator: some View {
        VStack(spacing: 4) {
            Text("MINIGAME BAR").font(.caption2.bold()).foregroundStyle(.secondary)
            BarIndicator(reading: bot.reading)
                .frame(width: 420, height: 44)
                .opacity(bot.reading == nil ? 0.35 : 1)
            if let e = bot.reading?.error {
                Text(String(format: "marker error %+.2f  %@", e,
                            bot.reading?.inBand == true ? "· in band" : ""))
                    .font(.caption2.monospaced())
                    .foregroundStyle(bot.reading?.inBand == true ? .green : .secondary)
            } else {
                Text(" ").font(.caption2.monospaced())
            }
        }
    }

    // MARK: - Start / Stop

    private var startStop: some View {
        Button {
            bot.toggle()
        } label: {
            Label(bot.running ? "Stop" : "Start fishing",
                  systemImage: bot.running ? "stop.fill" : "play.fill")
                .frame(width: 200)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .tint(bot.running ? .red : .green)
        .disabled(!bot.running && !bot.isConfigured)
    }

    // MARK: - Warnings

    @ViewBuilder private var warnings: some View {
        if !InputController.hasAccessibility {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Accessibility permission needed to send keys.").font(.caption)
                Button("Grant") { InputController.requestAccessibility() }.controlSize(.small)
            }
        }
        if !bot.isConfigured {
            Text("Capture the E template in the Config tab before starting.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
