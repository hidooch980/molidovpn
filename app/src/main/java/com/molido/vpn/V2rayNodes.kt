package com.molido.vpn

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.util.Locale
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One node of the "V2Ray servers" mode, parsed from a share URI.
 *
 * Carried inside [ShardNode.v2ray] so the whole SHARD machinery — race, health
 * memory, rotation, edge expansion, the live launch — runs these nodes unchanged.
 * The server address/port used at render time are the [ShardNode]'s, not these,
 * so an edge-expanded copy dials the edge.
 *
 * Only what the bundled xray can run is ever constructed: one outbound xray
 * rejects kills the whole probe process and with it the race, so [V2rayNodes.parse]
 * is strict and drops anything incomplete or unknown.
 */
data class V2rayNode(
    /** The URI without its `#fragment`; identity for dedupe and reports. */
    val uri: String,
    /** `vless`, `vmess`, `trojan` or `shadowsocks`. */
    val protocol: String,
    val address: String,
    val port: Int,
    /** UUID (vless/vmess) or password (trojan/ss). */
    val credential: String,
    /** vmess `scy` / ss method. */
    val method: String = "",
    val flow: String = "",
    /** tcp, ws, grpc, httpupgrade. */
    val network: String = "tcp",
    /** none, tls, reality. */
    val security: String = "none",
    val sni: String = "",
    val fingerprint: String = "",
    val alpn: String = "",
    val publicKey: String = "",
    val shortId: String = "",
    val spiderX: String = "",
    val host: String = "",
    val path: String = "",
    val serviceName: String = "",
    val grpcMulti: Boolean = false,
    /** XHTTP (SplitHTTP) mode: auto, packet-up, stream-up or stream-one. */
    val xhttpMode: String = "auto",
    /** XHTTP `extra` JSON object text from the share link, or empty. */
    val xhttpExtra: String = "",
    /** hysteria2 salamander obfs password, or empty. */
    val obfsPassword: String = "",
    /** TLS verification off, as the share link asked (hysteria2/tuic/anytls only). */
    val insecure: Boolean = false,
    /** tuic congestion control: cubic, new_reno or bbr. */
    val congestion: String = "",
    /** tuic UDP relay mode: native or quic. */
    val udpRelayMode: String = "",
    /** The share link's `#name` (vmess: `ps`); country detection and My configs only. */
    val name: String = "",
)

object V2rayNodes {

    private const val TAG = "V2rayNodes"

    /** xhttp needs xray v24.9+; the bundled libxray.so is v26.3.27. */
    private val NETWORKS = setOf("tcp", "ws", "grpc", "httpupgrade", "xhttp")

    private val XHTTP_MODES = setOf("auto", "packet-up", "stream-up", "stream-one")

    /** `splithttp` is the old name of xhttp; `mode` is only valid in the set above. */
    private fun normalizeNetwork(raw: String): String =
        raw.lowercase(Locale.US).let { if (it == "splithttp") "xhttp" else it }

    private fun xhttpMode(raw: String): String =
        raw.lowercase(Locale.US).takeIf { it in XHTTP_MODES } ?: "auto"

    /** The `extra` value only when it is a JSON object (anything else is dropped). */
    private fun xhttpExtra(raw: String): String =
        raw.trim().takeIf { it.startsWith("{") }?.let { runCatching { JSONObject(it).toString() }.getOrNull() }.orEmpty()

    /** uTLS names xray accepts; anything else would fail the whole config. */
    private val FINGERPRINTS = setOf(
        "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq",
        "random", "randomized",
    )

    /** AEAD / 2022 ciphers only — stream ciphers are gone from current xray. */
    private val SS_METHODS = setOf(
        "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305",
        "xchacha20-poly1305", "xchacha20-ietf-poly1305", "none", "plain",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
    )

    private val VMESS_SECURITY = setOf("auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero")

    private val FLOWS = setOf("", "xtls-rprx-vision", "xtls-rprx-vision-udp443")

    // ------------------------------------------------------------ parsing

