package com.privet.privet

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.RemoteMessage
import java.util.concurrent.ConcurrentHashMap

/**
 * Chat heads-up notifications.
 *
 * The OS draws a lock-screen notification from the FCM `notification` block
 * while the phone is locked. While it is unlocked, two things hide that
 * banner: the message channel may have been created below HIGH (no pop-up,
 * only the shade), and Flutter's foreground check treats our own process as
 * foreground whenever the screen is on — so the system does not post a
 * banner and the paused Dart isolate never shows one either.
 *
 * [showIfSwallowed] posts the banner only in that unlocked-but-not-visible
 * case. Lock-screen delivery stays with the OS.
 */
object MessageNotifier {
    const val CHANNEL_ID = "privet_messages"
    private const val PREFS = "privet_message_channel"
    private const val KEY_BUMPED = "bumped_high_v1"
    private val shownIds = ConcurrentHashMap.newKeySet<String>()

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val existing = nm.getNotificationChannel(CHANNEL_ID)
        // Android ignores a later importance upgrade. FCM creates a missing
        // channel at DEFAULT, which never pops a banner while the screen is on.
        if (existing != null &&
            existing.importance < NotificationManager.IMPORTANCE_HIGH &&
            !prefs.getBoolean(KEY_BUMPED, false)
        ) {
            nm.deleteNotificationChannel(CHANNEL_ID)
        }
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "New chat messages"
                enableVibration(true)
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    null,
                )
            }
            nm.createNotificationChannel(channel)
        }
        prefs.edit().putBoolean(KEY_BUMPED, true).apply()
    }

    /**
     * Post a heads-up when the phone is unlocked, Privet is not on screen,
     * and the process still looks foreground — the case where neither the OS
     * nor Dart will show the message.
     */
    fun showIfSwallowed(context: Context, message: RemoteMessage) {
        val data = message.data
        if (data["type"] == "call.incoming") return
        if (!shouldShowWhileUnlocked(context)) return
        val key = message.messageId
            ?: data["messageId"]?.takeIf { it.isNotEmpty() }
            ?: "${data["conversationId"]}:${message.sentTime}"
        if (key.isEmpty() || key == ":0") return
        if (!shownIds.add(key)) return
        if (shownIds.size > 64) shownIds.clear()
        show(context, message)
    }

    private fun shouldShowWhileUnlocked(context: Context): Boolean {
        if (MainActivity.isInForeground) return false
        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (km?.isKeyguardLocked == true) return false
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return false
        val procs = am.runningAppProcesses ?: return false
        val pkg = context.packageName
        return procs.any {
            it.processName == pkg &&
                it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        }
    }

    private fun show(context: Context, message: RemoteMessage) {
        ensureChannel(context)
        val data = message.data
        val title = message.notification?.title
            ?: data["title"]?.takeIf { it.isNotEmpty() }
            ?: "Privet"
        val body = message.notification?.body
            ?: data["body"]?.takeIf { it.isNotEmpty() }
            ?: "New message"
        val conversationId = data["conversationId"] ?: ""
        val tag = if (conversationId.isNotEmpty()) "chat:$conversationId" else "chat:privet"
        val id = tag.hashCode() and 0x7fffffff
        val payload = encodePayload(data)

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launch.action = "SELECT_NOTIFICATION"
        launch.putExtra("notificationId", id)
        launch.putExtra("notificationTag", tag)
        launch.putExtra("payload", payload)
        launch.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
        )
        val content = PendingIntent.getActivity(
            context,
            id,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_privet)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(content)
            .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))

        try {
            builder.setLargeIcon(
                BitmapFactory.decodeResource(context.resources, R.drawable.ic_privet_logo),
            )
        } catch (_: Exception) {
        }

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // Drop a system-posted copy that used the raw conversation id as its tag.
        if (conversationId.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            for (active in nm.activeNotifications) {
                if (active.tag == conversationId) nm.cancel(active.tag, active.id)
            }
        }
        nm.notify(tag, id, builder.build())
    }

    private fun encodePayload(data: Map<String, String>): String {
        val parts = ArrayList<String>()
        fun add(key: String) {
            val value = data[key] ?: return
            if (value.isEmpty() || value.contains('|') || value.contains('=')) return
            parts.add("$key=$value")
        }
        val type = data["type"]?.takeIf { it.isNotEmpty() } ?: "message"
        parts.add("type=$type")
        add("conversationId")
        add("messageId")
        add("taskId")
        return parts.joinToString("|")
    }
}
