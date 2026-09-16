package com.molido.vpn

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.util.Calendar

/**
 * Daily auto-connect / auto-disconnect times.
 *
 * Stored as minutes after midnight (-1 = off) in the settings file. Alarms are
 * exact when Android allows it (exact alarms may start the VPN foreground
 * service from the background); otherwise inexact, and a connect Android
 * refuses is only logged. Re-armed after every alarm and on boot.
 */
object ConnectSchedule {

    const val PREF_CONNECT = "schedule_connect_min"
    const val PREF_DISCONNECT = "schedule_disconnect_min"
    const val ACTION_CONNECT = "com.molido.vpn.SCHEDULE_CONNECT"
    const val ACTION_DISCONNECT = "com.molido.vpn.SCHEDULE_DISCONNECT"

    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun minutes(context: Context, key: String): Int = prefs(context).getInt(key, -1)

    fun set(context: Context, key: String, minutes: Int) {
        prefs(context).edit().putInt(key, minutes).apply()
        reschedule(context)
    }

    fun label(minutes: Int): String =
        if (minutes < 0) Strings.t("Off") else String.format(java.util.Locale.US, "%02d:%02d", minutes / 60, minutes % 60)

    private fun pending(context: Context, action: String): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            if (action == ACTION_CONNECT) 41 else 42,
            Intent(context, ScheduleReceiver::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    fun reschedule(context: Context) {
        val app = context.applicationContext
        val am = app.getSystemService(AlarmManager::class.java) ?: return
        listOf(PREF_CONNECT to ACTION_CONNECT, PREF_DISCONNECT to ACTION_DISCONNECT).forEach { (key, action) ->
            val pi = pending(app, action)
            am.cancel(pi)
            val min = minutes(app, key)
            if (min < 0) return@forEach
            val at = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, min / 60)
                set(Calendar.MINUTE, min % 60)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
                if (timeInMillis <= System.currentTimeMillis() + 1000) add(Calendar.DAY_OF_YEAR, 1)
            }.timeInMillis
            try {
                val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
                if (exact) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                } else {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
                }
            } catch (e: Exception) {
                Log.w("ConnectSchedule", "could not arm $action: ${e.message}")
                runCatching { am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi) }
            }
        }
    }
}

/** Fires the scheduled connect/disconnect, then arms the next day's alarm. */
class ScheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        if (AppLanguage.appContext == null) AppLanguage.appContext = app
        try {
            when (intent.action) {
                ConnectSchedule.ACTION_CONNECT -> if (!TunnelStatus.isActive()) {
                    ConnectionLog.record("Schedule: connecting")
                    AutoConnect.connect(app)
                }
                ConnectSchedule.ACTION_DISCONNECT -> if (TunnelStatus.isActive()) {
                    ConnectionLog.record("Schedule: disconnecting")
                    app.startService(
                        Intent(app, MolidoVpnService::class.java).setAction(MolidoVpnService.ACTION_DISCONNECT)
                    )
                }
            }
        } catch (e: Exception) {
            Log.w("ConnectSchedule", "scheduled ${intent.action} failed: ${e.message}")
        } finally {
            ConnectSchedule.reschedule(app)
        }
    }
}
