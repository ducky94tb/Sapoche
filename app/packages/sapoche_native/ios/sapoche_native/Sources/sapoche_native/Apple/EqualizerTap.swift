import AVFoundation
import MediaToolbox

/// The bands of the equalizer as the player last got them, read by the sound's thread of every tap at each block.
final class EqualizerState: @unchecked Sendable {
    private let lock = NSLock()
    private var held = [Int](repeating: 0, count: Eq.bands)

    var gains: [Int] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return held
        }
        set {
            lock.lock()
            held = newValue
            lock.unlock()
        }
    }
}

/// The equalizer in the way of a song that plays from a file: a tap on the sound of the item (`MTAudioProcessingTap`),
/// which runs it through an `EqFilter`. The tap does not run for a song played through an HLS playlist, so those (and a
/// picture put beside the sound) play without it; that is as it is on the platform, and the page of the equalizer says so.
/// Each item has its own filter, because it keeps what it heard of the sound before; they all follow one [EqualizerState].
enum EqualizerTap {
    /// An audio mix that runs the first sound track of [asset] through the equalizer; nil when there is none.
    static func mix(for asset: AVAsset, state: EqualizerState) async -> AVAudioMix? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let tap = makeTap(state: state) else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// What a tap holds: the filter, and what the sound is like (known once the player prepares the tap).
    private final class Box {
        let state: EqualizerState
        let filter = EqFilter()
        var channels = 0
        var interleaved = false
        /// The sound is 32 bit float, which is all that is handled; anything else goes through as it is.
        var usable = false

        init(state: EqualizerState) { self.state = state }

        func prepare(_ format: AudioStreamBasicDescription) {
            let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
            channels = Int(format.mChannelsPerFrame)
            interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            usable = isFloat && channels > 0 && format.mSampleRate >= 8000
            if usable {
                filter.setGains(state.gains)
                filter.configure(sampleRate: Int(format.mSampleRate), channels: channels)
            }
        }

        func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            guard usable, frames > 0 else { return }
            filter.setGains(state.gains)
            guard filter.begin() else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            if interleaved {
                if let data = buffers.first?.mData {
                    let base = data.assumingMemoryBound(to: Float.self)
                    for c in 0..<channels { filter.process(channel: c, samples: base + c, stride: channels, frames: frames) }
                }
            } else {
                for c in 0..<min(channels, buffers.count) {
                    if let data = buffers[c].mData {
                        filter.process(channel: c, samples: data.assumingMemoryBound(to: Float.self), stride: 1, frames: frames)
                    }
                }
            }
            filter.end()
        }
    }

    private static func box(_ tap: MTAudioProcessingTap) -> Box {
        Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    private static func makeTap(state: EqualizerState) -> MTAudioProcessingTap? {
        let held = Unmanaged.passRetained(Box(state: state))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: held.toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in EqualizerTap.box(tap).prepare(format.pointee) },
            unprepare: { tap in EqualizerTap.box(tap).usable = false },
            process: { tap, frames, _, list, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, nil, framesOut) == noErr else { return }
                EqualizerTap.box(tap).process(list, frames: framesOut.pointee)
            }
        )
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            // The tap never took the box, so it is ours to let go of
            held.release()
            return nil
        }
        return tap.takeRetainedValue()
    }
}
