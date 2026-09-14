package com.msnguard.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.telephony.TelephonyManager
import android.util.Log
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * Finds "clean" Cloudflare edge IPs for SHARD on the network the phone is on now.
 *
 * A sample of Cloudflare's published IPv4 ranges ([ShardEdges.sampleCloudflareIps])
 * plus the current best and the remote edge list is probed from the phone with a
 * real TLS handshake to a node host (SNI = that host) through each IP. The fastest
 * few that complete are kept per network (Wi-Fi / Ethernet / cellular MCC-MNC) and
 * [ShardEdges.expand] tries them first as the connect address; host and SNI are
 * never changed, so a bad pick only costs a failed race slot.
 *
 * Bounded on purpose: [SAMPLE] handshakes, [PARALLEL] at a time, [TIMEOUT_MS] each,
 * at most once per [MIN_INTERVAL_MS] per network, always off the main thread.
 * Our own package is excluded from the TUN, so this measures the carrier link even
 * while a tunnel is up — which is exactly the link the edge has to survive.
 */
object CleanIpScanner {

    private const val TAG = "MolidoCleanIp"
    private const val PREFS = "clean_ip"
    private const val MIN_INTERVAL_MS = 30 * 60 * 1000L
    private const val SAMPLE = 48
    private const val KEEP = 5
    private const val PARALLEL = 16
    private const val TIMEOUT_MS = 2_500
    private const val SCAN_BUDGET_S = 25L
    private const val FALLBACK_SNI = "speed.cloudflare.com"

    private val scanning = AtomicBoolean(false)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Which network a measurement belongs to. No SSID: that needs location permission. */
    fun networkKey(context: Context): String = try {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val caps = manager?.let { runCatching { it.getNetworkCapabilities(it.activeNetwork) }.getOrNull() }
        when {
            caps == null -> "unknown"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "eth"
            else -> {
                val op = runCatching {
                    (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)
                        ?.simOperator.orEmpty()
                }.getOrDefault("")
                if (op.isNotEmpty()) "cell:$op" else "cell"
            }
        }
    } catch (_: Exception) {
        "unknown"
    }

    /** Best clean IPs for the current network, fastest first. Empty when never scanned. */
    fun best(context: Context): List<String> = try {
        prefs(context).getString("ips_" + networkKey(context), "").orEmpty()
            .split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() && ShardEdges.isCloudflareAddress(it) }
    } catch (_: Exception) {
        emptyList()
    }

    /** Starts a background scan when this network's result is missing or older than 30 min. */
    fun scanIfDue(context: Context) {
        val app = context.applicationContext
        try {
            if (ShardConfigs.hasCustomIp(app)) return
            val key = networkKey(app)
            if (key == "unknown") return
            val elapsed = System.currentTimeMillis() - prefs(app).getLong("at_$key", 0L)
            if (elapsed in 0 until MIN_INTERVAL_MS) return
        } catch (_: Exception) {
            return
        }
        if (!scanning.compareAndSet(false, true)) return
        Thread({
            try {
                scan(app)
            } catch (e: Exception) {
                Log.w(TAG, "scan failed: ${e.message}")
            } finally {
                scanning.set(false)
            }
        }, "clean-ip-scan").apply { isDaemon = true }.start()
    }

    private fun scan(context: Context) {
        val key = networkKey(context)
        val sni = ShardSubscription.nodes(context)
            .firstOrNull { it.host.isNotBlank() && it.port == 443 }
            ?.serverName
            ?.takeIf { it.isNotBlank() }
            ?: FALLBACK_SNI
        val candidates = (best(context) + ShardEdges.edges(context) +
            ShardEdges.sampleCloudflareIps(SAMPLE))
            .filter { ShardEdges.isCloudflareAddress(it) }
            .distinct()
        if (candidates.isEmpty()) return
        val pool = Executors.newFixedThreadPool(PARALLEL)
        val results = ArrayList<Pair<String, Long>>()
        try {
            val tasks = candidates.map { ip -> Callable { ip to probe(ip, sni) } }
            val futures = pool.invokeAll(tasks, SCAN_BUDGET_S, TimeUnit.SECONDS)
            futures.forEach { future ->
                val pair = runCatching { future.get() }.getOrNull() ?: return@forEach
                val ms = pair.second ?: return@forEach
                results.add(pair.first to ms)
            }
        } finally {
            pool.shutdownNow()
        }
        val top = results.sortedBy { it.second }.take(KEEP)
        val editor = prefs(context).edit().putLong("at_$key", System.currentTimeMillis())
        // An empty result keeps the previous list: a scan on a momentarily dead
        // link must not erase what worked an hour ago.
        if (top.isNotEmpty()) editor.putString("ips_$key", top.joinToString(",") { it.first })
        editor.apply()
        val line = "net=$key sni=$sni probed=${candidates.size} ok=${results.size} best=" +
            top.joinToString(",") { "${it.first}(${it.second}ms)" }
        Log.i(TAG, line)
        ConnectionLog.record("Clean IP scan: $line")
    }

    /** Handshake time through [ip] with SNI [sni], or null when it did not complete. */
    private fun probe(ip: String, sni: String): Long? {
        val raw = Socket()
        return try {
            val startedAt = SystemClock.elapsedRealtime()
            raw.tcpNoDelay = true
            raw.connect(InetSocketAddress(ip, 443), TIMEOUT_MS)
            raw.soTimeout = TIMEOUT_MS
            val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
            val ssl = factory.createSocket(raw, sni, 443, true) as SSLSocket
            ssl.use { it.startHandshake() }
            SystemClock.elapsedRealtime() - startedAt
        } catch (_: Exception) {
            null
        } finally {
            try {
                raw.close()
            } catch (_: Exception) {
            }
        }
    }
}
