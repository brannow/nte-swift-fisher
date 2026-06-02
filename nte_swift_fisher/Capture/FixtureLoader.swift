//
//  FixtureLoader.swift
//  nte_swift_fisher
//
//  Loads the reference screenshots from the project's `screens/` folder so we
//  can calibrate regions and validate detection OFFLINE, no running game
//  required. The folder is derived from the current user's home dir (it is a dev
//  convenience and the fixtures are too large, 10MB+ each, to bundle or commit).
//
//  Note: fixture PNGs include the macOS window chrome AND the drop-shadow
//  border, so their content insets differ from a live SCStream capture (which
//  is tight to the window). That difference is exactly what the inset sliders
//  in the overlay let us dial in per-source.
//

import AppKit
import CoreGraphics

enum FixtureLoader {
    static var directory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/xcode/nte_swift_fisher/screens")
            .path
    }

    /// Filenames of available `.png` fixtures, sorted.
    static func available() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".png") }.sorted()
    }

    /// Load a fixture by filename, auto-cropped to the window (drop shadow
    /// removed) so the result matches a tight live SCStream capture.
    static func load(_ filename: String) -> CGImage? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return cropToWindow(img) ?? img
    }

    /// Detect the window's bounding box inside a macOS screenshot and crop to it.
    ///
    /// The screenshot has a dark drop-shadow border around a rounded window whose
    /// title bar (white) and game content (colourful) are bright. We downsample,
    /// take the MAX luminance per row/column (robust on dark night scenes where a
    /// mean would wash out), and bound the span that exceeds a threshold.
    static func cropToWindow(_ img: CGImage, downWidth: Int = 240,
                             threshold: Double = 0.20) -> CGImage? {
        let dw = downWidth
        let dh = max(1, Int(Double(dw) * Double(img.height) / Double(img.width)))
        var buf = [UInt8](repeating: 0, count: dw * dh * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: dw, height: dh,
                                  bitsPerComponent: 8, bytesPerRow: dw * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Flip so buffer row 0 == top of image (matches CGImage cropping space).
        ctx.translateBy(x: 0, y: CGFloat(dh))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: dw, height: dh))

        func lum(_ i: Int) -> Double {
            (Double(buf[i]) * 0.3 + Double(buf[i + 1]) * 0.59 + Double(buf[i + 2]) * 0.11) / 255
        }
        var rowMax = [Double](repeating: 0, count: dh)
        var colMax = [Double](repeating: 0, count: dw)
        for y in 0..<dh {
            for x in 0..<dw {
                let l = lum((y * dw + x) * 4)
                if l > rowMax[y] { rowMax[y] = l }
                if l > colMax[x] { colMax[x] = l }
            }
        }
        let x0 = colMax.firstIndex { $0 > threshold } ?? 0
        let x1 = colMax.lastIndex { $0 > threshold } ?? (dw - 1)
        let y0 = rowMax.firstIndex { $0 > threshold } ?? 0
        let y1 = rowMax.lastIndex { $0 > threshold } ?? (dh - 1)

        let sx = Double(img.width) / Double(dw)
        let sy = Double(img.height) / Double(dh)
        let crop = CGRect(x: Double(x0) * sx, y: Double(y0) * sy,
                          width: Double(x1 - x0 + 1) * sx,
                          height: Double(y1 - y0 + 1) * sy).integral
        return img.cropping(to: crop)
    }
}
