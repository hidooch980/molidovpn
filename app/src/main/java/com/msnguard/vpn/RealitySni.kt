package com.msnguard.vpn

import android.content.Context
import java.net.HttpURLConnection
import java.net.URL

/**
 * Alternate SNIs for V2Ray REALITY nodes that fail their probe.
 *
 * Retry-only: [ShardManager] uses these only after a whole race found nothing,
 * with at most [MAX_ALTERNATES] alternates per node and never when the node's own
 * SNI is already one of them. A SNI that then carries a real request is
 * remembered per node ([remembered]) and used on later connects.
 *
 * The list comes from remote/reality-sni.txt (raw.githubusercontent, then
 * jsDelivr), cached for a day; a short built-in list covers a first run offline.
 */
object RealitySni {

    private const val PREFS = "reality_sni"
    private const val LIST_KEY = "list"
    private const val AT_KEY = "list_at"
    private const val MAX_AGE_MS = 24 * 60 * 60 * 1000L
    const val MAX_ALTERNATES = 3

    private val URLS = listOf(
        "https://raw.githubusercontent.com/hidooch980/molidovpn-android/main/remote/reality-sni.txt",
        "https://cdn.jsdelivr.net/gh/hidooch980/molidovpn-android@main/remote/reality-sni.txt",
    )

    private val BUILT_IN = listOf("www.speedtest.net", "www.microsoft.com", "www.apple.com")

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun valid(host: String): Boolean =
        host.length in 4..253 && host.contains('.') && host.all { it.isLetterOrDigit() || it == '.' || it == '-' }

    /** The alternate list; fetches (blocking, short timeouts) when the cache is stale. */
    fun list(context: Context): List<String> {
        val p = prefs(context)
        val cached = p.getString(LIST_KEY, "").orEmpty().split('\n').filter { valid(it) }
        val age = System.currentTimeMillis() - p.getLong(AT_KEY, 0L)
        if (cached.isNotEmpty() && age in 0 until MAX_AGE_MS) return cached
        for (url in URLS) {
            val body = fetch(url) ?: continue
            val hosts = body.lineSequence().map { it.trim().lowercase() }
                .filter { it.isNotEmpty() && !it.startsWith("#") && valid(it) }
                .distinct().toList()
            if (hosts.isNotEmpty()) {
                p.edit().putString(LIST_KEY, hosts.joinToString("\n"))
                    .putLong(AT_KEY, System.currentTimeMillis()).apply()
                return hosts
            }
        }
        return cached.ifEmpty { BUILT_IN }
    }

    private fun fetch(url: String): String? = try {
        (URL(url).openConnection() as HttpURLConnection).run {
            connectTimeout = 4_000
            readTimeout = 5_000
            try {
                if (responseCode == 200) inputStream.bufferedReader().use { it.readText().take(64_000) } else null
            } finally {
                disconnect()
            }
        }
    } catch (_: Exception) {
        null
    }

    fun isReality(node: ShardNode): Boolean = node.v2ray?.security == "reality"

    /** Copy of [node] using [sni] (both the V2Ray SNI and the ShardNode serverName). */
    fun withSni(node: ShardNode, sni: String): ShardNode {
        val v2 = node.v2ray ?: return node
        return node.copy(serverName = sni, v2ray = v2.copy(sni = sni))
    }

    fun remembered(context: Context, node: ShardNode): String? =
        prefs(context).getString("node_" + node.key, null)?.takeIf { valid(it) }

    fun remember(context: Context, node: ShardNode, sni: String) {
        prefs(context).edit().putString("node_" + node.key, sni).apply()
    }

    /** Pool with each reality node's remembered working SNI applied. */
    fun applyRemembered(context: Context, pool: List<ShardNode>): List<ShardNode> =
        pool.map { node -> if (isReality(node)) remembered(context, node)?.let { withSni(node, it) } ?: node else node }

    /** Up to [MAX_ALTERNATES] SNI variants for each reality node in [failed]. */
    fun alternates(context: Context, failed: List<ShardNode>): List<ShardNode> {
        val reality = failed.filter { isReality(it) }
        if (reality.isEmpty()) return emptyList()
        val hosts = list(context)
        val out = ArrayList<ShardNode>()
        reality.forEach { node ->
            val own = node.v2ray?.sni.orEmpty().lowercase()
            if (own in hosts) return@forEach
            hosts.shuffled().take(MAX_ALTERNATES).forEach { out.add(withSni(node, it)) }
        }
        return out
    }
}
