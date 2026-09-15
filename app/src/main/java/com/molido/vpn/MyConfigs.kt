package com.molido.vpn

import android.content.Context
import android.graphics.Bitmap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * "My configs": the user's own share links, WireGuard / AmneziaWG configs and
 * subscription URLs, stored app-private in `filesDir/my-configs.json`.
 *
 * Proxy entries (vless incl. xhttp, vmess, trojan, ss, hysteria2, tuic, anytls)
 * connect through the SHARD machinery exactly like the V2Ray servers pool
 * ([shardNodes]); WireGuard entries connect through the AmneziaWG import path.
 * Subscriptions are re-fetched every [SUB_INTERVAL_MS].
 */
object MyConfigs {

    private const val TAG = "MyConfigs"

    /** Rail / preference / Auto name. */
    const val PROTOCOL = "myconfigs"

    const val KIND_PROXY = "proxy"
    const val KIND_WIREGUARD = "wireguard"

    private const val FILE = "my-configs.json"
    private const val PIN_PREF = "my_configs_pinned"
    private const val SUB_INTERVAL_MS = 6 * 60 * 60 * 1000L
    private const val MAX_ENTRIES = 500
    private const val MAX_BODY_CHARS = 2 * 1024 * 1024

    data class Entry(
        val id: String,
        val name: String,
        /** Share line, or the full WireGuard .conf text for [KIND_WIREGUARD]. */
        val line: String,
        val kind: String,
        /** Owning subscription id, or empty for a manually added entry. */
        val subId: String = "",
        /** Last ping in ms; -1 never tested, 0 failed. */
        val latencyMs: Int = -1,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("id", id).put("name", name).put("line", line).put("kind", kind)
            .put("sub", subId).put("ms", latencyMs)

        override fun toString(): String = "Entry($id, $kind)"
    }

    data class Sub(val id: String, val url: String, val name: String, val lastFetch: Long) {
        fun toJson(): JSONObject = JSONObject().put("id", id).put("url", url).put("name", name).put("at", lastFetch)
    }

    class Added(val added: Int, val skipped: Int)

    private val refreshing = AtomicBoolean(false)

    private fun file(context: Context) = File(context.filesDir, FILE)
    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private fun newId(): String = UUID.randomUUID().toString().replace("-", "").take(12)

    // ------------------------------------------------------------ storage

    @Synchronized
    fun entries(context: Context): List<Entry> = read(context).first

    @Synchronized
    fun subs(context: Context): List<Sub> = read(context).second

    private fun read(context: Context): Pair<List<Entry>, List<Sub>> {
        try {
            val f = file(context)
            if (!f.exists()) return Pair(emptyList(), emptyList())
            val root = JSONObject(f.readText())
            val e = root.optJSONArray("entries") ?: JSONArray()
            val s = root.optJSONArray("subs") ?: JSONArray()
            val entries = (0 until e.length()).map { i ->
                val j = e.getJSONObject(i)
                Entry(
                    id = j.getString("id"),
                    name = j.optString("name"),
                    line = j.getString("line"),
                    kind = j.optString("kind", KIND_PROXY),
                    subId = j.optString("sub"),
                    latencyMs = j.optInt("ms", -1),
                )
            }
            val subs = (0 until s.length()).map { i ->
                val j = s.getJSONObject(i)
                Sub(j.getString("id"), j.getString("url"), j.optString("name"), j.optLong("at", 0L))
            }
            return Pair(entries, subs)
        } catch (e: Exception) {
            ConnectionLog.record("$TAG could not read the store: ${e.javaClass.simpleName}")
            return Pair(emptyList(), emptyList())
        }
    }

    private fun write(context: Context, entries: List<Entry>, subs: List<Sub>) {
        val root = JSONObject()
            .put("entries", JSONArray().apply { entries.forEach { put(it.toJson()) } })
            .put("subs", JSONArray().apply { subs.forEach { put(it.toJson()) } })
        val tmp = File(context.filesDir, "$FILE.tmp")
        tmp.writeText(root.toString())
        if (!tmp.renameTo(file(context))) {
            file(context).writeText(root.toString())
            tmp.delete()
        }
    }

    fun pinned(context: Context): String = prefs(context).getString(PIN_PREF, "").orEmpty()

