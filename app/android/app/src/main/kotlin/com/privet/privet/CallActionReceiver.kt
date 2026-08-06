package com.privet.privet

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles the Answer / Decline actions on the incoming-call notification
 * (shown as a heads-up when the device is unlocked and in use). Answering
 * accepts in the running Flutter engine and brings the app to the front;
 * declining rejects over the existing WebSocket.
 */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra("privet_action") ?: return
        val data = CallPayload.readExtra(intent)
        if (data.isEmpty()) return

        when (action) {
            "answer" -> {
                IncomingCallNotifier.sendToFlutter("acceptCall", data)
                val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                if (launch != null) {
                    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(launch)
                }
            }
            "decline" -> {
                IncomingCallNotifier.sendToFlutter("declineCall", data)
            }
        }
        IncomingCallNotifier.cancel(context, IncomingCallData(data).callId)
    }

    companion object {
        fun intent(context: Context, data: Map<String, Any?>, action: String): Intent =
            Intent(context, CallActionReceiver::class.java)
                .putExtra("privet_action", action)
                .apply { CallPayload.putExtra(this, data) }
    }
}
