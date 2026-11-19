import Foundation

/// The equalizer: six bands (see `freqs`) from -12 to +12 dB. The first band is a low shelf, the last a high shelf, the
/// four between are peaking filters (the RBJ cookbook). Every band that is not at 0 is one biquad; the sound is turned
/// down by the largest boost first (`preampDb`) so that a boost cannot clip.
///
/// The same numbers are in `Eq.kt` and in `eq_vectors.json`, which both test against.
enum Eq {
    static let bands = 6
    static let maxDb = 12

    static let freqs = [60, 150, 400, 1000, 2400, 15000]

    /// The share of the sample rate above which a band is left out (a filter near half the rate is not worth its noise).
    private static let nyquistShare = 0.45

    private static let peakQ = 1.0
    private static let shelfQ = 0.7071

    /// One filter, divided by a0: y = b0 x + z1, z1 = b1 x - a1 y + z2, z2 = b2 x - a2 y.
    struct Biquad: Equatable {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
    }

    /// [gains] as the six whole dB the player takes: the missing ones are 0, the others are held to the range.
    static func clean(_ gains: [Double]?) -> [Int] {
        (0..<bands).map { i in
            guard let gains, i < gains.count else { return 0 }
            return min(max(Int(gains[i].rounded(.toNearestOrAwayFromZero)), -maxDb), maxDb)
        }
    }

    static func isFlat(_ gains: [Int]) -> Bool { gains.allSatisfy { $0 == 0 } }

    /// The gain (0 or below) that keeps the loudest boost from going past full scale.
    static func preampDb(_ gains: [Int]) -> Double { -Double(max(0, gains.max() ?? 0)) }

    /// The filters for [sampleRate]: one per band, nil where the band is 0 dB or too near half the sample rate.
    static func coefficients(sampleRate: Int, gains: [Int]) -> [Biquad?] {
        (0..<bands).map { i in
            let gain = gains[i]
            if gain == 0 || Double(freqs[i]) >= Double(sampleRate) * nyquistShare { return nil }
            return biquad(sampleRate: sampleRate, band: i, gainDb: gain)
        }
    }

