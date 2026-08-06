package com.privet.privet

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView
import org.json.JSONObject

/**
 * Teams-style full-screen incoming-call UI. Launched by the incoming-call
 * notification's full-screen intent (device locked / screen off) and shown
 * over the lock screen via `showWhenLocked` + `turnScreenOn`.
 *
 * Rings with the default phone ringtone and vibrates until the user answers,
 * declines, the call ends, or the server-side 60s ring timeout fires. Accept
 * and Decline are pushed into the running Flutter engine over the
 * `privet/incoming_call` method channel so WebRTC/WS signaling happens in Dart.
 */
class IncomingCallActivity : Activity() {
    companion object {
        private const val RING_TIMEOUT_MS = 60_000L
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PENDING_CALL_ACTION = "flutter.pending_call_action"

        @Volatile
        private var current: IncomingCallActivity? = null

        fun intent(context: Context, data: Map<String, Any?>, action: String? = null): Intent =
            Intent(context, IncomingCallActivity::class.java)
                .putExtra("privet_action", action)
                .apply { CallPayload.putExtra(this, data) }

        /** Close the ring screen (call answered/ended elsewhere). */
        fun dismiss() {
            current?.let { activity ->
                activity.runOnUiThread {
                    if (!activity.isFinishing) activity.finishAndRemoveTask()
                }
            }
        }

        /**
         * Read a pending call action stored by a previous accept/decline on
         * the ring screen when the Flutter engine was not yet running. The
         * Dart side calls [clearPendingCallAction] after processing it.
         * Returns null when there is no pending action.
         */
        fun readPendingCallAction(context: Context): Map<String, Any?>? {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(PENDING_CALL_ACTION, null) ?: return null
            return try {
                val json = JSONObject(raw)
                val map = HashMap<String, Any?>()
                for (key in json.keys()) map[key] = json.get(key)
                map
            } catch (_: Exception) {
                null
            }
        }

        /** Remove the pending call action from SharedPreferences. */
        fun clearPendingCallAction(context: Context) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .remove(PENDING_CALL_ACTION)
                .apply()
        }

        private fun storePendingCallAction(context: Context, action: String, data: Map<String, Any?>) {
            val json = JSONObject()
            json.put("action", action)
            for (key in CallPayload.keys) {
                val v = data[key]?.toString()
                if (!v.isNullOrEmpty()) json.put(key, v)
            }
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(PENDING_CALL_ACTION, json.toString())
                .apply()
        }
    }

    private var ringtone: Ringtone? = null
    private var mediaPlayer: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var vibrator: Vibrator? = null
    private val handler = Handler(Looper.getMainLooper())
    private var currentData: Map<String, Any?> = emptyMap()

    private val ringTimeout = Runnable {
        stopRing()
        if (!isFinishing) finishAndRemoveTask()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = this
        // Teams-style keyguard bypass. Mirrors the manifest showWhenLocked /
        // turnScreenOn attributes, kept at runtime so the behavior can't be
        // lost to theme/flag resets.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.incoming_call)

        dismissKeyguard()

        findViewById<ImageButton>(R.id.btn_accept).setOnClickListener {
            acceptCall(currentData)
        }
        findViewById<ImageButton>(R.id.btn_decline).setOnClickListener {
            declineCall(currentData)
        }

        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        val data = CallPayload.readExtra(intent)
        currentData = data
        val payload = IncomingCallData(data)
        val name = payload.callerDisplayName.ifBlank {
            payload.callerHandle.ifBlank { "Incoming call" }
        }

        findViewById<TextView>(R.id.caller_name).text = name
        findViewById<TextView>(R.id.mode_label).text = payload.modeLabel

        val initial = findViewById<TextView>(R.id.avatar_initial)
        initial.text = name.trim().take(1).ifBlank { "?" }.uppercase()

        // Avatar circle tinted by the caller's hue, matching the web palette.
        val hue = ((payload.callerAvatarHue % 360) + 360) % 360
        findViewById<View>(R.id.avatar_container).background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.HSVToColor(floatArrayOf(hue.toFloat(), 0.45f, 0.82f)))
        }

        handler.removeCallbacks(ringTimeout)
        stopRing()
        startRinging()
        startVibration()
        acquireWakeLock()
        handler.postDelayed(ringTimeout, RING_TIMEOUT_MS)
    }

    @Suppress("DEPRECATION")
    private fun dismissKeyguard() {
        // requestDismissKeyguard is API 26+; API 34+ shows a full-screen call
        // intent over the keyguard itself, so the explicit request is only
        // needed in between.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager ?: return
        try {
            km.requestDismissKeyguard(this, null)
        } catch (_: Exception) {
            // Best-effort: showWhenLocked still draws the ring over the keyguard.
        }
    }

    private fun acceptCall(data: Map<String, Any?>) {
        val callId = IncomingCallData(data).callId
        stopRing()
        IncomingCallNotifier.cancel(this, callId)

        // If Flutter is already running, push the accept over the method
        // channel so WebRTC signaling starts immediately.
        val engineAlive = IncomingCallNotifier.sendToFlutter("acceptCall", data)
        if (!engineAlive) {
            // App was killed — store the pending accept so Flutter can
            // auto-accept on the next cold start.
            storePendingCallAction(this, "accept", data)
        }

        // Bring the Flutter app (with the now-active call) to the front.
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(launch)
        }
        finishAndRemoveTask()
    }

    private fun declineCall(data: Map<String, Any?>) {
        val callId = IncomingCallData(data).callId
        stopRing()
        IncomingCallNotifier.cancel(this, callId)

        val engineAlive = IncomingCallNotifier.sendToFlutter("declineCall", data)
        if (!engineAlive) {
            // Store pending decline so Flutter can send the decline signal
            // over the WebSocket on next startup, or at least clean up.
            storePendingCallAction(this, "decline", data)
        }

        finishAndRemoveTask()
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        // Keep ringing.
    }

    override fun onDestroy() {
        handler.removeCallbacks(ringTimeout)
        current = null
        stopRing()
        releaseWakeLock()
        super.onDestroy()
    }

    private fun stopRing() {
        ringtone?.stop()
        ringtone = null
        mediaPlayer?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        mediaPlayer = null
        vibrator?.cancel()
    }

    private fun startRinging() {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val r = RingtoneManager.getRingtone(this, uri)
                r.isLooping = true
                r.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                r.play()
                ringtone = r
            } else {
                val p = MediaPlayer().apply {
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    setDataSource(this@IncomingCallActivity, uri)
                    isLooping = true
                    prepare()
                    start()
                }
                mediaPlayer = p
            }
        } catch (_: Exception) {
            // Never crash the ring over a missing ringtone.
        }
    }

    private fun startVibration() {
        vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        try {
            val pattern = longArrayOf(0, 900, 900)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator!!.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator!!.vibrate(pattern, 0)
            }
        } catch (_: Exception) {
        }
    }

    private fun acquireWakeLock() {
        releaseWakeLock()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "privet:incoming_call").apply {
            setReferenceCounted(false)
            acquire(RING_TIMEOUT_MS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }
}
