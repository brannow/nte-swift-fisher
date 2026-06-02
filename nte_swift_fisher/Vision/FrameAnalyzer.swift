//
//  FrameAnalyzer.swift
//  nte_swift_fisher
//
//  Lightweight pixel sampling over a captured CGImage. No ML — the states we
//  care about have distinctive colour signatures, so averaging / classifying a
//  small region is enough and cheap.
//
//  For M0 this provides `averageColor`, which proves the full pipeline works:
//  capture → content rect → normalized region → real pixels. M1+ build hue
//  classification (blue F button, green/yellow bar) on the same access pattern.
//

import CoreGraphics

struct RGB: Equatable, Sendable {
    var r: Double // 0...1
    var g: Double
    var b: Double

    /// Hue in degrees 0...360 (undefined-ish for greys; pair with saturation).
    var hue: Double {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0.0001 else { return 0 }
        let h: Double
        if mx == r { h = (g - b) / d }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h * 60).truncatingRemainder(dividingBy: 360) + (h < 0 ? 360 : 0)
    }

    var saturation: Double {
        let mx = max(r, g, b), mn = min(r, g, b)
        return mx > 0.0001 ? (mx - mn) / mx : 0
    }

    var brightness: Double { max(r, g, b) }
}

enum FrameAnalyzer {
    /// Fraction (0...1) of pixels in `pixelRect` that satisfy `predicate`.
    ///
    /// This is the core detection primitive — "how much of this zone looks like
    /// X". The same shape covers every state: white-ish glyph (IDLE button),
    /// blue ring (bait), green/yellow hue bands (minigame bar), brightness spike
    /// (catch flash). Each just plugs in a different predicate + threshold.
    ///
    /// WHY count real pixels instead of an average: a button is a bright glyph on
    /// a darker disc — its *average* washes toward the background, but the glyph
    /// shows up as a stable FRACTION of bright pixels. Averaging hides exactly the
    /// thing we want to measure.
    ///
    /// The crop is nearest-neighbour subsampled to ≤ `maxDim` on its long side:
    /// caps cost for big zones, and `.none` interpolation means we
    /// subsample real pixels rather than BLENDING glyph into background (which
    /// would smear the very distinction we're counting).
    static func pixelFraction(of image: CGImage, in pixelRect: CGRect,
                              maxDim: Int = 96,
                              predicate: (RGB) -> Bool) -> Double {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = pixelRect.integral.intersection(bounds)
        guard crop.width >= 1, crop.height >= 1,
              let sub = image.cropping(to: crop) else { return 0 }

        let longSide = max(sub.width, sub.height)
        let s = longSide > maxDim ? Double(maxDim) / Double(longSide) : 1
        let w = max(1, Int(Double(sub.width) * s))
        let h = max(1, Int(Double(sub.height) * s))

        var px = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &px, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: info) else { return 0 }
        ctx.interpolationQuality = .none
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))

        let total = w * h
        var hits = 0
        for i in stride(from: 0, to: total * 4, by: 4) {
            let rgb = RGB(r: Double(px[i]) / 255,
                          g: Double(px[i + 1]) / 255,
                          b: Double(px[i + 2]) / 255)
            if predicate(rgb) { hits += 1 }
        }
        return Double(hits) / Double(total)
    }

    /// Resample `pixelRect` to an `n×n` grid of "whiteness" (`v·(1−s)`) — the
    /// feature used for template matching (see GlyphTemplate). Used both to
    /// CAPTURE a template and to score a live region; both sides must use the
    /// same `n` so NCC compares like-for-like.
    ///
    /// `whiteness = brightness · (1 − saturation)` encodes "the glyph is WHITE":
    /// bright *and* colourless scores high, bright *and* colourful (cream sand,
    /// the cyan water glint, a yellow marker) is suppressed before correlation.
    ///
    /// Downsampling uses `.medium` (area-averaging) on purpose here — unlike the
    /// fraction counter, we WANT each cell to summarise its patch; that denoises
    /// the grid and tolerates the glyph shifting by a pixel between captures.
    static func featureGrid(of image: CGImage, in pixelRect: CGRect, n: Int) -> [Double]? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = pixelRect.integral.intersection(bounds)
        guard n >= 1, crop.width >= 1, crop.height >= 1,
              let sub = image.cropping(to: crop) else { return nil }

        var px = [UInt8](repeating: 0, count: n * n * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &px, width: n, height: n,
                                  bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: n, height: n))

        var grid = [Double](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            let rgb = RGB(r: Double(px[i * 4]) / 255,
                          g: Double(px[i * 4 + 1]) / 255,
                          b: Double(px[i * 4 + 2]) / 255)
            grid[i] = rgb.brightness * (1 - rgb.saturation)
        }
        return grid
    }

    /// Fraction of pixels in a hue band that are also sufficiently saturated and
    /// bright. The colour-based counterpart to template matching, for signals
    /// defined by COLOUR rather than shape — e.g. the bait blue ring (which
    /// animates, so its shape is unstable but its blue is constant), and later
    /// the minigame's green target / yellow marker bands.
    ///
    /// `sMin` is the important gate: it rejects a muted, low-saturation version of
    /// the same hue bleeding through (e.g. a water-spot background under the
    /// button's translucent disc) while passing the bright, saturated UI element.
    ///
    /// `hue` is treated as a plain closed range in 0...360 (no wrap-around — fine
    /// for blue/green/yellow, none of which straddle 0°).
    static func hueFraction(of image: CGImage, in pixelRect: CGRect,
                            hue: ClosedRange<Double>, sMin: Double, vMin: Double) -> Double {
        pixelFraction(of: image, in: pixelRect) {
            $0.brightness >= vMin && $0.saturation >= sMin && hue.contains($0.hue)
        }
    }

    /// Fraction of "white-ish" pixels — BRIGHT and DESATURATED. This is the UI
    /// glyph signature used to detect a button's presence (IDLE = eButton glyph).
    ///
    /// The gates are deliberately TIGHT and tunable: the glyph is near-pure white
    /// (v≈1, s≈0), while the worst-case background — pale SAND — is cream (v≈0.8,
    /// s≈0.2). A high `vMin` + low `sMax` is what keeps sand from masquerading as
    /// a glyph. Calibrate against real sand/water/wood captures, never assume.
    static func whiteishFraction(of image: CGImage, in pixelRect: CGRect,
                                 vMin: Double, sMax: Double) -> Double {
        pixelFraction(of: image, in: pixelRect) {
            $0.brightness >= vMin && $0.saturation <= sMax
        }
    }

    /// Average colour of `pixelRect` (top-left origin, pixel space) within `image`.
    /// Implemented by downsampling the cropped region to 1×1 and reading the
    /// resulting pixel — fast and allocation-light.
    static func averageColor(of image: CGImage, in pixelRect: CGRect) -> RGB? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = pixelRect.integral.intersection(bounds)
        guard crop.width >= 1, crop.height >= 1,
              let sub = image.cropping(to: crop) else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &px, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGB(r: Double(px[0]) / 255, g: Double(px[1]) / 255, b: Double(px[2]) / 255)
    }
}
