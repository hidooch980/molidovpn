package com.msnguard.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Opt-in anonymous connection-quality reports (default OFF).
 *
 * Sends only: an anonymous node fingerprint, success/failure, connect latency,
 * network type (wifi/cellular/other), platform and app version. No IP, no name,
 * no browsing data. Fire-and-forget on a daemon thread; never touches the tunnel.
 *
 * Node identity: the service does not keep the original config URI. For SHARD the
 * fingerprint is taken over [ShardNode.key] (protocol|credential|address|port|
 * network|security|path|host — the URI's identifying parts, label excluded, the
 * same way the '#fragment' is stripped from a URI). Transports with no per-node
 * identity send "mode:<name>".
 */
object ConnectionReports {

    const val PREF = "anonymous_reports"
    const val DEFAULT = false

    private const val ENDPOINT = "https://molido-sub.hidooch980.workers.dev/report"
    private const val TIMEOUT_MS = 10_000

    fun enabled(context: Context): Boolean =
        context.getSharedPreferences("settings", Context.MODE_PRIVATE).getBoolean(PREF, DEFAULT)

    /** First 16 hex chars of SHA-256 over the identity with any '#fragment' removed. */
    fun fingerprint(identity: String): String {
        val clean = identity.substringBefore('#').trim()
        val digest = MessageDigest.getInstance("SHA-256").digest(clean.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }.take(16)
    }

    fun report(context: Context, node: String, ok: Boolean, ms: Int?) {
        if (!enabled(context)) return
        val app = context.applicationContext
        Thread({
            try {
                val body = JSONObject().apply {
                    put("v", 1)
                    put("node", node)
                    put("ok", ok)
                    put("ms", ms ?: JSONObject.NULL)
                    put("net", networkType(app))
                    put("app", "android")
                    put("ver", versionName(app))
                }.toString()
                val connection = URL(ENDPOINT).openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = TIMEOUT_MS
                    connection.readTimeout = TIMEOUT_MS
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    connection.responseCode
                } finally {
                    connection.disconnect()
                }
            } catch (_: Exception) {
                // Best effort only.
            }
        }, "connection-report").apply { isDaemon = true }.start()
    }

    /** The underlying (non-VPN) network's type. */
    @Suppress("DEPRECATION")
    private fun networkType(context: Context): String = try {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        var result = "other"
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) { result = "wifi"; break }
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) result = "cellular"
        }
        result
    } catch (_: Exception) {
        "other"
    }

    private fun versionName(context: Context): String = try {
        @Suppress("DEPRECATION")
        context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty()
    } catch (_: Exception) {
        ""
    }
}
