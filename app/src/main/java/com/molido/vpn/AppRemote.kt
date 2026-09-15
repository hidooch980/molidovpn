package com.molido.vpn

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Owner-controlled settings from the /admin panel, served by the worker:
 *
 *  * `/app/flags.json`  — default connection mode for users who never picked one,
 *    and modes switched off globally (skipped by Auto, greyed in the picker).
 *  * `/app/notice.json` — one dismissible announcement for the home screen.
 *
 * Fails safe: nothing fetched yet → last cached copy → defaults (everything
 * enabled, Auto). The worker never allows all modes off; this side re-checks.
 */
object AppRemote {

    data class Notice(
        val id: String,
        val text: String,
        val warning: Boolean,
        val link: String,
        val linkLabel: String,
        val expiresAt: Long,
    )

    private const val BASE = "https://molido-sub.hidooch980.workers.dev/app/"
    private const val PREFS = "app_remote"
    private const val MIN_INTERVAL_MS = 5 * 60 * 1000L
    private const val TIMEOUT_MS = 8_000

    /** Flag keys the panel knows; Android core names map onto them in [flagKey]. */
    private val KNOWN = setOf("warp", "masque", "gool", "amnezia", "psiphon", "tor", "dns", "shard", "v2ray")

    private val refreshing = AtomicBoolean(false)

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Panel key for an Android core name; null for modes that can never be disabled (Auto, My configs). */
    fun flagKey(coreName: String): String? = when (coreName.lowercase()) {
        "wireguard" -> "warp"
        "masque" -> "masque"
        "gool" -> "gool"
        AmneziaConfig.PROTOCOL.lowercase() -> "amnezia"
        "psiphon" -> "psiphon"
        "tor" -> "tor"
        "dns" -> "dns"
        "shard" -> "shard"
        "v2ray" -> "v2ray"
        else -> null
    }

    fun disabledKeys(context: Context): Set<String> = try {
        val json = JSONObject(prefs(context).getString("flags", null) ?: "{}")
        val array = json.optJSONArray("disabled")
        val out = HashSet<String>()
        if (array != null) for (i in 0 until array.length()) array.optString(i).takeIf { it in KNOWN }?.let(out::add)
        // Never trust a list that would leave nothing to connect with.
        if (out.size >= KNOWN.size) emptySet() else out
    } catch (_: Exception) {
        emptySet()
    }

    /**
     * Whether [coreName] is switched off by the owner. Chains are off when any of
     * their legs is: Psiphon-over-WARP needs Psiphon and WARP, V2Ray-over-Psiphon
     * needs V2Ray and Psiphon.
     */
    fun isDisabled(context: Context, coreName: String): Boolean {
        val off = disabledKeys(context)
        if (off.isEmpty()) return false
        val name = coreName.lowercase()
        if (name.contains("psiphon") && name != "psiphon") {
            return "psiphon" in off || (name.contains("v2ray") && "v2ray" in off) ||
                (!name.contains("v2ray") && "warp" in off)
        }
        val key = flagKey(name) ?: return false
        return key in off
    }

    /** Owner's default mode as an Android core name, or null for Auto / unknown / disabled. */
    fun defaultMode(context: Context): String? = try {
        val key = JSONObject(prefs(context).getString("flags", null) ?: "{}").optString("default_mode")
        val core = when (key) {
            "warp" -> "wireguard"
            "amnezia" -> AmneziaConfig.PROTOCOL
            in KNOWN -> key
            else -> null
        }
        core?.takeIf { !isDisabled(context, it) }
    } catch (_: Exception) {
        null
    }

    /** Active, not dismissed, not expired announcement from the cache. */
    fun notice(context: Context): Notice? = try {
        val p = prefs(context)
        val json = JSONObject(p.getString("notice", null) ?: "{}")
        val id = json.optString("id")
        val text = json.optString("text").trim()
        val expires = json.optLong("expires_at", 0L)
        if (id.isEmpty() || text.isEmpty() || p.getString("dismissed", "") == id ||
            (expires > 0L && expires <= System.currentTimeMillis())
        ) {
            null
        } else {
            Notice(
                id = id,
                text = text,
                warning = json.optString("type") == "warning",
                link = json.optString("link").trim().takeIf { it.startsWith("https://") } ?: "",
                linkLabel = json.optString("link_label").trim(),
                expiresAt = expires,
            )
        }
    } catch (_: Exception) {
        null
    }

    fun dismissNotice(context: Context, id: String) {
        prefs(context).edit().putString("dismissed", id).apply()
    }

    /**
     * Background fetch of both files, at most every 5 minutes unless [force].
     * [onUpdated] runs on the fetch thread after a successful fetch.
     */
    fun refreshIfDue(context: Context, force: Boolean = false, onUpdated: (() -> Unit)? = null) {
        val app = context.applicationContext
        val p = prefs(app)
        val elapsed = System.currentTimeMillis() - p.getLong("at", 0L)
        if (!force && elapsed in 0 until MIN_INTERVAL_MS) return
        if (!refreshing.compareAndSet(false, true)) return
        Thread({
            try {
                refreshNow(app)
                onUpdated?.invoke()
            } catch (_: Exception) {
                // Cached copy (or defaults) stay in use.
            } finally {
                refreshing.set(false)
            }
        }, "app-remote").apply { isDaemon = true }.start()
    }

    /** Blocking: call off the main thread. Keeps the cache when a fetch fails. */
    fun refreshNow(context: Context) {
        val p = prefs(context)
        val editor = p.edit()
        var any = false
        get("flags.json")?.let { body ->
            if (runCatching { JSONObject(body) }.isSuccess) { editor.putString("flags", body); any = true }
        }
        get("notice.json")?.let { body ->
            if (runCatching { JSONObject(body) }.isSuccess) { editor.putString("notice", body); any = true }
        }
        if (any) editor.putLong("at", System.currentTimeMillis())
        editor.apply()
    }

    private fun get(file: String): String? = try {
        val connection = URL(BASE + file).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.setRequestProperty("User-Agent", "MolidoVPN-Android")
            if (connection.responseCode != 200) null
            else connection.inputStream.bufferedReader().use { it.readText() }.takeIf { it.length < 16_000 }
        } finally {
            connection.disconnect()
        }
    } catch (_: Exception) {
        null
    }
}
