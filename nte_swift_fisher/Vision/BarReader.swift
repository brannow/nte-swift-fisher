//
//  BarReader.swift
//  nte_swift_fisher
//
//  Reads the minigame top bar as a 1-D signal. The bar is a thin horizontal
//  strip: a green TARGET band somewhere along it + a yellow MARKER tick (the
//  thing we steer with a/d). Control needs POSITIONS, not "is green present" — so
//  we collapse the 2-D crop vertically into PER-COLUMN colour-fraction profiles
//  and locate each feature along the x axis.
//
//  Why two fraction profiles instead of one averaged colour line: averaging a
//  column that is half marker / half background smears a thin yellow tick into a
//  muddy colour that may not classify as yellow at all. Counting "what fraction
//  of this column is green / is yellow" keeps thin features sharp and lets the
//  green band and the yellow marker be found independently — even where the
//  marker sits on top of the band.
//

import CoreGraphics

struct BarReading: Equatable {
    /// Per-column green-target fraction (0…1), left→right.
    var green: [Double]
    /// Per-column yellow-marker fraction (0…1), left→right.
    var yellow: [Double]
    /// Normalized [0,1] extent of the green band (first…last green column).
    var greenBand: ClosedRange<Double>?
    /// Normalized [0,1] position of the yellow marker (yellow-weighted centroid).
    var marker: Double?

    var columns: Int { green.count }

    /// Centre of the green target band, normalized.
    var targetCenter: Double? {
        greenBand.map { ($0.lowerBound + $0.upperBound) / 2 }
    }

    /// Signed steering error = marker − target centre (normalized). Negative ⇒
    /// marker is LEFT of target, positive ⇒ RIGHT. nil if either is missing.
    var error: Double? {
        guard let m = marker, let c = targetCenter else { return nil }
        return m - c
    }

    /// Whether the marker currently sits within the green band.
    var inBand: Bool {
        guard let m = marker, let b = greenBand else { return false }
        return b.contains(m)
    }
}

enum BarReader {
    /// Collapse `pixelRect` to per-column green/yellow fraction profiles and
    /// extract the green band + yellow marker.
    ///
    /// `columns` is the horizontal resolution of the read; `rows` the vertical
    /// samples per column that we classify and average (a small number denoises
    /// while staying cheap). A column counts toward the band/marker once its
    /// fraction clears `presence`.
    /// `maxGap` bridges tiny holes in the green run (the marker's gap + pixel
    /// noise) — we KNOW the target is one solid bubble, so a few-column hole is an
    /// artefact, not a second band. `minWidth` rejects stray green specks: a run
    /// narrower than this doesn't count as the bubble.
    static func read(of image: CGImage, in pixelRect: CGRect,
                     columns: Int = 240, rows: Int = 12,
                     greenHue: ClosedRange<Double>, yellowHue: ClosedRange<Double>,
                     sMin: Double, vMin: Double, presence: Double = 0.35,
                     maxGap: Int = 6, minWidth: Int = 5) -> BarReading? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = pixelRect.integral.intersection(bounds)
        guard columns >= 1, rows >= 1, crop.width >= 1, crop.height >= 1,
              let sub = image.cropping(to: crop) else { return nil }

        var px = [UInt8](repeating: 0, count: columns * rows * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &px, width: columns, height: rows,
                                  bitsPerComponent: 8, bytesPerRow: columns * 4,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: columns, height: rows))

        var green = [Double](repeating: 0, count: columns)
        var yellow = [Double](repeating: 0, count: columns)
        for c in 0..<columns {
            var g = 0, y = 0
            for r in 0..<rows {
                let i = (r * columns + c) * 4
                let rgb = RGB(r: Double(px[i]) / 255,
                              g: Double(px[i + 1]) / 255,
                              b: Double(px[i + 2]) / 255)
                guard rgb.brightness >= vMin, rgb.saturation >= sMin else { continue }
                let h = rgb.hue
                if greenHue.contains(h) { g += 1 }
                else if yellowHue.contains(h) { y += 1 }
            }
            green[c] = Double(g) / Double(rows)
            yellow[c] = Double(y) / Double(rows)
        }

        func norm(_ i: Int) -> Double { (Double(i) + 0.5) / Double(columns) }

        // Green band = the single widest contiguous green run, after bridging
        // small gaps. We know the target is ONE bubble, so we (1) find runs of
        // above-presence columns, (2) merge runs separated by ≤ maxGap (fills the
        // marker gap + noise holes), (3) keep the widest, (4) require ≥ minWidth.
        // This is robust to stray green columns that naïve min…max would span.
        var runs: [(lo: Int, hi: Int)] = []
        var c = 0
        while c < columns {
            if green[c] >= presence {
                var e = c
                while e + 1 < columns && green[e + 1] >= presence { e += 1 }
                runs.append((c, e))
                c = e + 1
            } else { c += 1 }
        }
        var merged: [(lo: Int, hi: Int)] = []
        for r in runs {
            if !merged.isEmpty, r.lo - merged[merged.count - 1].hi - 1 <= maxGap {
                merged[merged.count - 1].hi = r.hi
            } else {
                merged.append(r)
            }
        }
        let widest = merged.max { ($0.hi - $0.lo) < ($1.hi - $1.lo) }
        let band: ClosedRange<Double>? = widest.flatMap {
            ($0.hi - $0.lo + 1) >= minWidth ? norm($0.lo)...norm($0.hi) : nil
        }

        // Marker = yellow-weighted centroid over columns above presence.
        var wSum = 0.0, iSum = 0.0
        for c in 0..<columns where yellow[c] >= presence {
            wSum += yellow[c]
            iSum += yellow[c] * norm(c)
        }
        let marker = wSum > 0 ? iSum / wSum : nil

        return BarReading(green: green, yellow: yellow, greenBand: band, marker: marker)
    }
}
