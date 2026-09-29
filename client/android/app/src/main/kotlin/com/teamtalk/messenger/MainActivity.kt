package com.teamtalk.messenger

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /** 저장 권한 요청 창이 떠 있는 동안 기다리는 Dart 쪽 호출(응답은 onRequestPermissionsResult에서). */
    private var pendingPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 다운로드 파일을 공용 Download/TangoTalk에 바로 저장하기 위한 채널(download_storage.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tangotalk/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 공용 Download 경로는 기기·사용자(업무 프로필 등)마다 달라서 OS에 묻는다.
                    "downloadsDir" -> result.success(
                        @Suppress("DEPRECATION")
                        Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOWNLOADS,
                        ).absolutePath,
                    )
                    "requestWritePermission" -> requestWritePermission(result)
                    // "파일"/"다운로드" 앱에 바로 보이도록 미디어 목록에 올린다.
                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 안드로이드 10 이하에서만 저장 권한(WRITE_EXTERNAL_STORAGE)이 필요하다 — 11부터는 앱이
     * 권한 없이도 Download에 자기 파일을 만들 수 있어서 바로 true.
     */
    private fun requestWritePermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQUEST_WRITE_STORAGE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_WRITE_STORAGE) return
        pendingPermission?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pendingPermission = null
    }

    companion object {
        private const val REQUEST_WRITE_STORAGE = 7301
    }
}
