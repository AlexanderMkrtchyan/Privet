package com.privet.privet

import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineHolder.attach(flutterEngine)

        // Create the privet_calls notification channel early so the auto-
        // displayed FCM notification (when the app is killed with a
        // notification-block message) uses a channel that already exists
        // with IMPORTANCE_MAX (ringtone + vibration).
        IncomingCallNotifier.ensureChannel(this)
        // Native incoming-call ring screen posts its notification here and
        // pushes Accept/Decline back into Dart over the same channel.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/incoming_call",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "showIncomingCall" -> {
                    val data = (call.arguments as? Map<*, *>)
                        ?.entries
                        ?.associate { (k, v) -> k.toString() to v }
                        ?: emptyMap()
                    IncomingCallNotifier.show(this, data)
                    result.success(null)
                }
                "cancelIncomingCall" -> {
                    val args = call.arguments as? Map<*, *>
                    IncomingCallNotifier.cancel(this, args?.get("callId")?.toString() ?: "")
                    result.success(null)
                }
                "readPendingCallAction" -> {
                    val action = IncomingCallActivity.Companion.readPendingCallAction(this)
                    result.success(action)
                }
                "clearPendingCallAction" -> {
                    IncomingCallActivity.Companion.clearPendingCallAction(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/screen_capture",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ScreenCaptureService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    ScreenCaptureService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/realtime",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    RealtimeConnectionService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    RealtimeConnectionService.stop(this)
                    result.success(null)
                }
                "requestBatteryExemption" -> {
                    val ok = RealtimeConnectionService.requestIgnoreBatteryOptimizations(this)
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/notifications",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestFullScreenIntent" -> {
                    result.success(requestFullScreenIntent(this))
                }
                "notificationsEnabled" -> {
                    result.success(notificationsEnabled(this))
                }
                "openNotificationSettings" -> {
                    result.success(openNotificationSettings(this))
                }
                "cancelNotificationsByTag" -> {
                    val tag = call.argument<String>("tag") ?: ""
                    cancelNotificationsByTag(this, tag)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/remote_input",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> result.success(
                    mapOf("canInject" to false, "platform" to "android")
                )
                "ensureReady" -> result.success(null)
                "getClipboardText" -> {
                    result.success(
                        clipboardManager.primaryClip
                            ?.takeIf { it.itemCount > 0 }
                            ?.getItemAt(0)
                            ?.coerceToText(this)
                    )
                }
                "getClipboardImagePng" -> result.success(clipboardImageBytes())
                "setClipboardImage" -> {
                    val bytes = call.argument<ByteArray>("png")
                    result.success(if (bytes != null) setClipboardImage(bytes) else false)
                }
                "setClipboardText" -> {
                    val text = call.argument<String>("text")
                    if (!text.isNullOrEmpty()) {
                        clipboardManager.setPrimaryClip(ClipData.newPlainText("Privet", text))
                    }
                    result.success(null)
                }
                "setInputLock" -> result.success(false)
                else -> result.notImplemented()
            }
        }
    }

    private val clipboardManager: ClipboardManager
        get() = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    /**
     * Writes [bytes] (any decodable image format) to a cache file exposed via
     * FileProvider, then puts that content URI on the system clipboard as an
     * image. Other apps (and this one) can paste it and resolve the image.
     * Returns true on success.
     */
    private fun setClipboardImage(bytes: ByteArray): Boolean {
        return try {
            val mime = sniffImageMime(bytes)
            val ext = when (mime) {
                "image/jpeg" -> "jpg"
                "image/gif" -> "gif"
                "image/webp" -> "webp"
                else -> "png"
            }
            val dir = File(cacheDir, "clipboard_images").apply { mkdirs() }
            val file = File(dir, "clipboard_image.$ext")
            file.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val clip = ClipData(
                "Privet image",
                arrayOf(mime),
                ClipData.Item(uri),
            )
            clipboardManager.setPrimaryClip(clip)
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Reads image bytes from the system clipboard. Only content-URI items whose
     * MIME type is image-like are considered (bitmap-only clips are not
     * shareable across processes). Returns null when the clipboard has no
     * image.
     */
    private fun clipboardImageBytes(): ByteArray? {
        val clip = clipboardManager.primaryClip ?: return null
        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            val mime = try {
                contentResolver.getType(uri)
            } catch (_: Exception) {
                null
            } ?: continue
            if (!mime.startsWith("image/")) continue
            val bytes = try {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            } catch (_: Exception) {
                null
            } ?: continue
            if (bytes.isNotEmpty()) return bytes
        }
        return null
    }

    private fun sniffImageMime(bytes: ByteArray): String {
        if (bytes.size >= 8 &&
            bytes[0] == 0x89.toByte() && bytes[1] == 'P'.code.toByte() &&
            bytes[2] == 'N'.code.toByte() && bytes[3] == 'G'.code.toByte()
        ) return "image/png"
        if (bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) {
            return "image/jpeg"
        }
        if (bytes.size >= 3 &&
            bytes[0] == 'G'.code.toByte() && bytes[1] == 'I'.code.toByte() &&
            bytes[2] == 'F'.code.toByte()
        ) return "image/gif"
        if (bytes.size >= 12 &&
            bytes[0] == 'R'.code.toByte() && bytes[1] == 'I'.code.toByte() &&
            bytes[2] == 'F'.code.toByte() && bytes[3] == 'F'.code.toByte() &&
            bytes[8] == 'W'.code.toByte() && bytes[9] == 'E'.code.toByte() &&
            bytes[10] == 'B'.code.toByte() && bytes[11] == 'P'.code.toByte()
        ) return "image/webp"
        return "image/png"
    }

    /**
     * Removes every visible notification whose tag matches (the FCM SDK posts
     * the display-message notification with the tag we set on the server, e.g.
     * "call:<callId>"). The Flutter full-screen Accept/Decline notification
     * then replaces it without leaving a duplicate in the shade.
     */
    private fun cancelNotificationsByTag(context: Context, tag: String) {
        if (tag.isEmpty()) return
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            for (n in manager.activeNotifications) {
                if (tag == n.tag) manager.cancel(n.tag, n.id)
            }
        } else {
            manager.cancel(tag, 0)
        }
    }

    /**
     * Whether the user has notifications enabled for this app at the OS level.
     * Pre-Android-N there is no per-app switch, so assume enabled.
     */
    private fun notificationsEnabled(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return true
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return manager.areNotificationsEnabled()
    }

    /**
     * Opens the per-app notification settings page (Android 8+). Returning
     * whether the user actually landed there is best-effort; callers treat a
     * false result as "could not show" and retry later.
     */
    private fun openNotificationSettings(context: Context): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Android 14+ gates full-screen call intents behind a user-granted switch
     * even when the manifest permission is declared. Ask once so incoming calls
     * can actually launch the Accept/Decline screen like WhatsApp.
     */
    private fun requestFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.canUseFullScreenIntent()) return true
        return try {
            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            false
        } catch (_: Exception) {
            false
        }
    }

    override fun onDestroy() {
        FlutterEngineHolder.clear()
        super.onDestroy()
    }
}
