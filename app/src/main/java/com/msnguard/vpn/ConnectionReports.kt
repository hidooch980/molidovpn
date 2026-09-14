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
    /** Set once the first-launch consent sheet has been shown. */
    const val ASKED_PREF = "anonymous_reports_asked"

    private const val ENDPOINT = "https://molido-sub.hidooch980.workers.dev/report"
    private const val SCORES_ENDPOINT = "https://molido-sub.hidooch980.workers.dev/scores?op="
    private const val SCORES_PREFS = "remote_scores"
    private const val SCORES_MIN_INTERVAL_MS = 60 * 60 * 1000L
    private const val TIMEOUT_MS = 10_000

    private val scoresRefreshing = java.util.concurrent.atomic.AtomicBoolean(false)
    @Volatile private var scoresCacheOp: String? = null
    @Volatile private var scoresCache: Map<String, Double> = emptyMap()

    /**
     * Mobile operator bucket: mci | irancell | tci | rightel | shatel | other.
     * From SIM MCC-MNC (no permission needed); Wi-Fi and unknown carriers are "other".
     */
    fun operator(context: Context): String = try {
        if (networkType(context) != "cellular") {
            "other"
        } else {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? android.telephony.TelephonyManager
            val mccMnc = tm?.networkOperator?.takeIf { it.length >= 5 } ?: tm?.simOperator.orEmpty()
            val name = tm?.networkOperatorName.orEmpty().lowercase()
            when {
                mccMnc == "43211" -> "mci"
                mccMnc == "43235" -> "irancell"
                mccMnc == "43220" -> "rightel"
                mccMnc == "43214" || mccMnc == "43219" -> "tci"
                name.contains("shatel") -> "shatel"
                else -> "other"
            }
        }
    } catch (_: Exception) {
        "other"
    }

    /**
     * Remote per-node scores for this operator, keyed by [fingerprint]; empty when
     * never fetched. Reads the cache only, so SHARD ranking never waits on network.
     */
    fun remoteScores(context: Context): Map<String, Double> {
        val op = operator(context)
        if (scoresCacheOp == op) return scoresCache
        val raw = context.getSharedPreferences(SCORES_PREFS, Context.MODE_PRIVATE)
            .getString("json_$op", null)
        val parsed = raw?.let { parseScores(it) } ?: emptyMap()
        scoresCache = parsed
        scoresCacheOp = op
        return parsed
    }

    /** Background fetch of `/scores?op=` at most hourly per operator. Never blocks. */
    fun refreshScoresIfDue(context: Context) {
        val app = context.applicationContext
        val op = operator(app)
        val prefs = app.getSharedPreferences(SCORES_PREFS, Context.MODE_PRIVATE)
        val elapsed = System.currentTimeMillis() - prefs.getLong("at_$op", 0L)
        if (elapsed in 0 until SCORES_MIN_INTERVAL_MS) return
        if (!scoresRefreshing.compareAndSet(false, true)) return
        Thread({
            try {
                val connection = URL(SCORES_ENDPOINT + op).openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = TIMEOUT_MS
                    connection.readTimeout = TIMEOUT_MS
                    connection.requestMethod = "GET"
                    val editor = prefs.edit().putLong("at_$op", System.currentTimeMillis())
                    if (connection.responseCode == 200) {
                        val body = connection.inputStream.bufferedReader().use { it.readText() }
                        if (parseScores(body).isNotEmpty()) {
                            editor.putString("json_$op", body)
                            scoresCacheOp = null
                        }
                    }
                    editor.apply()
                } finally {
                    connection.disconnect()
                }
            } catch (_: Exception) {
                // Best effort only; ranking falls back to local health.
            } finally {
                scoresRefreshing.set(false)
            }
        }, "remote-scores").apply { isDaemon = true }.start()
    }

    /** Accepts `{"scores":{fp:n}}`, `{fp:n}` or `{fp:{"score":n}}`. */
    private fun parseScores(body: String): Map<String, Double> = try {
        val root = JSONObject(body)
        val obj = root.optJSONObject("scores") ?: root
        val out = HashMap<String, Double>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = obj.opt(key)
            val score = when (value) {
                is Number -> value.toDouble()
                is JSONObject -> value.optDouble("score", Double.NaN)
                else -> Double.NaN
            }
            if (!score.isNaN()) out[key] = score
        }
        out
    } catch (_: Exception) {
        emptyMap()
    }

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
                    put("op", operator(app))
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
