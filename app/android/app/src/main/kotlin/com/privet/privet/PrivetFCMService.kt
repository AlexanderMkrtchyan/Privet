package com.privet.privet

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.media.RingtoneManager
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Handles data-only FCM call pushes for ALL app states (foreground, background,
 * killed).  The server sends call pushes as data-only messages (no notification
 * block) with priority=HIGH so [onMessageReceived] always fires.
 *
 * On receipt this service:
 * 1. Posts a temporary foreground notification so the process isn't killed
 *    mid-flight (critical on HyperOS/MIUI).
 * 2. Creates the `privet_calls` notification channel (if not already done).
 * 3. Cancels any stale OS notification from an earlier FCM delivery.
 * 4. Posts the Teams-style full-screen ring via [IncomingCallNotifier].
 * 5. Removes the foreground notification and stops self.
 *
 * Non-call messages are ignored; the Dart background handler owns chat
 * display notifications.
 */
class PrivetFCMService : FirebaseMessagingService() {
    companion object {
        const val CHANNEL_CALLS = "privet_calls"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREFIX = "flutter.native_call_handled_"
        private const val FG_NOTIF_ID = 26401

        fun ensureCallChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_CALLS) != null) return
            val channel = NotificationChannel(
                CHANNEL_CALLS,
                "Calls",
                NotificationManager.IMPORTANCE_MAX,
            ).apply {
                description = "Incoming calls"
                setShowBadge(false)
                setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE), null)
                enableVibration(true)
            }
            manager.createNotificationChannel(channel)
        }
    }

    // Create the call channel as soon as this service is instantiated, before
    // any message is processed — the channel must exist whether we handle this
    // message via onMessageReceived or the Dart background handler does.
    override fun onCreate() {
        super.onCreate()
        ensureCallChannel(this)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data.isEmpty()) return

        val type = data["type"] ?: ""
        if (type != "call.incoming") return

        val callId = data["callId"] ?: ""
        if (callId.isEmpty()) return

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.getBoolean("$PREFIX$callId", false)) return

        // Start a temporary foreground service notification to keep this
        // process alive during the full-screen ring post.  HyperOS/MIUI
        // aggressively kills service processes that don't have a foreground
        // notification.
        startCallForeground()

        val callData = mapOf(
            "callId" to callId,
            "conversationId" to (data["conversationId"] ?: ""),
            "mode" to (data["mode"] ?: "audio"),
            "fromUserId" to (data["fromUserId"] ?: ""),
            "callerDisplayName" to (data["callerDisplayName"] ?: data["title"] ?: ""),
            "callerHandle" to (data["callerHandle"] ?: ""),
            "callerAvatarHue" to (data["callerAvatarHue"] ?: "160"),
        )

        IncomingCallNotifier.show(this, callData)
        prefs.edit().putBoolean("$PREFIX$callId", true).apply()

        stopCallForeground()
    }

    override fun onNewToken(token: String) {
        // Token refresh handled by Flutter layer via onTokenRefresh.
    }

    /** Post a minimal foreground notification to keep this process alive. */
    private fun startCallForeground() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val ch = NotificationChannel(
            "privet_fcm_fg",
            "Service",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        nm.createNotificationChannel(ch)
        val notif = android.app.Notification.Builder(this, "privet_fcm_fg")
            .setSmallIcon(R.drawable.ic_stat_privet)
            .setLargeIcon(
                android.graphics.BitmapFactory.decodeResource(
                    resources,
                    R.drawable.ic_privet_logo,
                ),
            )
            .setContentTitle("Privet")
            .setContentText("Incoming call…")
            .setOngoing(true)
            .build()
        startForeground(FG_NOTIF_ID, notif)
    }

    /** Remove the foreground notification and release the foreground state. */
    private fun stopCallForeground() {
        stopForeground(STOP_FOREGROUND_REMOVE)
    }
}
