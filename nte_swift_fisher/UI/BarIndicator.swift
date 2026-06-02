//
//  BarIndicator.swift
//  nte_swift_fisher
//
//  Visualises a BarReading: per-column green/yellow profiles, the detected green
//  target band (shaded), and the yellow marker (white line). Shared by the
//  operator view (live minigame indicator) and the config view (calibration).
//

import SwiftUI

struct BarIndicator: View {
    let reading: BarReading?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard let r = reading else { return }
            let cw = size.width / CGFloat(max(r.columns, 1))

            for c in 0..<r.columns {
                let x = CGFloat(c) * cw
                if r.green[c] > 0 {
                    let h = CGFloat(r.green[c]) * size.height
                    ctx.fill(Path(CGRect(x: x, y: size.height - h, width: max(cw, 1), height: h)),
                             with: .color(.green))
                }
                if r.yellow[c] > 0 {
                    let h = CGFloat(r.yellow[c]) * size.height
                    ctx.fill(Path(CGRect(x: x, y: size.height - h, width: max(cw, 1), height: h)),
                             with: .color(.yellow))
                }
            }
            if let b = r.greenBand {
                let x0 = CGFloat(b.lowerBound) * size.width
                let x1 = CGFloat(b.upperBound) * size.width
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                         with: .color(.green.opacity(0.18)))
            }
            if let m = r.marker {
                let x = CGFloat(m) * size.width
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(.white), lineWidth: 1.5)
            }
        }
        .background(Color.black)
        .border(.gray.opacity(0.4))
    }
}
