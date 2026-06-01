//
//  Regions.swift
//  nte_swift_fisher
//
//  Named detection regions, expressed in NORMALIZED content-rect space so they
//  hold across window sizes and the day/night cycle.
//
//  These are tuned live in the calibration overlay and persisted to UserDefaults
//  (GameRegions is RawRepresentable so @AppStorage can store it). The values
//  below are the defaults / reset target — once dialled in, use the overlay's
//  "Copy Swift defaults" to paste fresh numbers back here.
//
//  NOTE: the bot is keyboard-only (f / a / d / esc). Pressing ESC on the catch
//  screen returns to IDLE — so there is no mouse click and no click region.
//

import SwiftUI

/// Stable identifier for each editable region.
enum RegionID: String, CaseIterable, Identifiable, Codable {
    case fButton, eButton, topBar, centerFlash
    var id: String { rawValue }

    /// Overlay draw colour (not persisted — purely presentation).
    var color: Color {
        switch self {
        case .fButton: .cyan
        case .eButton: .orange
        case .topBar: .green
        case .centerFlash: .pink
        }
    }
}

struct GameRegions: Equatable {
    /// Bottom-right hook button (stays in WAIT_BAIT; turns blue on a bite).
    var fButton = NormRect(x: 0.904, y: 0.879, w: 0.041, h: 0.067)

    /// "E refresh" slot, left neighbour of F. Present in IDLE, gone in
    /// WAIT_BAIT — used to distinguish those two states.
    var eButton = NormRect(x: 0.834, y: 0.880, w: 0.042, h: 0.068)

    /// Top-centre minigame bar (green target segment + yellow marker tick).
    var topBar = NormRect(x: 0.314, y: 0.053, w: 0.373, h: 0.015)

    /// Centre flash on a successful catch (colour varies by rarity) — the cue to
    /// press ESC and return to IDLE.
    var centerFlash = NormRect(x: 0.418, y: 0.328, w: 0.169, h: 0.259)

    /// Per-region vertical nudge (normalized), carried SEPARATELY for windowed
    /// and fullscreen. The game scales its UI slightly differently between the
    /// two modes, so rather than fight it we just store an explicit y offset per
    /// region per mode. Keyed by RegionID.rawValue; absent = 0. (Fixtures use the
    /// windowed offset.)
    var winYOffset: [String: Double] = [:]
    var fsYOffset = ["eButton": -0.003, "fButton": -0.003, "topBar": 0.003]

    /// Random-access by id, so the editor can bind to a selected region.
    subscript(id: RegionID) -> NormRect {
        get {
            switch id {
            case .fButton: fButton
            case .eButton: eButton
            case .topBar: topBar
            case .centerFlash: centerFlash
            }
        }
        set {
            switch id {
            case .fButton: fButton = newValue
            case .eButton: eButton = newValue
            case .topBar: topBar = newValue
            case .centerFlash: centerFlash = newValue
            }
        }
    }

    /// Per-mode vertical nudge for a region (normalized; 0 if unset).
    func yOffset(_ id: RegionID, fullscreen: Bool) -> Double {
        (fullscreen ? fsYOffset : winYOffset)[id.rawValue] ?? 0
    }

    mutating func setYOffset(_ value: Double, for id: RegionID, fullscreen: Bool) {
        if fullscreen { fsYOffset[id.rawValue] = value }
        else { winYOffset[id.rawValue] = value }
    }

    /// Effective rect for the current mode: base rect + per-mode y nudge.
    func rect(_ id: RegionID, fullscreen: Bool) -> NormRect {
        var r = self[id]
        r.y += yOffset(id, fullscreen: fullscreen)
        return r
    }

    /// Iterable view for overlay rendering + readouts (mode-aware).
    func labelled(fullscreen: Bool) -> [(id: RegionID, rect: NormRect, color: Color)] {
        RegionID.allCases.map { ($0, rect($0, fullscreen: fullscreen), $0.color) }
    }

    /// Swift source for the defaults, for pasting back into this file.
    func swiftDefaults() -> String {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        func line(_ name: String, _ r: NormRect) -> String {
            "    var \(name) = NormRect(x: \(f(r.x)), y: \(f(r.y)), w: \(f(r.w)), h: \(f(r.h)))"
        }
        func dict(_ name: String, _ d: [String: Double]) -> String? {
            let entries = d.filter { $0.value != 0 }
                .sorted { $0.key < $1.key }
                .map { "\"\($0.key)\": \(f($0.value))" }
            return entries.isEmpty ? nil : "    var \(name) = [\(entries.joined(separator: ", "))]"
        }
        var lines = [
            line("fButton", fButton),
            line("eButton", eButton),
            line("topBar", topBar),
            line("centerFlash", centerFlash),
        ]
        if let w = dict("winYOffset", winYOffset) { lines.append(w) }
        if let f = dict("fsYOffset", fsYOffset) { lines.append(f) }
        return lines.joined(separator: "\n")
    }
}

// Persist via @AppStorage by encoding to a JSON string. We serialize through a
// dedicated Codable DTO rather than making GameRegions itself Codable: a type
// that is BOTH Codable and RawRepresentable<Codable> can resolve encode(to:)
// back to `rawValue`, which here calls the encoder again → infinite recursion.
extension GameRegions: RawRepresentable {
    private struct DTO: Codable {
        var fButton, eButton, topBar, centerFlash: NormRect
        var winYOffset: [String: Double]?   // optional: old stored data lacks these
        var fsYOffset: [String: Double]?
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let d = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        self.init()
        fButton = d.fButton; eButton = d.eButton
        topBar = d.topBar; centerFlash = d.centerFlash
        winYOffset = d.winYOffset ?? [:]
        fsYOffset = d.fsYOffset ?? [:]
    }

    var rawValue: String {
        let dto = DTO(fButton: fButton, eButton: eButton,
                      topBar: topBar, centerFlash: centerFlash,
                      winYOffset: winYOffset, fsYOffset: fsYOffset)
        guard let data = try? JSONEncoder().encode(dto),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
