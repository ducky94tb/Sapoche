package app.sapoche

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import app.sapoche.core.EqFilter
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/**
 * The equalizer in the sound's way: runs before the speed and the volume of the player, so those stay as they are. It is
 * always active for a sound it can read (16 bit or float), because the sink picks its processors when a song is set up
 * and the person may turn the equalizer on in the middle of one; with every band at 0 it only copies the bytes.
 * [gains] is read at each buffer, so a change takes hold at the next one (a few tens of milliseconds).
 */
@UnstableApi
class EqualizerProcessor(private val gains: () -> IntArray) : BaseAudioProcessor() {
    private val filter = EqFilter()
    private var samples = FloatArray(0)
    private var channels = 0
    private var bytesPerSample = 2

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        val readable = inputAudioFormat.encoding == C.ENCODING_PCM_16BIT || inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT
        if (!readable || inputAudioFormat.channelCount < 1 || inputAudioFormat.sampleRate < 1) {
            EventLog.d("eq", "not applied to $inputAudioFormat")
            return AudioFormat.NOT_SET
        }
        channels = inputAudioFormat.channelCount
        bytesPerSample = if (inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT) 4 else 2
        filter.setGains(gains())
        filter.configure(inputAudioFormat.sampleRate, channels)
        EventLog.d("eq", "ready for ${inputAudioFormat.sampleRate} Hz, $channels channels, ${bytesPerSample * 8} bit")
        return inputAudioFormat
    }

    override fun onFlush() {
        // A new song or a seek: what the filters remember of the sound before is of no use
        filter.setGains(gains())
        filter.configure(inputAudioFormat.sampleRate, channels)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val size = inputBuffer.remaining()
        if (size == 0) return
        filter.setGains(gains())
        val out = replaceOutputBuffer(size)
        if (filter.isFlat) {
            out.put(inputBuffer)
            out.flip()
            return
        }
        val frameSize = channels * bytesPerSample
        val frames = size / frameSize
        val count = frames * channels
        if (samples.size < count) samples = FloatArray(count)
        val float = bytesPerSample == 4
        for (i in 0 until count) samples[i] = if (float) inputBuffer.getFloat() else inputBuffer.getShort() / 32768f
        filter.process(samples, frames)
        for (i in 0 until count) {
            if (float) out.putFloat(samples[i]) else out.putShort((samples[i] * 32768f).roundToInt().coerceIn(-32768, 32767).toShort())
        }
        // Bytes that do not make a whole frame go through as they are
        out.put(inputBuffer)
        out.flip()
    }
}