    /** Plain or base64 body → share-URI lines. */
    fun decodeBody(body: String): List<String> {
        val trimmed = body.trim()
        if (trimmed.isEmpty()) return emptyList()
        val text = if (trimmed.contains("://")) trimmed else base64Text(trimmed) ?: return emptyList()
        return text.lineSequence().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }.toList()
    }

    /** Parse lines into nodes, deduped by URI without `#fragment`, in order. */
    fun parse(lines: List<String>): List<V2rayNode> {
        val seen = HashSet<String>()
        val out = ArrayList<V2rayNode>()
        lines.forEach { line ->
            val node = parseOne(line) ?: return@forEach
            if (seen.add(node.uri)) out.add(node)
        }
        return out
    }

    fun parseOne(raw: String): V2rayNode? = try {
        val line = raw.trim()
        when (line.substringBefore("://", "").lowercase(Locale.US)) {
            "vless" -> parseVlessOrTrojan(line, "vless")
            "trojan" -> parseVlessOrTrojan(line, "trojan")
            "vmess" -> parseVmess(line)
            "ss" -> parseShadowsocks(line)
            // Carried by the sing-box sidecar ([SingBox]).
            "hysteria2", "hy2" -> parseHysteria2(line)
            "tuic" -> parseTuic(line)
            "anytls" -> parseAnyTls(line)
            else -> null
        }?.let { node -> node.copy(name = nameOf(line, node)) }
    } catch (_: Exception) {
        null
    }

    private fun nameOf(line: String, node: V2rayNode): String {
        val fragment = line.substringAfter('#', "")
        if (fragment.isNotEmpty()) return decode(fragment).trim()
        if (node.protocol != "vmess") return ""
        val payload = line.substringAfter("://").substringBefore('#').trim()
        return runCatching { JSONObject(base64Text(payload) ?: "{}").optString("ps").trim() }.getOrDefault("")
    }

    /** Canonical share line: the identity URI plus its `#name` when it has one. */
    fun shareLine(node: V2rayNode): String =
        if (node.name.isEmpty() || node.protocol == "vmess") {
            node.uri
        } else {
            node.uri + "#" + java.net.URLEncoder.encode(node.name, "UTF-8").replace("+", "%20")
        }

    private fun parseVlessOrTrojan(line: String, scheme: String): V2rayNode? {
        val uri = line.substringBefore('#').trim()
        val rest = uri.substringAfter("://")
        val credential = decode(rest.substringBefore('@', ""))
        if (credential.isEmpty()) return null
        val hostPortQuery = rest.substringAfter('@')
        val (address, port) = hostPort(hostPortQuery.substringBefore('?').substringBefore('/')) ?: return null
        val q = parseQuery(hostPortQuery.substringAfter('?', ""))
        val network = normalizeNetwork(q["type"].orEmpty()).ifEmpty { "tcp" }
        if (network !in NETWORKS) return null
        val headerType = q["headertype"].orEmpty().lowercase(Locale.US)
        if (network == "tcp" && headerType.isNotEmpty() && headerType != "none") return null
        val defaultSecurity = if (scheme == "trojan") "tls" else "none"
        val security = q["security"].orEmpty().lowercase(Locale.US).ifEmpty { defaultSecurity }
        if (security !in setOf("none", "tls", "reality")) return null
        if (scheme == "vless") {
            val encryption = q["encryption"].orEmpty().lowercase(Locale.US)
            if (encryption.isNotEmpty() && encryption != "none") return null
        }
        val flow = q["flow"].orEmpty().lowercase(Locale.US)
        if (flow !in FLOWS) return null
        if (flow.isNotEmpty() && (scheme != "vless" || network != "tcp" || security == "none")) return null
        val host = q["host"].orEmpty()
        val node = V2rayNode(
            uri = uri,
            protocol = scheme,
            address = address,
            port = port,
            credential = credential,
            flow = flow,
            network = network,
            security = security,
            sni = q["sni"].orEmpty().ifEmpty { q["peer"].orEmpty() },
            fingerprint = q["fp"].orEmpty().lowercase(Locale.US),
            alpn = q["alpn"].orEmpty(),
            publicKey = q["pbk"].orEmpty(),
            shortId = q["sid"].orEmpty(),
            spiderX = q["spx"].orEmpty(),
            host = host,
            path = q["path"].orEmpty(),
            serviceName = q["servicename"].orEmpty().ifEmpty { if (network == "grpc") q["path"].orEmpty() else "" },
            grpcMulti = q["mode"].orEmpty().lowercase(Locale.US) == "multi",
            xhttpMode = if (network == "xhttp") xhttpMode(q["mode"].orEmpty()) else "auto",
            xhttpExtra = if (network == "xhttp") xhttpExtra(q["extra"].orEmpty()) else "",
        )
        return node.takeIf { complete(it) }
    }

    private fun parseVmess(line: String): V2rayNode? {
        val payload = line.substringAfter("://").substringBefore('#').trim()
        val json = JSONObject(base64Text(payload) ?: return null)
        val address = json.optString("add").trim().removePrefix("[").removeSuffix("]")
        val port = json.opt("port")?.toString()?.trim()?.toIntOrNull() ?: return null
        val id = json.optString("id").trim()
        if (address.isEmpty() || port !in 1..65535 || id.isEmpty()) return null
        // Legacy MD5 auth (alterId > 0) was removed from xray; such a node would
        // fail config parsing for the whole probe process.
        val aid = json.opt("aid")?.toString()?.trim()?.toIntOrNull() ?: 0
        if (aid != 0) return null
        val network = normalizeNetwork(json.optString("net")).ifEmpty { "tcp" }
        if (network !in NETWORKS) return null
        val headerType = json.optString("type").lowercase(Locale.US)
        if (network == "tcp" && headerType.isNotEmpty() && headerType != "none") return null
        val tls = json.optString("tls").lowercase(Locale.US)
        val security = when (tls) {
            "", "none" -> "none"
            "tls" -> "tls"
            else -> return null
        }
        val scy = json.optString("scy").lowercase(Locale.US).ifEmpty { "auto" }
        if (scy !in VMESS_SECURITY) return null
        val path = json.optString("path")
        val node = V2rayNode(
            // Canonical identity: the payload decoded, so two encodings of one
            // node still dedupe. Kept as the original URI text otherwise.
            uri = "vmess://$payload",
            protocol = "vmess",
            address = address,
            port = port,
            credential = id,
            method = scy,
            network = network,
            security = security,
            sni = json.optString("sni"),
            fingerprint = json.optString("fp").lowercase(Locale.US),
            alpn = json.optString("alpn"),
            host = json.optString("host"),
            path = path,
            serviceName = if (network == "grpc") path else "",
            xhttpMode = if (network == "xhttp") xhttpMode(json.optString("mode")) else "auto",
        )
        return node.takeIf { complete(it) }
    }

    private fun parseShadowsocks(line: String): V2rayNode? {
        val uri = line.substringBefore('#').trim()
        var rest = uri.substringAfter("://")
        val query = rest.substringAfter('?', "")
        if (parseQuery(query).containsKey("plugin")) return null
        rest = rest.substringBefore('?').trimEnd('/')
        val userInfo: String
        val hostPart: String
        if (rest.contains('@')) {
            userInfo = rest.substringBeforeLast('@')
            hostPart = rest.substringAfterLast('@')
        } else {
            // Legacy form: base64("method:pass@host:port").
            val decoded = base64Text(rest) ?: return null
            if (!decoded.contains('@')) return null
            userInfo = decoded.substringBeforeLast('@')
            hostPart = decoded.substringAfterLast('@')
        }
        val (address, port) = hostPort(hostPart.substringBefore('/')) ?: return null
        val plain = decode(userInfo)
        val methodPass = if (plain.contains(':')) plain else base64Text(userInfo) ?: return null
        val method = methodPass.substringBefore(':', "").lowercase(Locale.US).trim()
        val password = methodPass.substringAfter(':', "")
        if (method !in SS_METHODS || password.isEmpty()) return null
        return V2rayNode(
            uri = uri,
            protocol = "shadowsocks",
            address = address,
            port = port,
            credential = password,
            method = method,
        )
    }

    private fun flag(value: String?): Boolean =
        value == "1" || value.equals("true", ignoreCase = true)

    /** hysteria2://auth@host:port[,hop-ports]/?sni=&insecure=&obfs=salamander&obfs-password= */
    private fun parseHysteria2(line: String): V2rayNode? {
        val rest = line.substringBefore('#').trim().substringAfter("://")
        val auth = decode(rest.substringBefore('@', ""))
        if (auth.isEmpty()) return null
        val hostPortQuery = rest.substringAfter('@')
        // Port hopping ("443,20000-30000") is not supported: the first port only.
        val hostPortText = hostPortQuery.substringBefore('?').substringBefore('/').substringBefore(',')
        val (address, port) = hostPort(hostPortText) ?: return null
        val q = parseQuery(hostPortQuery.substringAfter('?', ""))
        val obfs = q["obfs"].orEmpty().lowercase(Locale.US)
        if (obfs.isNotEmpty() && obfs != "none" && obfs != "salamander") return null
        val obfsPassword = if (obfs == "salamander") q["obfs-password"].orEmpty() else ""
        if (obfs == "salamander" && obfsPassword.isEmpty()) return null
        return V2rayNode(
            uri = "hysteria2://$rest",
            protocol = "hysteria2",
            address = address,
            port = port,
            credential = auth,
            security = "tls",
            sni = q["sni"].orEmpty().ifEmpty { q["peer"].orEmpty() },
            alpn = q["alpn"].orEmpty(),
            obfsPassword = obfsPassword,
            insecure = flag(q["insecure"]) || flag(q["allowinsecure"]) || flag(q["allow_insecure"]),
        ).takeIf { complete(it) }
    }

    /** tuic://uuid:password@host:port?congestion_control=&udp_relay_mode=&alpn=&sni=&allow_insecure= */
    private fun parseTuic(line: String): V2rayNode? {
        val uri = line.substringBefore('#').trim()
        val rest = uri.substringAfter("://")
        val userInfo = decode(rest.substringBefore('@', ""))
        val uuid = userInfo.substringBefore(':')
        val password = userInfo.substringAfter(':', "")
        if (uuid.isEmpty() || password.isEmpty()) return null
        val hostPortQuery = rest.substringAfter('@')
        val (address, port) = hostPort(hostPortQuery.substringBefore('?').substringBefore('/')) ?: return null
        val q = parseQuery(hostPortQuery.substringAfter('?', ""))
        return V2rayNode(
            uri = uri,
            protocol = "tuic",
            address = address,
            port = port,
            credential = uuid,
            method = password,
            security = "tls",
            sni = q["sni"].orEmpty(),
            alpn = q["alpn"].orEmpty(),
            insecure = flag(q["allow_insecure"]) || flag(q["insecure"]) || flag(q["allowinsecure"]),
            congestion = q["congestion_control"].orEmpty().lowercase(Locale.US)
                .takeIf { it in setOf("cubic", "new_reno", "bbr") } ?: "bbr",
            udpRelayMode = q["udp_relay_mode"].orEmpty().lowercase(Locale.US)
                .takeIf { it in setOf("native", "quic") } ?: "native",
        ).takeIf { complete(it) }
    }

    /** anytls://password@host:port?sni=&insecure= */
    private fun parseAnyTls(line: String): V2rayNode? {
        val uri = line.substringBefore('#').trim()
        val rest = uri.substringAfter("://")
        val password = decode(rest.substringBefore('@', ""))
        if (password.isEmpty()) return null
        val hostPortQuery = rest.substringAfter('@')
        val (address, port) = hostPort(hostPortQuery.substringBefore('?').substringBefore('/')) ?: return null
        val q = parseQuery(hostPortQuery.substringAfter('?', ""))
        return V2rayNode(
            uri = uri,
            protocol = "anytls",
            address = address,
            port = port,
            credential = password,
            security = "tls",
            sni = q["sni"].orEmpty(),
            alpn = q["alpn"].orEmpty(),
            insecure = flag(q["insecure"]) || flag(q["allowinsecure"]) || flag(q["allow_insecure"]),
        ).takeIf { complete(it) }
    }

    /** Fields that must be present for the rendered outbound to be valid. */
    private fun complete(node: V2rayNode): Boolean {
        if (node.address.isBlank() || node.port !in 1..65535 || node.credential.isBlank()) return false
        if (node.security == "reality") {
            if (node.publicKey.isBlank()) return false
            if (node.sni.isBlank() && node.host.isBlank()) return false
            if (node.network != "tcp" && node.network != "grpc" && node.network != "xhttp") return false
        }
        if (node.network == "grpc" && node.serviceName.isBlank()) return false
        return true
    }

    private fun hostPort(value: String): Pair<String, Int>? {
        val v = value.trim()
        val address: String
        val portText: String
        if (v.startsWith("[")) {
            address = v.substringAfter('[').substringBefore(']')
            portText = v.substringAfter("]:", "")
        } else {
            address = v.substringBeforeLast(':', "")
            portText = v.substringAfterLast(':', "")
        }
        val port = portText.toIntOrNull() ?: return null
        if (address.isEmpty() || port !in 1..65535) return null
        return address to port
    }

    private fun parseQuery(query: String): Map<String, String> {
        if (query.isEmpty()) return emptyMap()
        val out = HashMap<String, String>()
        query.split('&').forEach { pair ->
            val name = pair.substringBefore('=', "")
            if (name.isNotEmpty()) out[name.lowercase(Locale.US)] = decode(pair.substringAfter('=', ""))
        }
        return out
    }

    private fun decode(value: String): String = try {
        URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
    } catch (_: Exception) {
        value
    }

    /** Standard or URL-safe base64, padding optional; null when not base64 text. */
    private fun base64Text(value: String): String? = try {
        var s = value.filterNot { it.isWhitespace() }.replace('-', '+').replace('_', '/')
        while (s.length % 4 != 0) s += "="
        String(android.util.Base64.decode(s, android.util.Base64.DEFAULT), Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }

    // ------------------------------------------------------------ bridge to SHARD

    /** Wrap for the SHARD machinery (race, health, edges, live launch). */
    fun toShardNode(node: V2rayNode): ShardNode = ShardNode(
        protocol = node.protocol,
        credential = node.credential,
        address = node.address,
        port = node.port,
        network = node.network,
        security = node.security,
        path = if (node.network == "grpc") node.serviceName else node.path,
        host = node.host,
        serverName = node.sni.ifEmpty { node.host },
        fingerprint = node.fingerprint,
        cipherSuites = "",
        finalMask = "",
        alpn = node.alpn,
        // Read by ShardNode.countryCode (flag / ISO prefix); never shown as-is.
        label = node.name,
        v2ray = node,
    )

    /**
     * Whether [ShardEdges] may swap the address for a CDN edge: only Cloudflare-
     * fronted ws+tls nodes, the same shape SHARD's nodes have.
     */
    fun edgeExpandable(node: V2rayNode): Boolean =
        node.network == "ws" && node.security == "tls" && node.host.isNotBlank()

    // ------------------------------------------------------------ rendering

    /**
     * xray outbound for [node], dialling [address]:[port] (the ShardNode's, which
     * may be an edge variant). No mux: these nodes are not fragmented, and mux is
     * incompatible with vision flow.
     */
    fun outbound(node: V2rayNode, address: String, port: Int, tag: String): JSONObject {
        // hysteria2 / tuic / anytls: a socks hop into the sing-box sidecar.
        if (node.protocol in SingBox.PROTOCOLS) return SingBox.xrayOutbound(node, tag)
        val settings = JSONObject()
        when (node.protocol) {
            "vless" -> settings.put("vnext", JSONArray().put(JSONObject().apply {
                put("address", address)
                put("port", port)
                put("users", JSONArray().put(JSONObject().apply {
                    put("id", node.credential)
                    put("encryption", "none")
                    if (node.flow.isNotEmpty()) put("flow", node.flow)
                }))
            }))
            "vmess" -> settings.put("vnext", JSONArray().put(JSONObject().apply {
                put("address", address)
                put("port", port)
                put("users", JSONArray().put(JSONObject().apply {
                    put("id", node.credential)
                    put("alterId", 0)
                    put("security", node.method.ifEmpty { "auto" })
                }))
            }))
            "trojan" -> settings.put("servers", JSONArray().put(JSONObject().apply {
                put("address", address)
                put("port", port)
                put("password", node.credential)
            }))
            "shadowsocks" -> settings.put("servers", JSONArray().put(JSONObject().apply {
                put("address", address)
                put("port", port)
                put("method", node.method)
                put("password", node.credential)
            }))
        }

        val stream = JSONObject().apply {
            put("network", node.network)
            put("security", node.security)
            val serverName = node.sni.ifEmpty { node.host }.ifEmpty { node.address }
            val fp = node.fingerprint.takeIf { it in FINGERPRINTS }
            when (node.security) {
                "tls" -> put("tlsSettings", JSONObject().apply {
                    put("serverName", serverName)
                    if (fp != null) put("fingerprint", fp)
                    if (node.alpn.isNotBlank()) {
                        put("alpn", JSONArray().apply {
                            node.alpn.split(',').map { it.trim() }.filter { it.isNotEmpty() }.forEach { put(it) }
                        })
                    }
                    put("allowInsecure", false)
                })
                "reality" -> put("realitySettings", JSONObject().apply {
                    put("serverName", serverName)
                    put("fingerprint", fp ?: "chrome")
                    put("publicKey", node.publicKey)
                    put("shortId", node.shortId)
                    if (node.spiderX.isNotEmpty()) put("spiderX", node.spiderX)
                })
            }
            when (node.network) {
                "ws" -> put("wsSettings", JSONObject().apply {
                    put("path", node.path.ifEmpty { "/" })
                    if (node.host.isNotEmpty()) put("host", node.host)
                })
                "httpupgrade" -> put("httpupgradeSettings", JSONObject().apply {
                    put("path", node.path.ifEmpty { "/" })
                    if (node.host.isNotEmpty()) put("host", node.host)
                })
                "grpc" -> put("grpcSettings", JSONObject().apply {
                    put("serviceName", node.serviceName)
                    put("multiMode", node.grpcMulti)
                })
                "xhttp" -> put("xhttpSettings", JSONObject().apply {
                    put("path", node.path.ifEmpty { "/" })
                    if (node.host.isNotEmpty()) put("host", node.host)
                    put("mode", node.xhttpMode.ifEmpty { "auto" })
                    if (node.xhttpExtra.isNotEmpty()) {
                        runCatching { JSONObject(node.xhttpExtra) }.getOrNull()?.let { put("extra", it) }
                    }
                })
            }
        }

        return JSONObject().apply {
            put("tag", tag)
            put("protocol", node.protocol)
            put("settings", settings)
            if (node.protocol != "shadowsocks" || node.network != "tcp") put("streamSettings", stream)
        }
    }
}

