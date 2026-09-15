package com.molido.vpn

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit

/**
 * sing-box sidecar for the protocols the bundled xray cannot speak: hysteria2,
 * tuic and anytls.
 *
 * One exec'd `libsingbox.so` process (SagerNet release, pinned in
 * tools/fetch-binaries.sh) exposes every such node as its own loopback SOCKS
 * inbound. xray then renders the node as a plain `socks` outbound to that port
 * ([xrayOutbound]), so the whole SHARD machinery — race, health memory, rotation,
 * multi-path, the live tunnel and tun2socks — runs these nodes unchanged, and the
 * race's probe is the same real HTTP request through the node.
 *
 * Ports are assigned once per node URI for the process lifetime and never reused,
 * so a config rendered earlier stays valid while the sidecar keeps running.
 */
object SingBox {

    private const val TAG = "SingBox"

    /** V2rayNode protocols carried by the sidecar. */
    val PROTOCOLS = setOf("hysteria2", "tuic", "anytls")

    private const val BASE_PORT = 22000
    private const val MAX_NODES = 200

    private val ports = LinkedHashMap<String, Int>()
    private val nodes = LinkedHashMap<String, V2rayNode>()

    @Volatile
    private var process: Process? = null

    @Volatile
    private var runningSet: Set<String> = emptySet()

    fun isSingBox(node: ShardNode): Boolean = node.v2ray?.let { it.protocol in PROTOCOLS } == true

    private fun binary(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, "libsingbox.so")

    fun available(context: Context): Boolean = binary(context).exists()

    /**
     * Makes [pool]'s sing-box nodes reachable and returns the pool without the ones
     * that are not (binary missing, sidecar failed, cap reached). Blocks up to ~8 s
     * when the sidecar has to (re)start; worker threads only.
     *
     * @param allowRestart false beside a live tunnel: never restart the process (it
     *   may be carrying the session), only keep nodes it already serves.
     */
    @Synchronized
    fun prepare(context: Context, pool: List<ShardNode>, allowRestart: Boolean = true): List<ShardNode> {
        val sing = pool.mapNotNull { it.v2ray }.filter { it.protocol in PROTOCOLS }.distinctBy { it.uri }
        if (sing.isEmpty()) return pool
        if (!available(context)) return pool.filterNot { isSingBox(it) }
        val alive = process?.isAlive == true
        if (allowRestart) {
            sing.forEach { n ->
                if (!ports.containsKey(n.uri) && ports.size < MAX_NODES) ports[n.uri] = BASE_PORT + ports.size
                if (ports.containsKey(n.uri)) nodes[n.uri] = n
            }
            if (nodes.isNotEmpty() && (!alive || !runningSet.containsAll(nodes.keys))) {
                if (!launch(context)) return pool.filterNot { isSingBox(it) }
            }
        } else if (!alive) {
            return pool.filterNot { isSingBox(it) }
        }
        val served = runningSet
        return pool.filter { node -> !isSingBox(node) || node.v2ray?.uri in served }
    }

    /** xray outbound that hands the flow to this node's sidecar inbound. */
    fun xrayOutbound(node: V2rayNode, tag: String): JSONObject {
        // An unmapped node (cannot happen after prepare) points at a closed port and
        // simply fails its probe instead of breaking the whole xray config.
        val port = synchronized(this) { ports[node.uri] } ?: (BASE_PORT + MAX_NODES)
        return JSONObject().apply {
            put("tag", tag)
            put("protocol", "socks")
            put("settings", JSONObject().put("servers", JSONArray().put(
                JSONObject().put("address", "127.0.0.1").put("port", port)
            )))
        }
    }

    fun stop() {
        val proc = process
        Thread({
            runCatching {
                proc?.destroy()
                if (proc != null && !proc.waitFor(2, TimeUnit.SECONDS)) proc.destroyForcibly()
            }
            synchronized(this) {
                if (process === proc) {
                    process = null
                    runningSet = emptySet()
                }
            }
        }, "singbox-stop").start()
    }

    private fun stopLocked() {
        process?.let { proc ->
            runCatching {
                proc.destroy()
                if (!proc.waitFor(2, TimeUnit.SECONDS)) proc.destroyForcibly()
            }
        }
        process = null
        runningSet = emptySet()
    }

