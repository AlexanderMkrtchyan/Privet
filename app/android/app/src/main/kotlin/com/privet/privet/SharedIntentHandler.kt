package com.privet.privet

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.FileOutputStream

/**
 * Inbound Android share-sheet intents (ACTION_SEND / ACTION_SEND_MULTIPLE).
 *
 * When the user picks Privet from another app's share sheet, [onIntent]
 * extracts the payload — shared text/subject and/or content URIs — and copies
 * any streamed files into our own cache, because content:// URIs from other
 * apps are only readable for the lifetime of the granting process and cannot
 * be opened later by the upload pipeline. Flutter polls [takePending] once the
 * engine is up (on mobile session start and app resume) and routes the payload
 * through the "Send to…" picker.
 */
object SharedIntentHandler {
    private val pending = mutableListOf<Map<String, Any?>>()
    private var fileCounter = 0

    @Synchronized
    fun onIntent(context: Context, intent: Intent) {
        val payload = parse(context, intent) ?: return
        pending += payload
    }

    @Synchronized
    fun takePending(): List<Map<String, Any?>> {
        val out = pending.toList()
        pending.clear()
        return out
    }

    @Suppress("DEPRECATION")
    private fun parse(context: Context, intent: Intent): Map<String, Any?>? {
        val action = intent.action
        val isSend = action == Intent.ACTION_SEND
        val isMultiple = action == Intent.ACTION_SEND_MULTIPLE
        if (!isSend && !isMultiple) return null

        val uris = mutableListOf<Uri>()
        if (isSend) {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris += it }
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let {
                uris += it
            }
        }
        // Some apps put the stream in ClipData instead of the stream extra.
        if (uris.isEmpty()) {
            intent.clipData?.let { clip ->
                for (i in 0 until clip.itemCount) {
                    clip.getItemAt(i).uri?.let { uris += it }
                }
            }
        }

        val files = mutableListOf<Map<String, String>>()
        for (uri in uris) {
            copyToCache(context, uri)?.let { files += it }
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            ?.trim()
            ?.takeUnless { it.isEmpty() }
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
            ?.trim()
            ?.takeUnless { it.isEmpty() }
        if (files.isEmpty() && text == null) return null

        return buildMap {
            if (text != null) put("text", text)
            if (subject != null) put("subject", subject)
            if (files.isNotEmpty()) put("files", files)
        }
    }

    /**
     * Copies a share content URI into our cache so the upload pipeline can
     * read it later. Returns {path, mimeType, fileName} or null on failure.
     */
    private fun copyToCache(context: Context, uri: Uri): Map<String, String>? {
        return try {
            val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
            val name = queryDisplayName(context, uri) ?: defaultNameFor(mime)
            val dir = File(context.cacheDir, "shared_intents").apply {
                mkdirs()
                // Opportunistic cleanup: shared files are transient.
                listFiles()?.forEach { stale ->
                    if (stale.isFile && stale.lastModified() < System.currentTimeMillis() - 24 * 3600_000L) {
                        stale.delete()
                    }
                }
            }
            val outFile = File(dir, "${System.currentTimeMillis()}-${++fileCounter}-${sanitize(name)}")
            val copied = context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output -> input.copyTo(output) }
                true
            } ?: false
            if (!copied || outFile.length() == 0L) {
                outFile.delete()
                return null
            }
            mapOf("path" to outFile.absolutePath, "mimeType" to mime, "fileName" to name)
        } catch (_: Exception) {
            null
        }
    }

    private fun queryDisplayName(context: Context, uri: Uri): String? {
        return try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) {
                    cursor.getString(idx)
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            uri.lastPathSegment?.substringAfterLast('/')
        }
    }

    private fun defaultNameFor(mime: String): String {
        val ext = when {
            mime == "image/jpeg" -> "jpg"
            mime == "image/png" -> "png"
            mime == "image/gif" -> "gif"
            mime == "image/webp" -> "webp"
            mime == "video/mp4" -> "mp4"
            mime == "video/webm" -> "webm"
            mime == "video/quicktime" -> "mov"
            mime == "audio/mpeg" -> "mp3"
            mime == "audio/wav" -> "wav"
            mime == "application/pdf" -> "pdf"
            mime.startsWith("image/") -> "img"
            mime.startsWith("video/") -> "vid"
            mime.startsWith("audio/") -> "audio"
            else -> "file"
        }
        return "shared.$ext"
    }

    /** Keeps attacker-supplied display names out of the cache path. */
    private fun sanitize(name: String): String {
        val cleaned = name.replace(Regex("[^A-Za-z0-9._\\-]"), "_")
        return cleaned.ifBlank { "file" }
    }
}
