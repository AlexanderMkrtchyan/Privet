package com.privet.privet

import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings

/**
 * Legacy hook kept so older APKs can still be told to stop.
 *
 * We no longer run a persistent foreground "Online" notification — FCM
 * delivers messages and calls while backgrounded. [stop] cancels any leftover
 * service from a previous install.
 */
class RealtimeConnectionService : Service() {
    companion object {
        fun start(context: Context) {
            // No-op: persistent online notification removed by product choice.
            stop(context)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RealtimeConnectionService::class.java))
        }

        fun requestIgnoreBatteryOptimizations(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
            val pm = context.getSystemService(POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(context.packageName)) return true
            return try {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:${context.packageName}")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
                false
            } catch (_: Exception) {
                false
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf()
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
