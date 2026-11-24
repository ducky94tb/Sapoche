package app.sapoche

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.Process
import java.util.Locale

/** The top of an exported log: what a reader would otherwise have to ask for. Nothing in it names the person. */
object LogInfo {
    fun lines(context: Context): List<String> {
        val power = context.getSystemService(PowerManager::class.java)
        val notices = runCatching { context.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled() }.getOrNull()
        return listOf(
            "app: ${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}",
            "platform: Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "device: ${Build.MANUFACTURER} ${Build.MODEL}",
            "abi: ${Build.SUPPORTED_ABIS.firstOrNull().orEmpty()} (${if (Process.is64Bit()) "64" else "32"}-bit process)",
            "locale: ${Locale.getDefault().toLanguageTag()}",
            "battery optimization: ${if (power?.isIgnoringBatteryOptimizations(context.packageName) == true) "off for the app" else "on"}",
            "notifications: ${when (notices) { true -> "allowed"; false -> "blocked"; null -> "unknown" }}",
        )
    }
}