    private fun launch(context: Context): Boolean {
        stopLocked()
        val dir = File(context.filesDir, "singbox").apply { mkdirs() }
        val file = File(dir, "sidecar.json")
        file.writeText(config(nodes.values.toList()))
        val proc = try {
            ProcessBuilder(binary(context).absolutePath, "run", "-c", file.absolutePath, "-D", dir.absolutePath)
                .directory(dir)
                .redirectErrorStream(true)
                .apply { environment()["HOME"] = dir.absolutePath }
                .start()
        } catch (e: Exception) {
            ConnectionLog.record("$TAG exec failed: ${e.message}")
            return false
        }
        process = proc
        // Always drained: a full pipe blocks sing-box in write(). Only fatal lines
        // are kept, and those are config errors, not traffic.
        Thread({
            runCatching {
                proc.inputStream.bufferedReader().forEachLine { line ->
                    if (line.contains("FATAL")) ConnectionLog.record("$TAG ${line.take(200)}")
                }
            }
        }, "singbox-log").apply { isDaemon = true }.start()
        val firstPort = ports[nodes.keys.first()] ?: return false
        val deadline = System.currentTimeMillis() + 8_000L
        while (System.currentTimeMillis() < deadline && proc.isAlive) {
            if (portAccepts(firstPort)) {
                runningSet = nodes.keys.toSet()
                ConnectionLog.record("$TAG sidecar up with ${nodes.size} nodes")
                return true
            }
            Thread.sleep(100)
        }
        ConnectionLog.record("$TAG sidecar did not come up")
        stopLocked()
        return false
    }

    private fun portAccepts(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 300); true }
    } catch (_: Exception) {
        false
    }

    private fun config(list: List<V2rayNode>): String {
        val inbounds = JSONArray()
        val outbounds = JSONArray()
        val rules = JSONArray()
        list.forEach { n ->
            val port = ports[n.uri] ?: return@forEach
            val i = port - BASE_PORT
            inbounds.put(JSONObject().apply {
                put("type", "socks")
                put("tag", "in-$i")
                put("listen", "127.0.0.1")
                put("listen_port", port)
            })
            outbounds.put(outbound(n, "out-$i"))
            rules.put(JSONObject().apply {
                put("inbound", JSONArray().put("in-$i"))
                put("action", "route")
                put("outbound", "out-$i")
            })
        }
        outbounds.put(JSONObject().put("type", "direct").put("tag", "direct"))
        return JSONObject().apply {
            put("log", JSONObject().put("level", "warn").put("timestamp", false))
            // Server names are resolved over the carrier (our UID is off the TUN).
            put("dns", JSONObject().put("servers", JSONArray().put(
                JSONObject().put("type", "udp").put("tag", "dns-remote").put("server", "1.1.1.1")
            )))
            put("inbounds", inbounds)
            put("outbounds", outbounds)
            put("route", JSONObject().apply {
                put("rules", rules)
                put("final", "direct")
                put("default_domain_resolver", "dns-remote")
            })
        }.toString()
    }

    private fun tls(n: V2rayNode, defaultAlpn: String?): JSONObject = JSONObject().apply {
        put("enabled", true)
        put("server_name", n.sni.ifEmpty { n.host }.ifEmpty { n.address })
        if (n.insecure) put("insecure", true)
        val alpn = n.alpn.split(',').map { it.trim() }.filter { it.isNotEmpty() }
            .ifEmpty { listOfNotNull(defaultAlpn) }
        if (alpn.isNotEmpty()) put("alpn", JSONArray().apply { alpn.forEach { put(it) } })
    }

    private fun outbound(n: V2rayNode, tag: String): JSONObject = JSONObject().apply {
        put("tag", tag)
        put("server", n.address)
        put("server_port", n.port)
        when (n.protocol) {
            "hysteria2" -> {
                put("type", "hysteria2")
                put("password", n.credential)
                if (n.obfsPassword.isNotEmpty()) {
                    put("obfs", JSONObject().put("type", "salamander").put("password", n.obfsPassword))
                }
                put("tls", tls(n, "h3"))
            }
            "tuic" -> {
                put("type", "tuic")
                put("uuid", n.credential)
                put("password", n.method)
                put("congestion_control", n.congestion.ifEmpty { "bbr" })
                put("udp_relay_mode", n.udpRelayMode.ifEmpty { "native" })
                put("tls", tls(n, "h3"))
            }
            else -> {
                put("type", "anytls")
                put("password", n.credential)
                put("tls", tls(n, null))
            }
        }
    }
}
