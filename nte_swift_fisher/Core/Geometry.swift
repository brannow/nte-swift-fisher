//
//  Geometry.swift
//  nte_swift_fisher
//
//  The coordinate math that everything else trusts.
//
//  WHY this exists: the game UI is responsive (scales with window size) and we
//  capture on a Retina display, so we juggle THREE coordinate spaces and must
//  never confuse them:
//
//   1. Pixel space   — the captured CGImage (e.g. 3376×2324 px). Used for all
//                       pixel sampling / detection.
//   2. Point space   — global screen coordinates, top-left origin (what
//                       SCWindow.frame and CGEvent mouse positions use).
//                       scale = pixelWidth / pointWidth (≈2.0 on Retina).
//   3. Normalized    — (x,y,w,h) as fractions 0...1 of the *content rect*
//                       (the game viewport = window minus the macOS title bar).
//                       This is what makes detection independent of window size.
//
//  All rects here use a TOP-LEFT origin to match CGImage and CG global coords.
//

import CoreGraphics
import Foundation

/// A rectangle expressed as fractions (0...1) of some reference rect.
/// Origin is top-left, matching image/pixel coordinates.
struct NormRect: Equatable, Sendable, Codable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    /// Resolve this normalized rect against a concrete reference rect.
    func absolute(in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + x * rect.width,
               y: rect.minY + y * rect.height,
               width: w * rect.width,
               height: h * rect.height)
    }

    /// Center point as fractions, useful for click targets.
    var center: (x: Double, y: Double) { (x + w / 2, y + h / 2) }
}

/// Content-rect insets as fractions of the image dimensions. Used in FIXTURE
/// mode to fine-tune the auto-cropped viewport per screenshot (the cropToWindow
/// heuristic differs for windowed-with-titlebar vs fullscreen captures).
struct FractionalInsets: Equatable, Sendable, Codable {
    var top: Double = 0
    var bottom: Double = 0
    var leading: Double = 0
    var trailing: Double = 0
}

/// Per-fixture content-rect insets, keyed by filename, persistable via
/// @AppStorage (RawRepresentable JSON). Each screenshot keeps its own set since
/// windowed-with-titlebar and fullscreen captures crop differently.
///
/// Use `mutate(_:_:)` to change a single field — the subscript returns a *copy*
/// (FractionalInsets is a value type), so `map[name].top = 0.1` silently does
/// nothing. `mutate` does the read-modify-write atomically.
struct FixtureInsetMap: RawRepresentable, Equatable {
    var map: [String: FractionalInsets] = [:]

    init() {}
    init(map: [String: FractionalInsets]) { self.map = map }

    /// Read-only access (returns zero insets for unknown fixtures).
    subscript(_ name: String) -> FractionalInsets {
        map[name] ?? FractionalInsets()
    }

    /// Safely mutate one field of a fixture's insets without the value-type trap.
    mutating func mutate(_ name: String, _ keyPath: WritableKeyPath<FractionalInsets, Double>, _ value: Double) {
        var insets = map[name] ?? FractionalInsets()
        insets[keyPath: keyPath] = value
        map[name] = insets
    }

    /// Reset a single fixture's insets to zero (removes from map to keep JSON clean).
    mutating func reset(_ name: String) {
        map.removeValue(forKey: name)
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: FractionalInsets].self, from: data)
        else { return nil }
        map = decoded
    }
    var rawValue: String {
        guard let data = try? JSONEncoder().encode(map),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

enum Geometry {
    /// Aspect-fit `imageSize` inside `bounds`, returning where the image is drawn.
    /// Used to map pixel rects onto the on-screen SwiftUI view for overlays.
    static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: bounds.minX + (bounds.width - w) / 2,
                      y: bounds.minY + (bounds.height - h) / 2,
                      width: w, height: h)
    }
}

/// Bundles a captured frame with the geometry needed to convert between spaces.
///
/// The captured frame (live SCStream, or a shadow-cropped fixture) represents
/// the WINDOW: macOS title bar on top, game viewport below. The content rect =
/// game viewport = window minus the title bar. The title bar is a FIXED point
/// height (≈28pt), so we inset by `titleBarPoints × scale` pixels — never a
/// fraction, because the title bar is a different fraction at every window size.
///
/// In LIVE mode, `framePoints` is the real window frame (global, top-left) and
/// `scale` ≈ 2 — so `globalPoint(...)` yields a usable mouse-click target.
/// In FIXTURE mode we set framePoints = (0,0, pixelSize/2) so scale = 2 (the
/// reference screenshots are Retina 2× captures); clicks are irrelevant offline.
struct WindowGeometry: Equatable {
    var framePoints: CGRect    // global screen coords, top-left origin
    var pixelSize: CGSize      // captured image dimensions in pixels
    var titleBarPoints: Double // macOS title bar height in points (≈32) — a real
                               // viewport CROP: reduces height.
    /// Extra fractional insets, used in fixture mode to match the auto-crop to
    /// the real viewport. Zero for live capture.
    var contentInsets = FractionalInsets()

    var scale: CGFloat {
        framePoints.width > 0 ? pixelSize.width / framePoints.width : 1
    }

    /// Game viewport in pixel space (for sampling the captured image).
    var contentRectPixels: CGRect {
        let top = titleBarPoints * Double(scale) + contentInsets.top * pixelSize.height
        let bottom = contentInsets.bottom * pixelSize.height
        let left = contentInsets.leading * pixelSize.width
        let right = contentInsets.trailing * pixelSize.width
        return CGRect(x: left, y: top,
                      width: max(0, pixelSize.width - left - right),
                      height: max(0, pixelSize.height - top - bottom))
    }

    /// Game viewport in global point space (for mouse events).
    var contentRectPoints: CGRect {
        let s = scale
        let p = contentRectPixels
        return CGRect(x: framePoints.minX + p.minX / s,
                      y: framePoints.minY + p.minY / s,
                      width: p.width / s,
                      height: p.height / s)
    }

    /// A normalized region resolved to pixel space (detection / sampling).
    func pixelRect(_ n: NormRect) -> CGRect { n.absolute(in: contentRectPixels) }

    /// A normalized region resolved to global point space (mouse target).
    func globalPointRect(_ n: NormRect) -> CGRect { n.absolute(in: contentRectPoints) }

    /// A normalized point resolved to a global screen point (mouse click target).
    func globalPoint(normX: Double, normY: Double) -> CGPoint {
        let r = contentRectPoints
        return CGPoint(x: r.minX + normX * r.width,
                       y: r.minY + normY * r.height)
    }
}
