//
//  ZoneSnapshot.swift
//  nte_swift_fisher
//
//  Debug tool: write the EXACT cropped pixel buffer of a detection zone to a PNG
//  on disk. The calibration overlay already shows each zone's buffer live; this
//  freezes a moment to a file so we can collect real samples (day/night, live vs
//  fixture, button present vs absent) and design the detection metric against the
//  actual pixels — not a scaled-up thumbnail.
//
//  The CGImage we save is the same crop FrameAnalyzer will consume, written at
//  native size with no interpolation, so what's on disk == what detection sees.
//

import AppKit
import CoreGraphics

enum ZoneSnapshot {
    /// Output folder on the Desktop (App Sandbox is OFF, so we can write here).
    /// Created on first access. Falls back to the home directory.
    static let folder: URL = {
        let base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("nte_zone_snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Millisecond-resolution stamp so rapid successive snapshots never collide.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return f
    }()

    /// Write `image` to a new PNG. `zone` and `mode` go into the filename so a
    /// folder full of samples is self-describing
    /// (`20260601_142233_551_live_win_eButton_82x118.png`). Returns the URL, or
    /// nil if encoding/writing failed.
    @discardableResult
    static func save(_ image: CGImage, zone: String, mode: String) -> URL? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = "\(stamp.string(from: Date()))_\(mode)_\(zone)_\(image.width)x\(image.height).png"
        let url = folder.appendingPathComponent(name)
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// Open the snapshots folder in Finder.
    static func revealFolder() { NSWorkspace.shared.open(folder) }
}
