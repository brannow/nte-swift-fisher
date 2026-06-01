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
