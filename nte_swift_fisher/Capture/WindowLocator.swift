//
//  WindowLocator.swift
//  nte_swift_fisher
//
//  Finds the live NTE game window via ScreenCaptureKit's shareable content.
//
//  IMPORTANT: match the owning application NAME *exactly* ("NTE"). An earlier
//  version also matched any window whose title or bundle id merely *contained*
//  "nte" — which wrongly grabbed our own editor/terminal window titled
//  "nte_swift_fisher …". "nte" is far too common a substring to fuzzy-match.
//

import ScreenCaptureKit

enum WindowLocatorError: LocalizedError {
    case notFound
    var errorDescription: String? {
        "NTE window not found. Is the game running and on screen, and has screen-recording permission been granted?"
    }
}

struct WindowCandidate: Identifiable {
    let id: CGWindowID
    let appName: String
    let title: String
    let frame: CGRect
    let window: SCWindow
}

enum WindowLocator {
    /// The game's application name as reported by macOS (/Applications/NTE.app).
    static let appName = "NTE"

    /// Returns the best-matching on-screen NTE window, or nil if none found.
    static func findNTE() async throws -> SCWindow? {
        let candidates = try await listCandidates()
        // Exact application-name match only; pick the largest (the game viewport).
        return candidates
            .filter { $0.appName.caseInsensitiveCompare(appName) == .orderedSame }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?
            .window
    }

    /// All on-screen windows of a usable size — for diagnostics / manual pick.
    static func listCandidates() async throws -> [WindowCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        return content.windows
            .filter { $0.frame.width > 200 && $0.frame.height > 150 }
            .map {
                WindowCandidate(id: $0.windowID,
                                appName: $0.owningApplication?.applicationName ?? "?",
                                title: $0.title ?? "",
                                frame: $0.frame,
                                window: $0)
            }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }
}
