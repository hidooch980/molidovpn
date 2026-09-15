package com.molido.vpn

import android.content.Context

/**
 * User DNS choice: Automatic (today's behaviour, unchanged) or one of the Iranian
 * "gaming DNS" servers.
 *
 * The gaming servers only answer from inside Iranian networks, so their IPs are
 * routed OUTSIDE the tunnel (VpnService.Builder.excludeRoute, API 33+). Below
 * API 33 that is impossible and the service falls back to Automatic, logging why.
 */
object DnsSettings {

    const val PREF = "dns_preset"

    enum class Preset(
        val key: String,
        val enLabel: String,
        val servers: List<String>,
        val gaming: Boolean = false,
    ) {
        AUTO("auto", "Automatic", emptyList()),
        RADAR("radar", "Radar Game", listOf("10.202.10.10", "10.202.10.11"), gaming = true),
        ELECTRO("electro", "Electro", listOf("78.157.42.100", "78.157.42.101"), gaming = true),
        SHECAN("shecan", "Shecan", listOf("178.22.122.100", "185.51.200.2"), gaming = true),
        ONLINE403("403", "403.online", listOf("10.202.10.202", "10.202.10.102"), gaming = true);

        val label: String get() = Strings.t(enLabel)
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun preset(context: Context): Preset {
        val key = prefs(context).getString(PREF, Preset.AUTO.key)
        return Preset.entries.firstOrNull { it.key == key } ?: Preset.AUTO
    }

    fun byKey(key: String?): Preset? = Preset.entries.firstOrNull { it.key == key }

    fun setPreset(context: Context, preset: Preset) {
        prefs(context).edit().putString(PREF, preset.key).apply()
    }
}
