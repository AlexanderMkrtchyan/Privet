package com.privet.privet

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.firebase.messaging.RemoteMessage

/**
 * Same C2DM broadcast Flutter's messaging plugin listens to. When the phone
 * is unlocked and Privet is not the visible app, that plugin treats the
 * process as foreground and never posts a banner. Show it here.
 */
class MessagePushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        MessageNotifier.ensureChannel(context)
        val extras = intent.extras ?: return
        val message = try {
            RemoteMessage(extras)
        } catch (_: Exception) {
            return
        }
        MessageNotifier.showIfSwallowed(context, message)
    }
}
