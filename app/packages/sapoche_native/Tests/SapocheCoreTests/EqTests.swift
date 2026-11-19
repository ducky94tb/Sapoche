import XCTest
@testable import SapocheCore

final class EqTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: fixture("eq_vectors")) as! [String: Any]
    }

    /// `EqTest.kt` checks the same file: the two platforms filter by the same numbers.
    func testTheCoefficientsAreTheOnesKotlinTestsAgainst() throws {
        for item in try vectors()["cases"] as! [[String: Any]] {
            let rate = item["sampleRate"] as! Int
            let gains = Eq.clean((item["gains"] as! [Int]).map(Double.init))
            let bands = item["bands"] as! [Any]
            XCTAssertEqual(item["preampDb"] as! Double, Eq.preampDb(gains), accuracy: 1e-9)
            let got = Eq.coefficients(sampleRate: rate, gains: gains)
            for i in 0..<Eq.bands {
                guard let want = bands[i] as? [Double] else {
                    XCTAssertNil(got[i], "band \(i) at \(rate) Hz, gains \(gains)")
                    continue
                }
                let g = try XCTUnwrap(got[i])
                XCTAssertEqual(want[0], g.b0, accuracy: 1e-7)
                XCTAssertEqual(want[1], g.b1, accuracy: 1e-7)
                XCTAssertEqual(want[2], g.b2, accuracy: 1e-7)
                XCTAssertEqual(want[3], g.a1, accuracy: 1e-7)
                XCTAssertEqual(want[4], g.a2, accuracy: 1e-7)
            }
        }
    }

    func testGainsAreWholeDbHeldToTheRangeAndMissingOnesAreZero() {
        XCTAssertEqual(Eq.clean([40, -40, 2.6]), [12, -12, 3, 0, 0, 0])
        XCTAssertEqual(Eq.clean(nil), [0, 0, 0, 0, 0, 0])
    }

    private func sine(_ freq: Double, rate: Int, frames: Int, start: Int = 0) -> [Float] {
        (0..<frames).map { Float(0.25 * sin(2 * Double.pi * freq * Double(start + $0) / Double(rate))) }
    }

    /// Filters one channel in one block and gives the peak of its second half, after the filters settled.
    private func peakAfter(_ gains: [Int], freq: Double, rate: Int = 44100) -> (Float, Float) {
        let filter = EqFilter()
        filter.setGains(gains)
        filter.configure(sampleRate: rate, channels: 1)
        var samples = sine(freq, rate: rate, frames: rate)
        let input = samples
        if filter.begin() {
            samples.withUnsafeMutableBufferPointer { filter.process(channel: 0, samples: $0.baseAddress!, stride: 1, frames: rate) }
            filter.end()
        }
        let half = rate / 2
        return (input[half...].map(abs).max()!, samples[half...].map(abs).max()!)
    }

    func testFlatGainsLeaveEveryBlockAsItWas() {
        let filter = EqFilter()
        filter.configure(sampleRate: 44100, channels: 2)
        XCTAssertTrue(filter.isFlat)
        XCTAssertFalse(filter.begin())
    }

    func testABoostAt1kHzIsAsLoudAsBeforeAfterThePreampAndTheRestIsHalf() {
        let gains = [0, 0, 0, 6, 0, 0]
        let (on, onOut) = peakAfter(gains, freq: 1000)
        XCTAssertEqual(on, onOut, accuracy: 0.01)
        let (low, lowOut) = peakAfter(gains, freq: 100)
        XCTAssertEqual(low * 0.5, lowOut, accuracy: 0.02)
        let (high, highOut) = peakAfter(gains, freq: 15000)
        XCTAssertEqual(high * 0.5, highOut, accuracy: 0.02)
    }

    func testTheFirstBandLiftsTheBassTheLastTheTrebleAndACutIsACut() {
        let (bass, bassOut) = peakAfter([6, 0, 0, 0, 0, 0], freq: 30)
        XCTAssertEqual(bass, bassOut, accuracy: 0.02)
        let (treble, trebleOut) = peakAfter([0, 0, 0, 0, 0, 6], freq: 18000)
        XCTAssertEqual(treble, trebleOut, accuracy: 0.03)
        let (cut, cutOut) = peakAfter([0, 0, 0, -12, 0, 0], freq: 1000)
        XCTAssertEqual(cut * 0.25, cutOut, accuracy: 0.01)
    }

    func testALoudSongWithTheBiggestBoostStaysUnderFullScale() {
        let rate = 44100
        let filter = EqFilter()
        filter.setGains([12, 12, 6, 0, 0, 0])
        filter.configure(sampleRate: rate, channels: 1)
        var loud = (0..<rate).map { Float(0.99 * sin(2 * Double.pi * 80 * Double($0) / Double(rate))) }
        XCTAssertTrue(filter.begin())
        loud.withUnsafeMutableBufferPointer { filter.process(channel: 0, samples: $0.baseAddress!, stride: 1, frames: rate) }
        filter.end()
        XCTAssertTrue(loud.allSatisfy { abs($0) <= 1 })
    }

    func testSoftClipLeavesSmallSamplesAndNeverPassesOne() {
        XCTAssertEqual(Eq.softClip(0.5), 0.5)
        XCTAssertEqual(Eq.softClip(-0.9), -0.9)
        XCTAssertTrue(Eq.softClip(5) <= 1 && Eq.softClip(5) > 0.99)
        XCTAssertEqual(Eq.softClip(-2), -Eq.softClip(2))
    }

    func testAChangeOfGainsWhilePlayingMovesWithoutAJump() {
        let rate = 44100
        let filter = EqFilter()
        filter.configure(sampleRate: rate, channels: 1)
        var first = sine(300, rate: rate, frames: rate)
        if filter.begin() {
            first.withUnsafeMutableBufferPointer { filter.process(channel: 0, samples: $0.baseAddress!, stride: 1, frames: rate) }
            filter.end()
        }
        filter.setGains([12, 6, 0, 0, 0, 0])
        let original = sine(300, rate: rate, frames: 1024, start: rate)
        var next = original
        XCTAssertTrue(filter.begin())
        next.withUnsafeMutableBufferPointer { filter.process(channel: 0, samples: $0.baseAddress!, stride: 1, frames: 1024) }
        filter.end()
        XCTAssertEqual(original[0], next[0], accuracy: 0.01)
        let ownStep = (1..<original.count).map { abs(original[$0] - original[$0 - 1]) }.max()!
        let step = (1..<next.count).map { abs(next[$0] - next[$0 - 1]) }.max()!
        XCTAssertLessThan(step, ownStep * 2.5)
    }

    func testBackToFlatTheSoundGoesThroughUntouchedAgain() {
        let filter = EqFilter()
        filter.setGains([6, 0, 0, 0, 0, 0])
        filter.configure(sampleRate: 44100, channels: 1)
        var block = sine(200, rate: 44100, frames: 2048)
        XCTAssertTrue(filter.begin())
        block.withUnsafeMutableBufferPointer { filter.process(channel: 0, samples: $0.baseAddress!, stride: 1, frames: 2048) }
        filter.end()
        filter.setGains([0, 0, 0, 0, 0, 0])
        XCTAssertTrue(filter.begin())
        block.withUnsafeMutableBufferPointer { filter.process(channel: 0, samples: $0.baseAddress!, stride: 1, frames: 2048) }
        filter.end()
        XCTAssertFalse(filter.begin())
        XCTAssertTrue(filter.isFlat)
    }

    func testABandBeyondWhatTheSampleRateHoldsIsLeftOut() {
        XCTAssertNil(Eq.coefficients(sampleRate: 22050, gains: [0, 0, 0, 0, 0, 6])[5])
    }

    func testTwoChannelsInOneBufferAreFilteredApart() {
        let rate = 44100
        let filter = EqFilter()
        filter.setGains([0, 0, 0, 6, 0, 0])
        filter.configure(sampleRate: rate, channels: 2)
        // left plays 1 kHz, right is silent: the right must stay silent
        var buffer = [Float](repeating: 0, count: 2 * rate)
        for i in 0..<rate { buffer[2 * i] = Float(0.25 * sin(2 * Double.pi * 1000 * Double(i) / Double(rate))) }
        XCTAssertTrue(filter.begin())
        buffer.withUnsafeMutableBufferPointer { p in
            for c in 0..<2 { filter.process(channel: c, samples: p.baseAddress! + c, stride: 2, frames: rate) }
        }
        filter.end()
        XCTAssertEqual((0..<rate).map { abs(buffer[2 * $0 + 1]) }.max()!, 0, accuracy: 1e-6)
        XCTAssertGreaterThan((rate / 2..<rate).map { abs(buffer[2 * $0]) }.max()!, 0.2)
    }
}
