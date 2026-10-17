package com.teamtalk.messenger

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File

/**
 * 다른 앱의 "공유 → TangoTalk"(ACTION_SEND / ACTION_SEND_MULTIPLE)로 받은 글·파일을 앱이 읽을 수 있는 모양으로 바꾼다
 * (share_intake.dart). 파일은 content:// 주소라 앱이 나중에 못 열 수 있어서, 받자마자 이 앱의 캐시 폴더(cache/shared)에 복사해
 * 경로로 넘긴다(올리고 나면 앱이 지운다 — 남은 것은 다음 공유 때 하루 지난 것부터 정리).
 */
object ShareIntake {
    private const val MAX_FILES = 20

    fun isShare(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE

    /** 공유 인텐트 → `{ text, subject, files: [{ path, name, mimeType, size }] }`. 무거운 복사라 메인 스레드 밖에서 부른다. */
    fun read(context: Context, intent: Intent): Map<String, Any?> {
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            uris.addAll(streamList(intent))
        } else {
            streamOne(intent)?.let { uris.add(it) }
        }
        // 글만 공유했는데 클립데이터에만 주소가 든 앱도 있다.
        if (uris.isEmpty()) {
            val clip = intent.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
            }
        }
        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        pruneOld(dir)
        val files = mutableListOf<Map<String, Any?>>()
        for ((index, uri) in uris.take(MAX_FILES).withIndex()) {
            try {
                val name = displayName(context, uri) ?: "file_${index + 1}"
                val safe = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
                val target = File(dir, "${System.currentTimeMillis()}_${index}_$safe")
                context.contentResolver.openInputStream(uri)?.use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                } ?: continue
                files.add(
                    mapOf(
                        "path" to target.absolutePath,
                        "name" to name,
                        "mimeType" to context.contentResolver.getType(uri),
                        "size" to target.length(),
                    ),
                )
            } catch (_: Exception) {
                // 읽을 수 없는 파일(권한이 사라짐 등)은 빼고 나머지만.
            }
        }
        return mapOf("text" to text, "subject" to subject, "files" to files)
    }

    @Suppress("DEPRECATION")
    private fun streamOne(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }

    @Suppress("DEPRECATION")
    private fun streamList(intent: Intent): List<Uri> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        }

    private fun displayName(context: Context, uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    /** 하루 넘게 남은 복사본(올리지 않고 그만둔 공유)을 지운다. */
    private fun pruneOld(dir: File) {
        val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        dir.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
    }
}