    private static func biquad(sampleRate: Int, band: Int, gainDb: Int) -> Biquad {
        let a = pow(10.0, Double(gainDb) / 40)
        let w = 2 * Double.pi * Double(freqs[band]) / Double(sampleRate)
        let c = cos(w), s = sin(w)
        let b0, b1, b2, a0, a1, a2: Double
        if band != 0 && band != bands - 1 {
            let alpha = s / (2 * peakQ)
            b0 = 1 + alpha * a; b1 = -2 * c; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * c; a2 = 1 - alpha / a
        } else {
            let sq = 2 * a.squareRoot() * (s / (2 * shelfQ))
            if band == 0 {
                b0 = a * ((a + 1) - (a - 1) * c + sq); b1 = 2 * a * ((a - 1) - (a + 1) * c); b2 = a * ((a + 1) - (a - 1) * c - sq)
                a0 = (a + 1) + (a - 1) * c + sq; a1 = -2 * ((a - 1) + (a + 1) * c); a2 = (a + 1) + (a - 1) * c - sq
            } else {
                b0 = a * ((a + 1) + (a - 1) * c + sq); b1 = -2 * a * ((a - 1) + (a + 1) * c); b2 = a * ((a + 1) + (a - 1) * c - sq)
                a0 = (a + 1) - (a - 1) * c + sq; a1 = 2 * ((a - 1) - (a + 1) * c); a2 = (a + 1) - (a - 1) * c - sq
            }
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static let knee: Float = 0.9

    /// Samples under 0.9 are left as they are; above it they bend toward 1 and never pass it.
    static func softClip(_ x: Float) -> Float {
        let m = abs(x)
        if m <= knee { return x }
        let shaped = knee + (1 - knee) * Float(tanh(Double((m - knee) / (1 - knee))))
        return x < 0 ? -shaped : shaped
    }
}

/// The filters of the equalizer over a block of samples between -1 and 1, one channel at a time. One thread calls
/// `begin`, `process` and `end` (the sound's) and `configure`; `setGains` may come from any thread. A change of the gains
/// is spread over the next block (the coefficients move from the old to the new in a straight line while the state of the
/// filters goes on), so that it makes no click.
final class EqFilter {
    private let lock = NSLock()
    private var wanted = [Int](repeating: 0, count: Eq.bands)

    private var sampleRate = 0
    private var channels = 0
    private var applied = [Int](repeating: 0, count: Eq.bands)
    private var from = [Eq.Biquad?](repeating: nil, count: Eq.bands)
    private var to = [Eq.Biquad?](repeating: nil, count: Eq.bands)
    private var preampFrom = 1.0
    private var preampTo = 1.0
    private var moving = false
    private var steady = true
    private var z1: [Double] = []
    private var z2: [Double] = []

    private func goal() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return wanted
    }

    /// [gains] are six whole dB (see `Eq.clean`).
    func setGains(_ gains: [Int]) {
        lock.lock()
        wanted = gains
        lock.unlock()
    }

    /// Nothing is filtered: the sound goes through as it is.
    var isFlat: Bool { !moving && Eq.isFlat(applied) && Eq.isFlat(goal()) }

    func configure(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        z1 = [Double](repeating: 0, count: Eq.bands * channels)
        z2 = [Double](repeating: 0, count: Eq.bands * channels)
        applied = goal()
        to = Eq.coefficients(sampleRate: sampleRate, gains: applied)
        from = to
        preampTo = pow(10.0, Eq.preampDb(applied) / 20)
        preampFrom = preampTo
        moving = false
    }

    /// Starts a block: false when the block is to go through as it is (call neither `process` nor `end` then).
    func begin() -> Bool {
        let wantedNow = goal()
        if wantedNow != applied {
            // The filters as they stand now are where the move starts
            from = to
            preampFrom = preampTo
            applied = wantedNow
            to = Eq.coefficients(sampleRate: sampleRate, gains: wantedNow)
            preampTo = pow(10.0, Eq.preampDb(wantedNow) / 20)
            moving = true
        }
        if !moving && Eq.isFlat(applied) {
            if z1.contains(where: { $0 != 0 }) {
                for i in z1.indices { z1[i] = 0; z2[i] = 0 }
            }
            return false
        }
        steady = !moving
        return true
    }

    /// Filters [frames] samples of one channel in place, [stride] apart.
    func process(channel: Int, samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int) {
        for i in 0..<frames {
            let t = steady ? 1.0 : (Double(i) + 1) / Double(frames)
            var x = Double(samples[i * stride]) * (preampFrom + (preampTo - preampFrom) * t)
            for b in 0..<Eq.bands {
                let f = from[b], g = to[b]
                if f == nil && g == nil { continue }
                let k = b * channels + channel
                let c: Eq.Biquad
                if steady {
                    c = g!
                } else {
                    let p = f ?? .identity, q = g ?? .identity
                    c = Eq.Biquad(
                        b0: p.b0 + (q.b0 - p.b0) * t, b1: p.b1 + (q.b1 - p.b1) * t, b2: p.b2 + (q.b2 - p.b2) * t,
                        a1: p.a1 + (q.a1 - p.a1) * t, a2: p.a2 + (q.a2 - p.a2) * t)
                }
                let y = c.b0 * x + z1[k]
                z1[k] = c.b1 * x - c.a1 * y + z2[k]
                z2[k] = c.b2 * x - c.a2 * y
                x = y
            }
            samples[i * stride] = Eq.softClip(Float(x))
        }
    }

    /// Ends a block that `begin` started.
    func end() {
        if moving {
            moving = false
            from = to
            preampFrom = preampTo
        }
    }
}