    /** Connect to one entry only; empty = race all of them. */
    fun pin(context: Context, id: String) {
        prefs(context).edit().putString(PIN_PREF, id).apply()
    }

    @Synchronized
    fun rename(context: Context, id: String, name: String) {
        val (e, s) = read(context)
        write(context, e.map { if (it.id == id) it.copy(name = name.trim().ifEmpty { it.name }) else it }, s)
    }

    @Synchronized
    fun delete(context: Context, id: String) {
        val (e, s) = read(context)
        write(context, e.filterNot { it.id == id }, s)
        if (pinned(context) == id) pin(context, "")
    }

    @Synchronized
    fun deleteSub(context: Context, subId: String) {
        val (e, s) = read(context)
        val removed = e.filter { it.subId == subId }.map { it.id }.toSet()
        write(context, e.filterNot { it.subId == subId }, s.filterNot { it.id == subId })
        if (pinned(context) in removed) pin(context, "")
    }

    @Synchronized
    fun setLatency(context: Context, results: Map<String, Int>) {
        val (e, s) = read(context)
        write(context, e.map { entry -> results[entry.id]?.let { entry.copy(latencyMs = it) } ?: entry }, s)
    }

    // ------------------------------------------------------------ pool

    fun hasProxyNodes(context: Context): Boolean = entries(context).any { it.kind == KIND_PROXY }

    /** Node for a proxy entry, or null when the line no longer parses. */
    fun node(entry: Entry): ShardNode? =
        if (entry.kind != KIND_PROXY) null else V2rayNodes.parseOne(entry.line)?.let { V2rayNodes.toShardNode(it) }

    /** The pinned entry when one is set, otherwise every proxy entry. */
    fun shardNodes(context: Context): List<ShardNode> {
        val proxies = entries(context).filter { it.kind == KIND_PROXY }
        val pin = pinned(context)
        val chosen = proxies.filter { it.id == pin }.ifEmpty { proxies }
        return chosen.mapNotNull { node(it) }.distinctBy { it.key }
    }

    fun protocolLabel(entry: Entry): String =
        if (entry.kind == KIND_WIREGUARD) "wireguard" else node(entry)?.let { NodeTest.label(it) } ?: "?"

    // ------------------------------------------------------------ adding

    /**
     * Adds everything recognisable in [text]: share links (one per line, or a
     * base64 subscription body), subscription URLs, wireguard:// links and a full
     * WireGuard / AmneziaWG .conf. Blocking (subscriptions are fetched); worker
     * threads only.
     */
    fun addText(context: Context, text: String): Added {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return Added(0, 0)
        if (trimmed.contains("[Interface]", ignoreCase = true)) {
            return if (addWireGuardConf(context, trimmed, "")) Added(1, 0) else Added(0, 1)
        }
        val lines = if (trimmed.contains("://")) {
            trimmed.lines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
        } else {
            V2rayNodes.decodeBody(trimmed)
        }
        var added = 0
        var skipped = 0
        val proxies = ArrayList<Entry>()
        lines.forEach { line ->
            when (line.substringBefore("://", "").lowercase(Locale.US)) {
                // ssconf:// is an Outline dynamic access key: kept like a subscription
                // so the key is re-fetched when its owner rotates it.
                "http", "https", "ssconf" -> if (addSubscription(context, line) >= 0) added++ else skipped++
                "wireguard", "wg" -> {
                    val conf = wireGuardUriToConf(line)
                    if (conf != null && addWireGuardConf(context, conf, dec(line.substringAfter('#', "")))) added++ else skipped++
                }
                else -> {
                    val node = V2rayNodes.parseOne(line)
                    if (node == null) {
                        skipped++
                    } else {
                        proxies += Entry(newId(), node.name.ifEmpty { node.address }, V2rayNodes.shareLine(node), KIND_PROXY)
                    }
                }
            }
        }
        if (proxies.isNotEmpty()) {
            val stored = appendProxies(context, proxies)
            added += stored
            skipped += proxies.size - stored
        }
        ConnectionLog.record("$TAG added $added, skipped $skipped")
        return Added(added, skipped)
    }

