package com.shiyi.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 拾忆长任务的 Android 前台承载。
 *
 * Service 不承载第二套 Flutter 引擎，也不重复实现网络请求；它只让当前
 * Flutter 进程在用户明确发起生成或开启手机 Relay 后获得前台服务优先级，
 * 并显示运行状态。
 */
class ShiyiBackgroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "shiyi_background_tasks"
        private const val NOTIFICATION_ID = 43120
        private const val ACTION_SYNC = "com.shiyi.agent.action.SYNC"
        private const val EXTRA_ACTIVE_SESSIONS = "activeSessions"
        private const val EXTRA_RELAY_ENABLED = "relayEnabled"

        fun sync(context: Context, activeSessions: Int, relayEnabled: Boolean) {
            val intent = Intent(context, ShiyiBackgroundService::class.java).apply {
                action = ACTION_SYNC
                putExtra(EXTRA_ACTIVE_SESSIONS, activeSessions)
                putExtra(EXTRA_RELAY_ENABLED, relayEnabled)
            }
            if (activeSessions > 0 || relayEnabled) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ContextCompat.startForegroundService(context, intent)
                } else {
                    context.startService(intent)
                }
            } else {
                context.stopService(intent)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val activeSessions = intent?.getIntExtra(EXTRA_ACTIVE_SESSIONS, 1) ?: 1
        val relayEnabled = intent?.getBooleanExtra(EXTRA_RELAY_ENABLED, false) ?: false
        if (activeSessions <= 0 && !relayEnabled) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, buildNotification(activeSessions, relayEnabled))
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(activeSessions: Int, relayEnabled: Boolean): Notification {
        val title = "拾忆正在后台运行"
        val body = if (relayEnabled && activeSessions <= 0) {
            "手机 API 中转服务运行中，网络连接保持中"
        } else if (relayEnabled && activeSessions == 1) {
            "API 中转运行中，1 个会话正在生成"
        } else if (relayEnabled) {
            "API 中转运行中，$activeSessions 个会话正在生成"
        } else if (activeSessions == 1) {
            "1 个会话正在生成，网络连接保持中"
        } else {
            "$activeSessions 个会话正在生成，网络连接保持中"
        }
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            43120,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "拾忆后台任务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "拾忆生成、DSH 和远程同步任务的后台运行状态"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
