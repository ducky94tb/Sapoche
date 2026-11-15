import Foundation

/// What the screen is told of the height of the picture that plays: the heights the song has that this phone plays, the one
/// playing, the tallest this phone plays at all, and why the picture is not as tall as asked. Mirrors `PictureInfo` of Kotlin.
struct PictureInfo: Equatable {
    var heights: [Int] = []
    var now = 0
    var max = VideoPicker.maxPlayableHeight
    /// `metered` (mobile data), `network` (the link was too slow for more), `video` (the song has no taller one); nil for none.
    var limit: String?

    /// [asked] is the height the person chose; [now] the height playing, 0 when no picture plays.
    static func of(heights: [Int], now: Int, asked: Int, metered: Bool, budgetKbps: Int64) -> PictureInfo {
        let max = VideoPicker.maxPlayableHeight
        guard now > 0, !heights.isEmpty else { return PictureInfo(heights: heights, now: now, max: max) }
        let wanted = min(asked, max)
        let allowed = metered ? min(wanted, VideoPicker.maxPlayableHeight) : wanted
        let best = heights.last { $0 <= allowed } ?? heights[0]
        let limit: String?
        if metered && wanted > VideoPicker.maxPlayableHeight && now <= VideoPicker.maxPlayableHeight {
            limit = "metered"
        } else if now < best && budgetKbps > 0 {
            limit = "network"
        } else if now >= best && (heights.last ?? 0) < wanted {
            limit = "video"
        } else {
            limit = nil
        }
        return PictureInfo(heights: heights, now: now, max: max, limit: limit)
    }
}
