package com.msnguard.vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import android.widget.RemoteViews

/**
 * Home-screen widget: tunnel status plus one connect/disconnect button.
 *
 * Exported only for the system's APPWIDGET_UPDATE. Status updates and the
 * button go through [WidgetActionReceiver], which is not exported, so no other
 * app can toggle the VPN through it.
 */
class MolidoWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context)
    }

    companion object {
        const val ACTION_TOGGLE = "com.msnguard.vpn.WIDGET_TOGGLE"
        private const val PREFS = "widget"
        private const val KEY_STATUS = "status"

        fun saveStatus(context: Context, status: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_STATUS, status).apply()
        }

        private fun currentStatus(context: Context): String {
            val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_STATUS, MsnGuardVpnService.STATUS_DISCONNECTED)
                ?: MsnGuardVpnService.STATUS_DISCONNECTED
            // A stale "connected" after the process died must not stick.
            if (saved == MsnGuardVpnService.STATUS_CONNECTED && !TunnelStatus.isActive()) {
                return MsnGuardVpnService.STATUS_DISCONNECTED
            }
            return saved
        }

        fun render(context: Context) {
            val app = context.applicationContext
            if (AppLanguage.appContext == null) AppLanguage.appContext = app
            val manager = AppWidgetManager.getInstance(app)
            val ids = runCatching {
                manager.getAppWidgetIds(ComponentName(app, MolidoWidget::class.java))
            }.getOrNull() ?: return
            if (ids.isEmpty()) return
            val status = currentStatus(app)
            val connected = status == MsnGuardVpnService.STATUS_CONNECTED
            val busy = status == MsnGuardVpnService.STATUS_CONNECTING ||
                status == MsnGuardVpnService.STATUS_STARTING ||
                status == MsnGuardVpnService.STATUS_SCANNING
            val views = RemoteViews(app.packageName, R.layout.widget_molido)
            views.setTextViewText(
                R.id.widget_status,
                when {
                    connected -> Strings.t("Connected")
                    busy -> Strings.t("Connecting…")
                    else -> Strings.t("Disconnected")
                }
            )
            views.setImageViewResource(
                R.id.widget_icon,
                if (connected) R.drawable.ic_tile_connected else R.drawable.ic_tile_disconnected
            )
            views.setTextViewText(
                R.id.widget_button,
                if (connected || busy) Strings.t("Disconnect") else Strings.t("Connect")
            )
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val needsUi = !connected && !busy && !CoreConfig.proxyOnly(app) && VpnService.prepare(app) != null
            val click = if (needsUi) {
                // No VPN consent yet: only the app can ask for it.
                PendingIntent.getActivity(
                    app, 1,
                    Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    flags,
                )
            } else {
                PendingIntent.getBroadcast(
                    app, 2,
                    Intent(app, WidgetActionReceiver::class.java).setAction(ACTION_TOGGLE),
                    flags,
                )
            }
            views.setOnClickPendingIntent(R.id.widget_button, click)
            views.setOnClickPendingIntent(
                R.id.widget_icon,
                PendingIntent.getActivity(
                    app, 3,
                    Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    flags,
                )
            )
            runCatching { manager.updateAppWidget(ids, views) }
        }
    }
}

/** Not exported: status broadcasts from the service and the widget's button. */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        when (intent.action) {
            MsnGuardVpnService.ACTION_STATUS -> {
                // Traffic/exit-IP broadcasts share the action but carry no status.
                val status = intent.getStringExtra(MsnGuardVpnService.EXTRA_STATUS) ?: return
                MolidoWidget.saveStatus(app, status)
                MolidoWidget.render(app)
            }
            MolidoWidget.ACTION_TOGGLE -> {
                try {
                    if (TunnelStatus.isActive() || MsnGuardVpnService.STATUS_CONNECTING ==
                        app.getSharedPreferences("widget", Context.MODE_PRIVATE).getString("status", null)
                    ) {
                        app.startService(
                            Intent(app, MsnGuardVpnService::class.java).setAction(MsnGuardVpnService.ACTION_DISCONNECT)
                        )
                        MolidoWidget.saveStatus(app, MsnGuardVpnService.STATUS_DISCONNECTED)
                    } else if (AutoConnect.connect(app)) {
                        MolidoWidget.saveStatus(app, MsnGuardVpnService.STATUS_CONNECTING)
                    }
                } catch (e: Exception) {
                    Log.w("MolidoWidget", "toggle failed: ${e.message}")
                }
                MolidoWidget.render(app)
            }
        }
    }
}