/**
 * The V2Ray servers pool: five mirror subscriptions merged, iOS feed as fallback,
 * cached in filesDir, refreshed at most hourly.
 */
object V2raySubscription {

    private const val TAG = "V2raySubscription"
    private const val BASE = "https://molido-sub.hidooch980.workers.dev"
    private val SOURCES = (1..5).map { "$BASE/sub/$it" }
    private const val FALLBACK = "$BASE/ios"

    private const val CACHE_FILE = "v2ray-configs.txt"
    private const val LAST_CHECK_PREF = "v2ray_last_check"
    private const val LAST_COUNT_PREF = "v2ray_last_count"
    private const val MIN_INTERVAL_MS = 60 * 60 * 1000L
    private const val CONNECT_TIMEOUT_MS = 10_000
    private const val READ_TIMEOUT_MS = 15_000

    private val refreshing = AtomicBoolean(false)

    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private fun cacheFile(context: Context) = File(context.filesDir, CACHE_FILE)

    fun cachedCount(context: Context): Int = prefs(context).getInt(LAST_COUNT_PREF, 0)

    /** Nodes from the cache; with no usable cache, fetches synchronously (worker thread only). */
    fun nodes(context: Context): List<V2rayNode> {
        val cached = readCache(context)
        if (cached.isNotEmpty()) return cached
        if (refreshing.compareAndSet(false, true)) {
            try {
                refreshBlocking(context)
            } catch (e: Exception) {
                ConnectionLog.record("$TAG first fetch failed: ${e.message}")
            } finally {
                refreshing.set(false)
            }
        }
        return readCache(context)
    }

