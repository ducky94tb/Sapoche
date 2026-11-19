import Foundation

/// The soft change between two songs: the last seconds of a song fade out and the first half of that time of the next
/// song fades in. The songs do not overlap, so no moment of the room's timeline moves and the gapless change stays.
///
/// Only the volume is a function of the position; whether a fade applies at the start (the song came by itself, not by a
/// press on Next) and at the end (a song follows) is for the player's side to say.
enum Crossfade {
    static let maxSeconds = 12

    /// A song shorter than this many times the fade time is played as it is.
    private static let minSongFactor: Int64 = 3

    private static let endSlackMs: Int64 = 1500

    /// The fade is on for songs of this length.
    static func applies(durationMs: Int64, seconds: Int) -> Bool {
        (1...maxSeconds).contains(seconds) && durationMs >= minSongFactor * Int64(seconds) * 1000
    }

    /// The share (0...1) of the volume that [positionMs] of a song [durationMs] long gets; 1 outside the two fades.
    static func ramp(positionMs: Int64, durationMs: Int64, seconds: Int, fadeIn: Bool, fadeOut: Bool) -> Float {
        guard applies(durationMs: durationMs, seconds: seconds) else { return 1 }
        let outMs = Int64(seconds) * 1000
        let inMs = outMs / 2
        var level: Float = 1
        if fadeOut, durationMs - positionMs < outMs { level *= curve(Float(max(durationMs - positionMs, 0)) / Float(outMs)) }
        if fadeIn, positionMs < inMs { level *= curve(Float(max(positionMs, 0)) / Float(inMs)) }
        return level
    }

    /// Whether a song that was last seen playing at [lastPositionMs], [elapsedMs] ago, has played to its end by now.
    static func endedItself(lastPositionMs: Int64, durationMs: Int64, elapsedMs: Int64) -> Bool {
        durationMs > 0 && lastPositionMs + elapsedMs >= durationMs - (endSlackMs + elapsedMs / 20)
    }

    /// 0 to 1 over [share] 0 to 1; sin squared, so that the two ends are soft.
    private static func curve(_ share: Float) -> Float {
        let s = sin(Double.pi / 2 * Double(share))
        return Float(s * s)
    }
}
