import Foundation

/// The name of a picture's height as YouTube gives it: a 1920×1012 video (a wide film frame) is "1080p", not 1012p, as the
/// heights of the streams of such a video are those of the frame cut to its shape. Mirrors `VideoLevels` of Kotlin.
enum VideoLevels {
    private static let standard = [144, 240, 360, 480, 720, 1080, 1440, 2160, 4320]

    /// The standard height nearest to what [width] and [height] stand for: for a picture wider than 16:9 the height it would have
    /// at 16:9, for a taller one its height, and for an upright one its width (YouTube names those by the short side).
    static func nominalHeight(width: Int, height: Int) -> Int {
        guard height > 0 else { return height }
        let raw = width > 0 && width < height ? width : max(height, (width * 9 + 8) / 16)
        return standard.min { abs(log(Double($0) / Double(raw))) < abs(log(Double($1) / Double(raw))) } ?? height
    }
}