    /** The pool wrapped for [ShardManager]. */
    fun shardNodes(context: Context): List<ShardNode> = nodes(context).map { V2rayNodes.toShardNode(it) }

    private fun readCache(context: Context): List<V2rayNode> = try {
        val text = cacheFile(context).takeIf { it.exists() }?.readText().orEmpty()
        if (text.isBlank()) emptyList() else V2rayNodes.parse(text.lines())
    } catch (_: Exception) {
        emptyList()
    }

    fun refreshIfDue(context: Context, force: Boolean = false, onDone: ((Int) -> Unit)? = null) {
        val app = context.applicationContext
        val elapsed = System.currentTimeMillis() - prefs(app).getLong(LAST_CHECK_PREF, 0L)
        if (!force && elapsed in 0 until MIN_INTERVAL_MS && cacheFile(app).exists()) {
            onDone?.invoke(cachedCount(app))
            return
        }
        if (!refreshing.compareAndSet(false, true)) {
            onDone?.invoke(cachedCount(app))
            return
        }
        Thread({
            val count = try {
                refreshBlocking(app)
            } catch (e: Exception) {
                ConnectionLog.record("$TAG refresh failed: ${e.message}")
                cachedCount(app)
            } finally {
                refreshing.set(false)
            }
            onDone?.invoke(count)
        }, "v2ray-refresh").apply { isDaemon = true }.start()
    }

