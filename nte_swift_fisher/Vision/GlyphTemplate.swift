//
//  GlyphTemplate.swift
//  nte_swift_fisher
//
//  A captured reference of a UI glyph (the E refresh icon, the F hook) as a small
//  NxN grid of "whiteness" values, matched against a live region by NORMALIZED
//  CROSS-CORRELATION (NCC).
//
//  WHY this and not "count the white pixels": the background behind a button is
//  spot-dependent (wood / water / SAND) and day/night-dependent. A bright-pixel
//  count is fooled by a uniformly bright background (sand reads like the glyph).
//  NCC matches the glyph's SHAPE — the spatial pattern of bright/dark — which no
//  natural background reproduces. A uniform region has ~zero variance and thus a
//  ~zero correlation with a structured template, regardless of how bright it is.
//
//  NCC is also zero-mean + unit-norm, so it's invariant to a linear brightness
//  change: the day/night cycle scales every value and cancels out. This is the
//  same maths as OpenCV's matchTemplate(TM_CCOEFF_NORMED), without the C++ dep.
//
//  Both the template and the live region are resampled to the SAME NxN grid, so
//  the window-size scaling of the UI is normalised away as long as the region
//  rect frames the glyph consistently (which our normalized regions do).
//

import Foundation

/// A glyph reference: an `n×n` grid of whiteness features. Empty = not captured.
/// Persisted via @AppStorage (RawRepresentable JSON).
struct GlyphTemplate: Equatable {
    /// Grid side length; 0 when uncaptured.
    var n: Int = 0
    /// Row-major whiteness values, length `n*n`. Empty when uncaptured.
    var features: [Double] = []

    var isEmpty: Bool { features.isEmpty || n == 0 }

    /// Normalized cross-correlation against a live feature grid of the same size.
    /// Returns a score in roughly -1...1 (1 = identical pattern), or nil if either
    /// side is empty / size-mismatched. A near-uniform `live` (e.g. flat sand)
    /// has ~zero variance → score collapses to ~0, which is the whole point.
    func ncc(_ live: [Double]) -> Double? {
        guard !isEmpty, live.count == features.count else { return nil }
        let a = features, b = live
        let count = Double(a.count)
        let ma = a.reduce(0, +) / count
        let mb = b.reduce(0, +) / count
        var num = 0.0, va = 0.0, vb = 0.0
        for i in a.indices {
            let ca = a[i] - ma, cb = b[i] - mb
            num += ca * cb
            va += ca * ca
            vb += cb * cb
        }
        let den = (va * vb).squareRoot()
        return den > 1e-9 ? num / den : 0
    }
}

// Persist via @AppStorage. Serialized through a DTO (see GameRegions for why a
// type that is both Codable and RawRepresentable<Codable> recurses).
extension GlyphTemplate: RawRepresentable {
    private struct DTO: Codable { var n: Int; var features: [Double] }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let d = try? JSONDecoder().decode(DTO.self, from: data) else { return nil }
        self.init(n: d.n, features: d.features)
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(DTO(n: n, features: features)),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
