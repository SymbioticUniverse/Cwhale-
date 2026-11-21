package com.deepwhalephone.suiwen

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.cwhale/generation",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isIgnoringBatteryOptimizations" -> {
                        val manager = getSystemService(PowerManager::class.java)
                        result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                                manager.isIgnoringBatteryOptimizations(packageName),
                        )
                    }
                    "requestBatteryOptimizationExemption" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                            result.success(true)
                        } else {
                            val manager = getSystemService(PowerManager::class.java)
                            if (manager.isIgnoringBatteryOptimizations(packageName)) {
                                result.success(true)
                            } else {
                                val intent = Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"),
                                )
                                startActivity(intent)
                                result.success(false)
                            }
                        }
                    }
                    "start" -> {
                        GenerationForegroundService.start(this) { started, error ->
                            if (started) {
                                result.success(null)
                                requestNotificationPermissionIfNeeded()
                            } else {
                                result.error(
                                    "GENERATION_SERVICE_FAILED",
                                    error ?: "Android 未确认后台生成服务已启动。",
                                    null,
                                )
                            }
                        }
                    }
                    "stop" -> {
                        GenerationForegroundService.stop(this)
                        result.success(null)
                    }
                    "complete" -> {
                        val completed = call.argument<Boolean>("completed") ?: false
                        val receivedCharacters =
                            call.argument<Int>("receivedCharacters") ?: 0
                        result.success(
                            GenerationForegroundService.complete(
                                completed,
                                receivedCharacters,
                            ),
                        )
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error(
                    "GENERATION_SERVICE_FAILED",
                    error.message ?: "无法启动后台生成保护。",
                    null,
                )
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.cwhale/local_files",
        ).setMethodCallHandler { call, result ->
            if (call.method == "openUrl") {
                val rawUrl = call.argument<String>("url")
                val uri = rawUrl?.let { Uri.parse(it) }
                if (uri == null || uri.scheme !in setOf("https", "http") || uri.host.isNullOrBlank()) {
                    result.error("INVALID_URL", "链接不是有效的 HTTP/HTTPS 地址。", null)
                    return@setMethodCallHandler
                }
                try {
                    startActivity(
                        Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE),
                    )
                    result.success(null)
                } catch (error: ActivityNotFoundException) {
                    result.error("NO_BROWSER", "设备上没有可打开链接的浏览器。", null)
                } catch (error: Exception) {
                    result.error("OPEN_URL_FAILED", error.message ?: "无法打开链接。", null)
                }
                return@setMethodCallHandler
            }

            if (call.method != "openWith") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val path = call.argument<String>("path")
            val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
            if (path.isNullOrBlank()) {
                result.error("INVALID_PATH", "文件路径为空。", null)
                return@setMethodCallHandler
            }

            try {
                val file = File(path).canonicalFile
                val appFilesRoot = filesDir.canonicalPath + File.separator
                if (!file.path.startsWith(appFilesRoot) || !file.isFile) {
                    result.error("FILE_NOT_FOUND", "本机文件不存在。", null)
                    return@setMethodCallHandler
                }

                val uri: Uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    file,
                )
                val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeType)
                    clipData = ClipData.newUri(contentResolver, file.name, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                startActivity(Intent.createChooser(viewIntent, "选择应用打开文件"))
                result.success(null)
            } catch (error: ActivityNotFoundException) {
                result.error("NO_FILE_APP", "没有安装可打开此文件的应用。", null)
            } catch (error: Exception) {
                result.error("OPEN_FILE_FAILED", error.message ?: "无法打开文件。", null)
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val preferences = getSharedPreferences("cwhale_runtime_permissions", MODE_PRIVATE)
        if (preferences.getBoolean("notification_requested", false)) return
        preferences.edit().putBoolean("notification_requested", true).apply()
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4103)
    }
}