    @Synchronized
    private fun appendProxies(context: Context, fresh: List<Entry>): Int {
        val (e, s) = read(context)
        val known = e.mapNotNull { if (it.kind == KIND_PROXY) V2rayNodes.parseOne(it.line)?.uri else null }.toMutableSet()
        val toAdd = fresh.filter { entry -> V2rayNodes.parseOne(entry.line)?.uri?.let { known.add(it) } == true }
            .take((MAX_ENTRIES - e.size).coerceAtLeast(0))
        if (toAdd.isNotEmpty()) write(context, e + toAdd, s)
        return toAdd.size
    }

    @Synchronized
    private fun addWireGuardConf(context: Context, conf: String, name: String): Boolean {
        if (runCatching { AmneziaConfig.parse(conf) }.isFailure) return false
        val (e, s) = read(context)
        if (e.any { it.kind == KIND_WIREGUARD && it.line == conf }) return false
        if (e.size >= MAX_ENTRIES) return false
        write(context, e + Entry(newId(), name.ifEmpty { "WireGuard" }, conf, KIND_WIREGUARD), s)
        return true
    }

    /** URL-decoding that keeps `+` (base64 keys and passwords carry it). */
    private fun dec(value: String): String =
        runCatching { URLDecoder.decode(value.replace("+", "%2B"), "UTF-8") }.getOrDefault(value)

    /** wireguard://PRIVATEKEY@host:port?publickey=&address=&mtu=#name → .conf text. */
    private fun wireGuardUriToConf(line: String): String? {
        val body = line.substringBefore('#').substringAfter("://")
        val privateKey = dec(body.substringBefore('@', ""))
        if (privateKey.isEmpty()) return null
        val hostPortQuery = body.substringAfter('@')
        val endpoint = hostPortQuery.substringBefore('?').trimEnd('/')
        val q = hostPortQuery.substringAfter('?', "").split('&').filter { it.contains('=') }
            .associate { it.substringBefore('=').lowercase(Locale.US) to dec(it.substringAfter('=')) }
        val publicKey = q["publickey"].orEmpty().ifEmpty { q["public_key"].orEmpty() }.ifEmpty { q["peer_public_key"].orEmpty() }
        val address = q["address"].orEmpty().ifEmpty { q["ip"].orEmpty() }
        if (publicKey.isEmpty() || address.isEmpty() || endpoint.isEmpty()) return null
        return buildString {
            append("[Interface]\nPrivateKey = ").append(privateKey).append('\n')
            append("Address = ").append(address).append('\n')
            q["mtu"]?.takeIf { it.isNotEmpty() }?.let { append("MTU = ").append(it).append('\n') }
            append("[Peer]\nPublicKey = ").append(publicKey).append('\n')
            append("Endpoint = ").append(endpoint).append('\n')
            append("AllowedIPs = 0.0.0.0/0, ::/0\n")
        }
    }

    // ------------------------------------------------------------ subscriptions

    /** Stores [url] and fetches it; the node count, or -1 when it is not a URL. */
    fun addSubscription(context: Context, url: String): Int {
        val u = url.trim()
        val host = runCatching { URL(httpsUrl(u)).host }.getOrNull()?.takeIf { it.isNotEmpty() } ?: return -1
        val sub = synchronized(this) {
            val (e, s) = read(context)
            s.firstOrNull { it.url == u } ?: Sub(newId(), u, host, 0L).also { write(context, e, s + it) }
        }
        return refreshSub(context, sub).coerceAtLeast(0)
    }

    /** Re-fetches one subscription; the node count, or -1 when the fetch failed. */
    fun refreshSub(context: Context, sub: Sub): Int {
        val body = fetch(httpsUrl(sub.url)) ?: return -1
        val nodes = V2rayNodes.parse(V2rayNodes.decodeBody(outlineBody(body, sub.url)))
        synchronized(this) {
            val (e, s) = read(context)
            if (s.none { it.id == sub.id }) return 0
            val now = System.currentTimeMillis()
            val subs = s.map { if (it.id == sub.id) it.copy(lastFetch = now) else it }
            if (nodes.isEmpty()) {
                // Keep the previous entries: an empty answer is more likely a block than a wipe.
                write(context, e, subs)
                return 0
            }
            val others = e.filter { it.subId != sub.id }
            val previous = e.filter { it.subId == sub.id }
                .associateBy { V2rayNodes.parseOne(it.line)?.uri.orEmpty() }
            val fresh = nodes.take((MAX_ENTRIES - others.size).coerceAtLeast(0)).map { n ->
                previous[n.uri]?.copy(line = V2rayNodes.shareLine(n))
                    ?: Entry(newId(), n.name.ifEmpty { n.address }, V2rayNodes.shareLine(n), KIND_PROXY, sub.id)
            }
            write(context, others + fresh, subs)
            ConnectionLog.record("$TAG subscription updated — ${fresh.size} configs")
            return fresh.size
        }
    }

