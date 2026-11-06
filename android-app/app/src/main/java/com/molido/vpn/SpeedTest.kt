package com.molido.vpn

import android.content.Context
import android.os.SystemClock
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL

/**
 * Settings speed measurement. Native TUN modes without a local SOCKS listener are
 * measured directly and MUST be displayed as direct-network results, not VPN speed.
 */
object SpeedTest {
    private const val DOWN_BYTES = 10_000_000
    private const val UP_BYTES = 5_000_000
    private const val BASE = "https://speed.cloudflare.com"
    private const val TRANSFER_LIMIT_MS = 20_000L
    private const val PROBE_LIMIT_MS = 4_000L
    private const val PROBE_COUNT = 5

    data class Result(
        val pingMs: Long?,
        val downMbps: Double?,
        val upMbps: Double?,
        val viaTunnel: Boolean,
        val error: String? = null,
        val jitterMs: Double? = null,
        val packetLossPct: Double = 100.0,
    )

    private fun accepts(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 400); true }
    } catch (_: Exception) {
        false
    }

    /** The tunnel's SOCKS port, or null when traffic can only go direct. */
    private fun socksPort(context: Context): Int? {
        if (!TunnelStatus.isActive()) return null
        if (ShardManager.isRunning) return ShardManager.listenPort
        if (TunnelStatus.isProxyMode) return CoreConfig.proxyListenPort(context)
        if (TunnelStatus.isNativeTunMode) return null
        return listOf(CoreConfig.SOCKS_PORT, TorManager.FRONT_SOCKS_PORT).firstOrNull { accepts(it) }
    }

    /** Blocking; call off the main thread. */
    fun run(context: Context): Result {
        val port = socksPort(context)
        val proxy = port?.let { Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", it)) } ?: Proxy.NO_PROXY
        return try {
            val probes = (0 until PROBE_COUNT).mapNotNull { timed(proxy, "$BASE/__down?bytes=0") }
            val sorted = probes.sorted()
            val ping = sorted.getOrNull(sorted.size / 2)
            val jitter = if (probes.size < 2) null else
                probes.zipWithNext().map { (a, b) -> kotlin.math.abs(b - a).toDouble() }.average()
            val down = download(proxy)
            val up = upload(proxy)
            Result(
                ping, down, up, port != null,
                jitterMs = jitter,
                packetLossPct = (PROBE_COUNT - probes.size) * 100.0 / PROBE_COUNT,
            )
        } catch (e: Exception) {
            Result(null, null, null, port != null, e.message ?: e.javaClass.simpleName,
                packetLossPct = 100.0)
        }
    }

    private fun open(proxy: Proxy, url: String): HttpURLConnection =
        (URL(url).openConnection(proxy) as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = TRANSFER_LIMIT_MS.toInt()
            useCaches = false
        }

    private fun timed(proxy: Proxy, url: String): Long? = try {
        val t0 = SystemClock.elapsedRealtime()
        val c = open(proxy, url)
        try {
            if (c.responseCode != HttpURLConnection.HTTP_OK) return null
            c.inputStream.use { input ->
                val buf = ByteArray(1024)
                while (input.read(buf) >= 0) {
                    if (SystemClock.elapsedRealtime() - t0 > PROBE_LIMIT_MS) return null
                }
            }
            (SystemClock.elapsedRealtime() - t0).takeIf { it <= PROBE_LIMIT_MS }
        } finally {
            c.disconnect()
        }
    } catch (_: Exception) {
        null
    }

    private fun mbps(bytes: Long, ms: Long): Double =
        if (ms <= 0) 0.0 else bytes * 8.0 / 1_000_000.0 / (ms / 1000.0)

    private fun download(proxy: Proxy): Double? {
        val c = open(proxy, "$BASE/__down?bytes=$DOWN_BYTES")
        try {
            if (c.responseCode != HttpURLConnection.HTTP_OK) return null
            if (c.contentLengthLong >= 0 && c.contentLengthLong != DOWN_BYTES.toLong()) return null
            val t0 = SystemClock.elapsedRealtime()
            var total = 0L
            c.inputStream.use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val elapsed = SystemClock.elapsedRealtime() - t0
                    if (elapsed >= TRANSFER_LIMIT_MS) return null
                    c.readTimeout = (TRANSFER_LIMIT_MS - elapsed).coerceAtLeast(1).toInt()
                    val n = input.read(buf)
                    if (n < 0) break
                    total += n
                    if (total > DOWN_BYTES) return null
                }
            }
            val ms = SystemClock.elapsedRealtime() - t0
            return if (total == DOWN_BYTES.toLong() && ms <= TRANSFER_LIMIT_MS) mbps(total, ms) else null
        } finally {
            c.disconnect()
        }
    }

    private fun upload(proxy: Proxy): Double? {
        val c = open(proxy, "$BASE/__up")
        try {
            c.requestMethod = "POST"
            c.doOutput = true
            c.setFixedLengthStreamingMode(UP_BYTES)
            c.setRequestProperty("Content-Type", "application/octet-stream")
            val chunk = ByteArray(64 * 1024)
            val t0 = SystemClock.elapsedRealtime()
            c.outputStream.use { out ->
                var left = UP_BYTES
                while (left > 0) {
                    if (SystemClock.elapsedRealtime() - t0 >= TRANSFER_LIMIT_MS) return null
                    val n = minOf(left, chunk.size)
                    out.write(chunk, 0, n)
                    left -= n
                }
            }
            val status = c.responseCode
            if (status !in 200..299) return null
            val response = if (status >= 400) c.errorStream else c.inputStream
            response?.use { input ->
                val buf = ByteArray(1024)
                while (input.read(buf) >= 0) {
                    if (SystemClock.elapsedRealtime() - t0 >= TRANSFER_LIMIT_MS) return null
                }
            }
            val ms = SystemClock.elapsedRealtime() - t0
            return if (ms <= TRANSFER_LIMIT_MS) mbps(UP_BYTES.toLong(), ms) else null
        } finally {
            c.disconnect()
        }
    }
}
