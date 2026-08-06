package com.privet.privet

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import java.util.concurrent.ConcurrentHashMap

/**
 * Posts the incoming-call notification that drives the Teams-style ring:
 * a full-screen intent into [IncomingCallActivity] when the device is locked
 * (or the screen is off), and a persistent call heads-up notification with
 * Answer / Decline actions when the device is unlocked and in use.
 *
 * The notification id/tag scheme matches the Dart side
 * (`tag.hashCode & 0x7fffffff`, tag `call:<callId>`), so existing
 * `cancelMobileNotification` / `cancelNotificationsByTag` call-sites keep
 * working against notifications posted here.
 */
object IncomingCallNotifier {
    private const val CHANNEL_ID = "privet_calls"
    // Distinct from the FCM/Flutter "call:" tag so the background handler's
    // cancel-by-tag (`cancelMobileNotificationsByTag('call:$callId')`) never
    // removes the native ring.
    private const val TAG_PREFIX = "privet_call:"

    /** callId -> true while a native ring is being shown. Used for dedup. */
    private val activeCallIds = ConcurrentHashMap<String, Boolean>()

    fun notificationId(callId: String): Int = callId.hashCode() and 0x7fffffff

    fun show(context: Context, data: Map<String, Any?>) {
        val callId = data["callId"]?.toString() ?: return
        val tag = TAG_PREFIX + callId
        val id = notificationId(callId)

        ensureChannel(context)

        val payload = IncomingCallData(data)
        val callIntent = Intent(context, IncomingCallActivity::class.java)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .apply { CallPayload.putExtra(this, data) }

        val fullScreen = PendingIntent.getActivity(
            context,
            id,
            callIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val content = PendingIntent.getActivity(
            context,
            id + 1,
            context.packageManager.getLaunchIntentForPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val answer = PendingIntent.getBroadcast(
            context,
            id + 2,
            CallActionReceiver.intent(context, data, "answer"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val decline = PendingIntent.getBroadcast(
            context,
            id + 3,
            CallActionReceiver.intent(context, data, "decline"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val callerName =
            payload.callerDisplayName.ifBlank { payload.callerHandle.ifBlank { "Incoming call" } }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_privet)
            .setContentTitle(callerName)
            .setContentText(payload.modeLabel)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(fullScreen, true)
            .setContentIntent(content)
            .addAction(
                NotificationCompat.Action.Builder(null, "Answer", answer).build(),
            )
            .addAction(
                NotificationCompat.Action.Builder(null, "Decline", decline).build(),
            )

        // Mirror the server's 60s ring timeout so a stale ring can never linger.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setTimeoutAfter(60_000L)
        }

        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(tag, id, builder.build())
        activeCallIds[callId] = true
    }

    fun cancel(context: Context, callId: String) {
        if (callId.isEmpty()) return
        activeCallIds.remove(callId)
        val tag = TAG_PREFIX + callId
        val id = notificationId(callId)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            for (n in manager.activeNotifications) {
                if (tag == n.tag) manager.cancel(n.tag, n.id)
            }
        } else {
            manager.cancel(tag, id)
        }
        IncomingCallActivity.dismiss()
    }

    fun isActive(callId: String): Boolean = activeCallIds[callId] == true

    /** Push `method` (acceptCall / declineCall) into the running Flutter engine.
     *  Returns true when the engine was available and the call was dispatched. */
    fun sendToFlutter(method: String, data: Map<String, Any?>): Boolean {
        val engine = FlutterEngineHolder.get() ?: return false
        io.flutter.plugin.common.MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "privet/incoming_call",
        ).invokeMethod(method, data)
        return true
    }

    /** Create the privet_calls channel. Idempotent — safe to call early and often. */
    fun ensureChannel(context: Context) {
        PrivetFCMService.Companion.ensureCallChannel(context)
    }
}

/**
 * Call payload that travels with every native ring (notification extras,
 * activity intent) so Accept / Decline can rebuild the ring on the Dart side.
 */
object CallPayload {
    const val KEY_CALL_ID = "callId"
    const val KEY_CONVERSATION_ID = "conversationId"
    const val KEY_MODE = "mode"
    const val KEY_FROM_USER_ID = "fromUserId"
    const val KEY_CALLER_DISPLAY_NAME = "callerDisplayName"
    const val KEY_CALLER_HANDLE = "callerHandle"
    const val KEY_CALLER_AVATAR_HUE = "callerAvatarHue"

    val keys = listOf(
        KEY_CALL_ID,
        KEY_CONVERSATION_ID,
        KEY_MODE,
        KEY_FROM_USER_ID,
        KEY_CALLER_DISPLAY_NAME,
        KEY_CALLER_HANDLE,
        KEY_CALLER_AVATAR_HUE,
    )

    fun putExtra(intent: Intent, data: Map<String, Any?>) {
        for (k in keys) {
            val v = data[k]?.toString()
            if (!v.isNullOrEmpty()) intent.putExtra(k, v)
        }
    }

    fun readExtra(intent: Intent): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        for (k in keys) {
            intent.getStringExtra(k)?.let { out[k] = it }
        }
        return out
    }
}

/** Wraps the payload map with typed convenience getters. */
class IncomingCallData(data: Map<String, Any?>) {
    val callId: String = data["callId"]?.toString() ?: ""
    val conversationId: String = data["conversationId"]?.toString() ?: ""
    val mode: String = data["mode"]?.toString() ?: "video"
    val fromUserId: String = data["fromUserId"]?.toString() ?: ""
    val callerDisplayName: String = data["callerDisplayName"]?.toString() ?: ""
    val callerHandle: String = data["callerHandle"]?.toString() ?: ""
    val callerAvatarHue: Int =
        data["callerAvatarHue"]?.toString()?.toIntOrNull() ?: 160

    val modeLabel: String = when (mode) {
        "audio" -> "Incoming audio call"
        "screen" -> "Incoming screen share"
        "control" -> "Incoming remote control"
        else -> "Incoming call"
    }
}