    /** ssconf://host/path → https://host/path (Outline always serves keys over HTTPS). */
    private fun httpsUrl(url: String): String =
        if (url.startsWith("ssconf://", ignoreCase = true)) "https://" + url.substring("ssconf://".length) else url

    /**
     * An Outline dynamic access key answers `{server, server_port, password, method}`
     * (or a plain `ss://` line). Turned into one SIP002 `ss://` line so the ordinary
     * parser takes it; any other body is returned unchanged. The optional `prefix`
     * (salt prefix) has no xray equivalent and is ignored.
     */
    private fun outlineBody(body: String, url: String): String {
        val text = body.trim()
        if (!text.startsWith("{")) return text
        return try {
            val o = JSONObject(text)
            val server = o.optString("server").trim()
            val port = o.optInt("server_port", 0)
            val password = o.optString("password")
            val method = o.optString("method").trim()
            if (server.isEmpty() || port !in 1..65535 || password.isEmpty() || method.isEmpty()) return text
            val userInfo = android.util.Base64.encodeToString(
                "$method:$password".toByteArray(Charsets.UTF_8),
                android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING,
            )
            val host = if (server.contains(':') && !server.startsWith("[")) "[$server]" else server
            val name = url.substringAfter('#', "").ifEmpty { "Outline" }
            "ss://$userInfo@$host:$port#$name"
        } catch (_: Exception) {
            text
        }
    }

    /** Re-fetches subscriptions older than [SUB_INTERVAL_MS] (all when [force]); own thread. */
    fun refreshIfDue(context: Context, force: Boolean = false, onDone: (() -> Unit)? = null) {
        val app = context.applicationContext
        val now = System.currentTimeMillis()
        val due = subs(app).filter { force || now - it.lastFetch !in 0 until SUB_INTERVAL_MS }
        if (due.isEmpty() || !refreshing.compareAndSet(false, true)) {
            onDone?.invoke()
            return
        }
        Thread({
            try {
                due.forEach { runCatching { refreshSub(app, it) } }
            } finally {
                refreshing.set(false)
                onDone?.invoke()
            }
        }, "my-configs-refresh").apply { isDaemon = true }.start()
    }

    private fun fetch(url: String): String? = try {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", "Mozilla/5.0")
            if (connection.responseCode != HttpURLConnection.HTTP_OK) {
                null
            } else {
                connection.inputStream.bufferedReader().use { reader ->
                    val buf = CharArray(8192)
                    val sb = StringBuilder()
                    while (sb.length < MAX_BODY_CHARS) {
                        val n = reader.read(buf)
                        if (n < 0) break
                        sb.append(buf, 0, n)
                    }
                    sb.toString()
                }
            }
        } finally {
            connection.disconnect()
        }
    } catch (_: Exception) {
        null
    }

    // ------------------------------------------------------------ QR

    /** Text of a QR code in [bitmap], or null. zxing core only, no camera stack. */
    fun decodeQr(bitmap: Bitmap): String? {
        val w = bitmap.width
        val h = bitmap.height
        if (w <= 0 || h <= 0) return null
        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
        val source = com.google.zxing.RGBLuminanceSource(w, h, pixels)
        val hints = mapOf(com.google.zxing.DecodeHintType.TRY_HARDER to true)
        val reader = com.google.zxing.qrcode.QRCodeReader()
        return try {
            reader.decode(com.google.zxing.BinaryBitmap(com.google.zxing.common.HybridBinarizer(source)), hints).text
        } catch (_: Exception) {
            try {
                reader.reset()
                reader.decode(com.google.zxing.BinaryBitmap(com.google.zxing.common.GlobalHistogramBinarizer(source)), hints).text
            } catch (_: Exception) {
                null
            }
        }
    }
}
