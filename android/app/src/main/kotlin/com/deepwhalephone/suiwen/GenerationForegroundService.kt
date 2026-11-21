package com.deepwhalephone.suiwen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

class GenerationForegroundService : Service() {
    private var generationWakeLock: PowerManager.WakeLock? = null
    private var generationStartedAt = 0L
    private var isForeground = false

    override fun onCreate() {
        super.onCreate()
        activeService = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "模型回复生成",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "用户发起的模型回复正在生成时显示。"
                    setShowBadge(false)
                },
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (!isForeground) {
                isForeground = true
                generationStartedAt = SystemClock.elapsedRealtime()
            }
            val notification = buildNotification(ongoing = true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            acquireGenerationWakeLock()
            completePendingStarts(success = true)
        } catch (error: Exception) {
            Log.e(TAG, "Could not enter foreground state", error)
            isForeground = false
            completePendingStarts(
                success = false,
                error = error.message ?: error.javaClass.simpleName,
            )
            stopSelf(startId)
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isForeground = false
        generationWakeLock?.let { wakeLock ->
            if (wakeLock.isHeld) wakeLock.release()
        }
        generationWakeLock = null
        if (activeService === this) activeService = null
        super.onDestroy()
    }

    private fun finishGeneration(completed: Boolean, receivedCharacters: Int) {
        if (!isForeground) return
        isForeground = false
        val durationSeconds =
            ((SystemClock.elapsedRealtime() - generationStartedAt) / 1_000L)
                .coerceAtLeast(0L)
        val finalTitle = if (completed) "Cwhale 回复已完成" else "Cwhale 回复中断"
        val finalText =
            "${formatElapsed(durationSeconds)} · 已接收约 ${receivedCharacters.coerceAtLeast(0)} 字符"
        getSystemService(NotificationManager::class.java).notify(
            NOTIFICATION_ID,
            buildNotification(
                ongoing = false,
                title = finalTitle,
                text = finalText,
            ),
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
        generationWakeLock?.let { wakeLock ->
            if (wakeLock.isHeld) wakeLock.release()
        }
        generationWakeLock = null
        stopSelf()
    }

    private fun acquireGenerationWakeLock() {
        if (generationWakeLock?.isHeld == true) return
        try {
            generationWakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:Generation")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        } catch (error: Exception) {
            // Foreground service priority remains active if the optional CPU
            // wake lock is unavailable; keep the actual generation running.
            Log.w(TAG, "Could not acquire generation wake lock", error)
        }
    }

    private fun buildNotification(
        ongoing: Boolean,
        title: String = "Cwhale 正在生成回复",
        text: String = "切回 Cwhale 查看实时回复。",
    ): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        private const val TAG = "CwhaleGeneration"
        private const val CHANNEL_ID = "cwhale_generation"
        private const val NOTIFICATION_ID = 4102
        private const val START_TIMEOUT_MS = 4_000L
        private val mainHandler = Handler(Looper.getMainLooper())
        private val pendingStartCallbacks = mutableListOf<(Boolean, String?) -> Unit>()
        private var startTimeout: Runnable? = null
        private var activeService: GenerationForegroundService? = null

        fun start(
            context: android.content.Context,
            onStarted: (Boolean, String?) -> Unit,
        ) {
            synchronized(pendingStartCallbacks) {
                pendingStartCallbacks.add(onStarted)
                startTimeout?.let { mainHandler.removeCallbacks(it) }
                val timeout = Runnable {
                    completePendingStarts(
                        success = false,
                        error = "Android 未能及时确认前台服务已启动。",
                    )
                }
                startTimeout = timeout
                mainHandler.postDelayed(timeout, START_TIMEOUT_MS)
            }
            val intent = Intent(context, GenerationForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                completePendingStarts(
                    success = false,
                    error = error.message ?: error.javaClass.simpleName,
                )
            }
        }

        private fun completePendingStarts(success: Boolean, error: String? = null) {
            val callbacks = synchronized(pendingStartCallbacks) {
                val pending = pendingStartCallbacks.toList()
                pendingStartCallbacks.clear()
                startTimeout?.let { mainHandler.removeCallbacks(it) }
                startTimeout = null
                pending
            }
            callbacks.forEach { callback -> callback(success, error) }
        }

        fun complete(completed: Boolean, receivedCharacters: Int): Boolean {
            val service = activeService ?: return false
            service.finishGeneration(completed, receivedCharacters)
            return true
        }

        private fun formatElapsed(totalSeconds: Long): String {
            val hours = totalSeconds / 3_600L
            val minutes = (totalSeconds % 3_600L) / 60L
            val seconds = totalSeconds % 60L
            return if (hours > 0) {
                "%d:%02d:%02d".format(hours, minutes, seconds)
            } else {
                "%02d:%02d".format(minutes, seconds)
            }
        }

        fun stop(context: android.content.Context) {
            context.stopService(Intent(context, GenerationForegroundService::class.java))
        }
    }
}
