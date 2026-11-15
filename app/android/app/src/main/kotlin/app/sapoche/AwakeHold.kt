package app.sapoche

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Keeps the CPU and the Wi-Fi awake while this device waits for the next song to start. ExoPlayer holds both only while
 * it plays or buffers, so in the gap between the last song and the next one (asking for more songs, fetching the stream)
 * a phone with its screen off may go to sleep and leave the music at a stop. The hold always ends by itself after
 * [AWAKE_MAX_MS]: it is never kept for good. Used on the main thread.
 */
class AwakeHold(context: Context, private val scope: CoroutineScope) {
    private val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    private val cpu: PowerManager.WakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sapoche:autoplay").apply { setReferenceCounted(false) }

    @Suppress("DEPRECATION")
    private val wifi: WifiManager.WifiLock? = wifiManager
        ?.createWifiLock(if (Build.VERSION.SDK_INT < 29) WifiManager.WIFI_MODE_FULL_HIGH_PERF else WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "sapoche:autoplay")
        ?.apply { setReferenceCounted(false) }

    private var expiry: Job? = null

    /** Whether the locks are held now. */
    var held = false
        private set

    /** Takes the locks (or keeps them, and starts the count of [maxMs] over). [reason] is for the log. */
    fun hold(reason: String, maxMs: Long = AWAKE_MAX_MS) {
        try {
            // The timeout is the backstop if the job below never runs
            cpu.acquire(maxMs + BACKSTOP_MS)
            wifi?.acquire()
        } catch (e: RuntimeException) {
            EventLog.d("awake", "could not hold the device awake for $reason: ${e.javaClass.simpleName}: ${e.message}")
            return
        }
        if (!held) EventLog.d("awake", "holding the device awake for $reason, at most ${maxMs / 1000} s")
        held = true
        expiry?.cancel()
        expiry = scope.launch {
            delay(maxMs)
            release("it ran out after ${maxMs / 1000} s (held for $reason)")
        }
    }

    /** Lets the locks go. Does nothing when they are not held. */
    fun release(reason: String) {
        expiry?.cancel()
        expiry = null
        if (!held) return
        held = false
        try {
            if (cpu.isHeld) cpu.release()
            if (wifi?.isHeld == true) wifi.release()
        } catch (e: RuntimeException) {
            EventLog.d("awake", "could not let the device sleep: ${e.javaClass.simpleName}: ${e.message}")
        }
        EventLog.d("awake", "no longer holding the device awake: $reason")
    }

    companion object {
        /** The longest one hold lasts, in milliseconds. */
        const val AWAKE_MAX_MS = 120_000L
        private const val BACKSTOP_MS = 5_000L
    }
}
