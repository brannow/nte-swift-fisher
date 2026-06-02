//
//  Log.swift
//  nte_swift_fisher
//
//  Tiny console logger for bot actions. Each line is prefixed with a datetime to
//  microsecond precision (DateFormatter only resolves to milliseconds, so we
//  compute the microseconds from the Date's fractional second ourselves).
//

import Foundation

enum Log {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func msg(_ s: String) {
        let now = Date()
        let t = now.timeIntervalSince1970
        let micros = Int((t - floor(t)) * 1_000_000)
        print(String(format: "%@.%06d %@", stamp.string(from: now), micros, s))
    }
}
