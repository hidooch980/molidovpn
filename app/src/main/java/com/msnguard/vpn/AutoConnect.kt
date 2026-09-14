package com.msnguard.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log

/**
 * Connect without a user tap: after boot / app update ([BootReceiver]) and when
 * Android's "Always-on VPN" starts the service itself.
 *
 * Builds exactly the config the Quick Settings tile builds, so all three
 * non-interactive entry points raise the same tunnel shape as the tile.
 */
object AutoConnect {

    private const val TAG = "AutoConnect"

    /** SharedPreferences key in the "settings" file. */
    const val PREF = "auto_connect"
    const val DEFAULT = true

    fun enabled(context: Context): Boolean =
        context.getSharedPreferences(MsnGuardTileService.SETTINGS, Context.MODE_PRIVATE)
            .getBoolean(PREF, DEFAULT)

    /**
     * Config for a tile-style connect. Honours the chain card: if
     * Psiphon-over-WARP is armed and Psiphon is the picked transport, the chain is
     * raised rather than the bare transport.
     */
    fun configJson(context: Context): String {
        val prefs = context.getSharedPreferences(MsnGuardTileService.SETTINGS, Context.MODE_PRIVATE)
        val armed = prefs.getBoolean(
            MsnGuardTileService.CHAIN_ARMED,
            MsnGuardTileService.CHAIN_ARMED_DEFAULT,
        )
        val picked = prefs.getString(
            MsnGuardTileService.DEFAULT_PROTOCOL,
            MsnGuardTileService.Companion.Protocol.AUTO.coreName,
        )
        return if (armed && picked == MsnGuardTileService.Companion.Protocol.PSIPHON.coreName) {
            CoreConfig.json(context, MsnGuardVpnService.CHAIN_PROTOCOL_MARKER.lowercase())
        } else {
            CoreConfig.json(context)
        }
    }

    /**
     * Starts the tunnel if consent is already granted.
     *
     * @return false when VPN consent is missing (nothing can be done without UI).
     */
    fun connect(context: Context): Boolean {
        val needsConsent = !CoreConfig.proxyOnly(context) && VpnService.prepare(context) != null
        if (needsConsent) {
            Log.w(TAG, "VPN consent missing; not auto-connecting")
            return false
        }
        context.startForegroundService(
            Intent(context, MsnGuardVpnService::class.java)
                .setAction(MsnGuardVpnService.ACTION_CONNECT)
                .putExtra(MsnGuardVpnService.EXTRA_CONFIG, configJson(context))
        )
        return true
    }
}

/** Auto-connect after the phone restarts or the app is updated. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val app = context.applicationContext
        if (AppLanguage.appContext == null) AppLanguage.appContext = app
        // Alarms do not survive a reboot or an update: re-arm the schedule first.
        runCatching { ConnectSchedule.reschedule(app) }
        if (!AutoConnect.enabled(app)) return
        if (TunnelStatus.isActive()) return
        try {
            AutoConnect.connect(app)
        } catch (e: Exception) {
            // Background FGS start restrictions or similar: never crash on boot.
            Log.w("AutoConnect", "Boot auto-connect failed: ${e.message}")
        }
    }
}
