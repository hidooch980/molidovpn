package com.molido.vpn

import android.content.Context
import android.os.SystemClock
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL

/**
 * Settings > Speed test: 10 MB download and 5 MB upload against
 * speed.cloudflare.com, plus a ping (median of 3 tiny requests).
 *
 * Our own package is excluded from the TUN, so a plain request would measure the
 * carrier link. The test therefore goes through the tunnel's local SOCKS port
 * whenever one exists (SHARD/V2Ray, proxy mode, Psiphon, Tor). WireGuard/MASQUE
 * in VPN mode have no local listener; there the result is marked as direct.
 */
object SpeedTest {

    private const val DOWN_BYTES = 10_000_000
    private const val UP_BYTES = 5_000_000
    private const val BASE = "https://speed.cloudflare.com"

    data class Result(
        val pingMs: Long?,
        val downMbps: Double?,
        val upMbps: Double?,
        val viaTunnel: Boolean,
        val error: String? = null,
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
            val pings = (0 until 3).mapNotNull { timed(proxy, "$BASE/__down?bytes=0") }
            val ping = pings.sorted().getOrNull(pings.size / 2)
            val down = download(proxy)
            val up = upload(proxy)
            Result(ping, down, up, port != null)
        } catch (e: Exception) {
            Result(null, null, null, port != null, e.message ?: e.javaClass.simpleName)
        }
    }

    private fun open(proxy: Proxy, url: String): HttpURLConnection =
        (URL(url).openConnection(proxy) as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 20_000
            useCaches = false
        }

    private fun timed(proxy: Proxy, url: String): Long? = try {
        val t0 = SystemClock.elapsedRealtime()
        val c = open(proxy, url)
        try {
            c.inputStream.use { it.readBytes() }
            SystemClock.elapsedRealtime() - t0
        } finally {
            c.disconnect()
        }
    } catch (_: Exception) {
        null
    }

    private fun mbps(bytes: Long, ms: Long): Double = if (ms <= 0) 0.0 else bytes * 8.0 / 1_000_000.0 / (ms / 1000.0)

    private fun download(proxy: Proxy): Double? {
        val c = open(proxy, "$BASE/__down?bytes=$DOWN_BYTES")
        try {
            val t0 = SystemClock.elapsedRealtime()
            var total = 0L
            c.inputStream.use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    total += n
                }
            }
            val ms = SystemClock.elapsedRealtime() - t0
            return if (total > 0) mbps(total, ms) else null
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
                    val n = minOf(left, chunk.size)
                    out.write(chunk, 0, n)
                    left -= n
                }
            }
            c.responseCode
            val ms = SystemClock.elapsedRealtime() - t0
            return mbps(UP_BYTES.toLong(), ms)
        } finally {
            c.disconnect()
        }
    }
}
