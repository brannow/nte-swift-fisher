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
    case eButton, topBar
    var id: String { rawValue }

    /// Overlay draw colour (not persisted — purely presentation).
    var color: Color {
        switch self {
        case .eButton: .orange
        case .topBar: .green
        }
    }
}

struct GameRegions: Equatable {
    /// "E refresh" slot (bottom-right button row). Present in IDLE, gone once we
    /// cast — this is the single IDLE discriminator (E-glyph template match).
    var eButton = NormRect(x: 0.834, y: 0.880, w: 0.042, h: 0.068)

    /// Top-centre minigame bar (green target segment + yellow marker tick).
    var topBar = NormRect(x: 0.316, y: 0.054, w: 0.370, h: 0.012)

    /// Per-region vertical nudge (normalized), carried SEPARATELY for windowed
    /// and fullscreen. The game scales its UI slightly differently between the
    /// two modes, so rather than fight it we just store an explicit y offset per
    /// region per mode. Keyed by RegionID.rawValue; absent = 0. (Fixtures use the
    /// windowed offset.)
    var winYOffset: [String: Double] = [:]
    var fsYOffset = ["eButton": -0.003, "topBar": 0.003]

    /// Random-access by id, so the editor can bind to a selected region.
    subscript(id: RegionID) -> NormRect {
        get {
            switch id {
            case .eButton: eButton
            case .topBar: topBar
            }
        }
        set {
            switch id {
            case .eButton: eButton = newValue
            case .topBar: topBar = newValue
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
            line("eButton", eButton),
            line("topBar", topBar),
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
        var eButton, topBar: NormRect
        var winYOffset: [String: Double]?   // optional: old stored data lacks these
        var fsYOffset: [String: Double]?
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let d = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        self.init()
        eButton = d.eButton; topBar = d.topBar
        winYOffset = d.winYOffset ?? [:]
        fsYOffset = d.fsYOffset ?? [:]
    }

    var rawValue: String {
        let dto = DTO(eButton: eButton, topBar: topBar,
                      winYOffset: winYOffset, fsYOffset: fsYOffset)
        guard let data = try? JSONEncoder().encode(dto),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
