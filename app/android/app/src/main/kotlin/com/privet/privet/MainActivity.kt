package com.privet.privet

import android.Manifest
import android.app.DownloadManager
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private var pendingStorageResult: MethodChannel.Result? = null
    // Legacy (API < 29) public-Downloads write waiting for a permission answer.
    private var pendingDownloadSave: (() -> Unit)? = null
    private var pendingDownloadResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Before Flutter creates privet_messages: bump a FCM-default channel
        // up to HIGH so unlocked phones get a heads-up, not only a shade entry.
        MessageNotifier.ensureChannel(this)
        // A cold start from another app's share sheet delivers the payload in
        // onCreate; parse it before the engine builds so Flutter can poll.
        SharedIntentHandler.onIntent(this, intent)
        super.onCreate(savedInstanceState)
    }

    override fun onStart() {
        super.onStart()
        startedActivities++
    }

    override fun onStop() {
        startedActivities = (startedActivities - 1).coerceAtLeast(0)
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        SharedIntentHandler.onIntent(this, intent)
    }

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
                "bringToFront" -> {
                    bringMainActivityToFront()
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/shared_intent",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> result.success(SharedIntentHandler.takePending())
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/storage",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestReadMedia" -> requestReadMedia(result)
                else -> result.notImplemented()
            }
        }
        // Saving chat media: Android has no writable "Downloads" path in the
        // app sandbox, so files must go through MediaStore (API 29+) or the
        // public Downloads folder (legacy). Dart downloads to a temp file and
        // hands the path here; the returned path is what the toast shows.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "privet/downloads",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("filename") ?: "download"
                    val mime = call.argument<String>("mimeType")
                        ?: "application/octet-stream"
                    if (path.isNullOrEmpty()) {
                        result.success(null)
                    } else {
                        saveToDownloads(File(path), name, mime, result)
                    }
                }
                "reveal" -> {
                    val path = call.argument<String>("path")
                    result.success(revealDownload(path))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == STORAGE_PERMISSION_REQUEST) {
            pendingStorageResult?.success(
                grantResults.any { it == PackageManager.PERMISSION_GRANTED },
            )
            pendingStorageResult = null
        }
        if (requestCode == DOWNLOAD_PERMISSION_REQUEST) {
            val pending = pendingDownloadSave
            pendingDownloadSave = null
            pendingDownloadResult = null
            // The closure re-checks the permission itself, so denial falls back
            // to the app-specific folder instead of failing the download.
            pending?.invoke()
        }
    }

    /**
     * Copies [src] into the phone's public Downloads folder.
     *
     * Android 10+ uses MediaStore.Downloads (no permission, indexed by the
     * Files app / Downloads UI). API 24–28 writes the public directory
     * directly, which needs WRITE_EXTERNAL_STORAGE; when the user denies it we
     * fall back to the app-specific external folder instead of failing.
     * Returns the saved absolute path, or null on failure.
     */
    private fun saveToDownloads(
        src: File,
        displayName: String,
        mimeType: String,
        result: MethodChannel.Result,
    ) {
        if (!src.exists() || src.length() == 0L) {
            result.success(null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val permission = Manifest.permission.WRITE_EXTERNAL_STORAGE
            if (ContextCompat.checkSelfPermission(this, permission) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                legacySave(src, displayName, mimeType, result, publicDir = true)
            } else {
                // A newer download supersedes the one still waiting for the
                // permission dialog; fail it instead of leaving Dart hanging.
                pendingDownloadResult?.success(null)
                pendingDownloadResult = result
                pendingDownloadSave = {
                    val grantedNow = ContextCompat.checkSelfPermission(
                        this,
                        permission,
                    ) == PackageManager.PERMISSION_GRANTED
                    legacySave(
                        src,
                        displayName,
                        mimeType,
                        result,
                        publicDir = grantedNow,
                    )
                }
                requestPermissions(
                    arrayOf(permission),
                    DOWNLOAD_PERMISSION_REQUEST,
                )
            }
            return
        }
        Thread {
            var created: Uri? = null
            try {
                val resolver = contentResolver
                val finalName = uniqueMediaStoreName(resolver, displayName)
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, finalName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS,
                    )
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val target = resolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: throw IOException("MediaStore insert failed")
                created = target
                resolver.openOutputStream(target)?.use { out ->
                    src.inputStream().use { input -> input.copyTo(out, 64 * 1024) }
                } ?: throw IOException("MediaStore openOutputStream failed")
                val done = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(target, done, null, null)
                postResult(result, publicDownloadsPath(finalName))
            } catch (_: Exception) {
                created?.let { runCatching { contentResolver.delete(it, null, null) } }
                postResult(result, null)
            }
        }.start()
    }

    /** API < 29: plain file write into Download/ (or the app dir on denial). */
    private fun legacySave(
        src: File,
        displayName: String,
        mimeType: String,
        result: MethodChannel.Result,
        publicDir: Boolean,
    ) {
        Thread {
            try {
                val dir = if (publicDir) {
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS,
                    )
                } else {
                    getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
                }
                if (!dir.exists()) dir.mkdirs()
                val target = File(dir, uniqueFileName(dir, displayName))
                src.inputStream().use { input ->
                    target.outputStream().use { output ->
                        input.copyTo(output, 64 * 1024)
                    }
                }
                if (publicDir) {
                    MediaScannerConnection.scanFile(
                        this,
                        arrayOf(target.absolutePath),
                        arrayOf(mimeType),
                        null,
                    )
                }
                postResult(result, target.absolutePath)
            } catch (_: Exception) {
                postResult(result, null)
            }
        }.start()
    }

    /** Opens the saved file with its viewer, else the system Downloads UI. */
    private fun revealDownload(path: String?): Boolean {
        if (!path.isNullOrEmpty() && path.contains("/Android/data/")) {
            // Legacy fallback location (app-specific external storage): expose
            // it through our FileProvider so the viewer can read it.
            try {
                val file = File(path)
                if (file.exists()) {
                    val uri = FileProvider.getUriForFile(
                        this,
                        "$packageName.fileprovider",
                        file,
                    )
                    val ext = file.extension
                    val mime = android.webkit.MimeTypeMap.getSingleton()
                        .getMimeTypeFromExtension(ext) ?: "*/*"
                    val view = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mime)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    if (startActivityIfAvailable(view)) return true
                }
            } catch (_: Exception) {
                // Fall through to the Downloads UI.
            }
        }
        if (!path.isNullOrEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val name = File(path).name
                contentResolver.query(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    arrayOf(
                        MediaStore.Downloads._ID,
                        MediaStore.Downloads.MIME_TYPE,
                    ),
                    "${MediaStore.Downloads.DISPLAY_NAME}=?",
                    arrayOf(name),
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val id = cursor.getLong(0)
                        val mime = cursor.getString(1) ?: "*/*"
                        val uri = ContentUris.withAppendedId(
                            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                            id,
                        )
                        val view = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        if (startActivityIfAvailable(view)) return true
                    }
                }
            } catch (_: Exception) {
                // Fall through to the Downloads UI below.
            }
        }
        return startActivityIfAvailable(
            Intent(DownloadManager.ACTION_VIEW_DOWNLOADS),
        )
    }

    private fun startActivityIfAvailable(intent: Intent): Boolean {
        return try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    /** MediaStore allows duplicate names — make "photo (1).jpg" instead. */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun uniqueMediaStoreName(
        resolver: ContentResolver,
        name: String,
    ): String {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var candidate = name
        var index = 1
        while (index < 1000) {
            val exists = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.DISPLAY_NAME}=? AND " +
                    "${MediaStore.Downloads.RELATIVE_PATH} LIKE ?",
                arrayOf(candidate, "${Environment.DIRECTORY_DOWNLOADS}%"),
                null,
            )?.use { it.moveToFirst() } ?: false
            if (!exists) return candidate
            candidate = "$base ($index)$ext"
            index++
        }
        return candidate
    }

    private fun uniqueFileName(dir: File, name: String): String {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var candidate = name
        var index = 1
        while (File(dir, candidate).exists() && index < 1000) {
            candidate = "$base ($index)$ext"
            index++
        }
        return candidate
    }

    private fun publicDownloadsPath(name: String): String {
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        return File(dir, name).absolutePath
    }

    private fun postResult(result: MethodChannel.Result, value: Any?) {
        runOnUiThread { result.success(value) }
    }

    private fun requestReadMedia(result: MethodChannel.Result) {
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_AUDIO,
            )
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        val missing = perms.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        pendingStorageResult?.success(false)
        pendingStorageResult = result
        requestPermissions(missing.toTypedArray(), STORAGE_PERMISSION_REQUEST)
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
     * Raises this activity over whatever is currently on screen (YouTube,
     * launcher, etc.) after a notification tap. Uses reorder-to-front so we
     * don't spawn a duplicate task.
     */
    private fun bringMainActivityToFront() {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        startActivity(intent)
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

    companion object {
        private const val STORAGE_PERMISSION_REQUEST = 4721
        private const val DOWNLOAD_PERMISSION_REQUEST = 4722

        @Volatile
        private var startedActivities = 0

        /** True while a Privet activity is visible (not merely process-alive). */
        val isInForeground: Boolean get() = startedActivities > 0
    }
}
