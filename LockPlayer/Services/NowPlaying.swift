import AppKit
import CoreImage
import Observation
import SwiftUI

/// Le morceau en cours, alimenté par une `PlayerSource`.
@MainActor
@Observable
final class NowPlaying {
    var title = ""
    var artist = ""
    var album = ""
    var duration: Double = 0
    /// Position (s) au moment `timestamp`.
    var elapsedAtTimestamp: Double = 0
    var timestamp = Date()
    var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var accent = Color(white: 0.3)
    var sourceDescription = "Recherche…"

    var hasTrack: Bool { !title.isEmpty }
    var trackKey: String { "\(artist)\u{1F}\(title)" }

    func elapsed(at date: Date) -> Double {
        var value = elapsedAtTimestamp
        if isPlaying { value += date.timeIntervalSince(timestamp) }
        if duration > 0 { value = min(value, duration) }
        return max(0, value)
    }

    func setArtwork(_ image: NSImage?) {
        artwork = image
        accent = image.flatMap(ArtworkColor.average) ?? Color(white: 0.3)
    }

    /// Mise à jour locale immédiate (avant la confirmation du lecteur).
    func setPlaying(_ playing: Bool) {
        let now = Date()
        elapsedAtTimestamp = elapsed(at: now)
        timestamp = now
        isPlaying = playing
    }

    func setPosition(_ seconds: Double) {
        elapsedAtTimestamp = seconds
        timestamp = Date()
    }

    func clear() {
        title = ""
        artist = ""
        album = ""
        duration = 0
        elapsedAtTimestamp = 0
        isPlaying = false
        setArtwork(nil)
    }
}

enum ArtworkColor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func average(_ image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}
