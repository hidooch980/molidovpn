package com.molido.vpn

import android.content.Context

/**
 * Preferred exit country for the V2Ray servers pool (and My configs).
 *
 * The country comes from the node's name ([ShardNode.countryCode]: a leading ISO
 * pair or a flag emoji). Nodes without one never match a chosen country. When
 * nothing in the pool matches, connecting falls back to the whole pool rather than
 * failing; the picker refuses a country with no servers up front.
 */
object CountryFilter {

    const val PREF = "v2ray_country"

    /** Offered in the picker even when the pool has none right now. */
    val COMMON = listOf("TR", "DE", "NL", "FI", "FR", "GB", "US", "CA", "SE", "AE", "AM", "RU", "JP", "SG")

    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun selected(context: Context): String = prefs(context).getString(PREF, "").orEmpty()

    fun set(context: Context, code: String) {
        prefs(context).edit().putString(PREF, code.uppercase()).apply()
        ConnectionLog.record(if (code.isEmpty()) "Country filter off" else "Country filter: $code")
    }

    /** Country name in the UI language (e.g. "ایالات متحده"), falling back to the code. */
    fun displayName(code: String): String = runCatching {
        java.util.Locale("", code).getDisplayCountry(java.util.Locale(AppLanguage.current())).ifBlank { code }
    }.getOrDefault(code)

    /** Shown when no server from the chosen country connected with an exit in that country. */
    fun noServerMessage(context: Context): String {
        val code = selected(context)
        return Strings.tf("No working server from %s was found; choose another country or tap Automatic", "${flag(code)} ${displayName(code)}".trim())
    }

    /** Regional-indicator flag for an ISO pair, or "" for anything else. */
    fun flag(code: String): String {
        if (code.length != 2 || code.any { it !in 'A'..'Z' }) return ""
        return String(Character.toChars(0x1F1E6 + (code[0] - 'A'))) +
            String(Character.toChars(0x1F1E6 + (code[1] - 'A')))
    }

    /** Every pool the filter applies to; worker threads only (may fetch). */
    fun pool(context: Context): List<ShardNode> =
        runCatching { V2raySubscription.shardNodes(context) + MyConfigs.shardNodes(context) }.getOrDefault(emptyList())

    fun counts(pool: List<ShardNode>): Map<String, Int> =
        pool.map { it.countryCode }.filter { it.isNotEmpty() }.groupingBy { it }.eachCount()

    /**
     * [pool] narrowed to the chosen country. An explicit choice is never widened:
     * empty when no server from that country exists (the caller fails with
     * [noServerMessage] instead of silently exiting somewhere else).
     */
    fun apply(context: Context, pool: List<ShardNode>, log: Boolean = true): List<ShardNode> {
        val code = selected(context)
        if (code.isEmpty() || pool.isEmpty()) return pool
        val matching = pool.filter { it.countryCode == code }
        if (matching.isEmpty()) {
            if (log) ConnectionLog.record("Country filter: no $code server available — not connecting elsewhere")
            return emptyList()
        }
        if (log) ConnectionLog.record("Country filter: ${matching.size} $code servers")
        return matching
    }
}
