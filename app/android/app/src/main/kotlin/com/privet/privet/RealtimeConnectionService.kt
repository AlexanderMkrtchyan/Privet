package com.privet.privet

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings

/**
 * Keeps the Privet process alive while logged in so WebSocket calls/messages
 * arrive when the user switches to another app (YouTube, etc.).
 */
class RealtimeConnectionService : Service() {
    companion object {
        private const val CHANNEL_ID = "privet_realtime"
        private const val NOTIFICATION_ID = 2408

        fun start(context: Context) {
            val intent = Intent(context, RealtimeConnectionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
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

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Privet connection",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps Privet online for calls and messages"
                    setShowBadge(false)
                },
            )
        }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setContentTitle("Privet")
            .setContentText("Online — calls and messages will arrive")
            // Small icon must be a monochrome silhouette. The full-color
            // launcher icon renders as a white square (a "stop" button) here.
            .setSmallIcon(R.drawable.ic_stat_privet)
            .setLargeIcon(
                android.graphics.BitmapFactory.decodeResource(
                    resources,
                    R.drawable.ic_privet_logo,
                ),
            )
            .setContentIntent(pending)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null
}