    /** Fetch all sources in parallel, merge, dedupe; fallback when they yield nothing. */
    private fun refreshBlocking(context: Context): Int {
        val executor = Executors.newFixedThreadPool(SOURCES.size)
        val lines = ArrayList<String>()
        try {
            val futures = executor.invokeAll(
                SOURCES.map { url -> Callable<List<String>> { fetchLines(url) } },
                READ_TIMEOUT_MS.toLong() + CONNECT_TIMEOUT_MS,
                TimeUnit.MILLISECONDS,
            )
            futures.forEach { f ->
                try {
                    if (!f.isCancelled) lines.addAll(f.get())
                } catch (_: Exception) {
                }
            }
        } finally {
            executor.shutdownNow()
        }
        var parsed = V2rayNodes.parse(lines)
        if (parsed.isEmpty()) {
            parsed = V2rayNodes.parse(fetchLines(FALLBACK))
        }
        if (parsed.isEmpty()) {
            ConnectionLog.record("$TAG no usable nodes — keeping previous cache")
            return cachedCount(context)
        }
        // Stored as one canonical URI per line; vmess keeps its payload form.
        // Names kept (#fragment) so the country filter can read them from the cache.
        cacheFile(context).writeText(parsed.joinToString("\n") { V2rayNodes.shareLine(it) })
        prefs(context).edit()
            .putLong(LAST_CHECK_PREF, System.currentTimeMillis())
            .putInt(LAST_COUNT_PREF, parsed.size)
            .apply()
        ConnectionLog.record("$TAG updated — ${parsed.size} nodes")
        return parsed.size
    }

    private fun fetchLines(url: String): List<String> = try {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", "Mozilla/5.0")
            if (connection.responseCode != HttpURLConnection.HTTP_OK) {
                emptyList()
            } else {
                V2rayNodes.decodeBody(connection.inputStream.bufferedReader().use { it.readText() })
            }
        } finally {
            connection.disconnect()
        }
    } catch (_: Exception) {
        emptyList()
    }
}
