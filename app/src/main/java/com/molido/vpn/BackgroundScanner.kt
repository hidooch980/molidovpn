package com.molido.vpn

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.net.ConnectivityManager
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Internal background scanner: every hour (JobScheduler, network required, battery
 * not low) probe SHARD + V2Ray subscription + My configs nodes from the user's own
 * internet, so Auto mode and the V2Ray race prefer nodes that worked on THIS network.
 *
 * Runs inside [ShardRefreshJob] (job id [JOB_ID]) so no manifest change is needed.
 * Lightweight: ≤ 8 probes at once (one xray process per batch of 8), 5 s per probe,
 * whole run capped at 4 minutes — far below JobScheduler's 10-minute stop.
 */
object BackgroundScanner {

    const val PREF = "background_scanner"
    const val DEFAULT = true
    const val JOB_ID = 0x5A51

    private const val PERIOD_MS = 60 * 60 * 1000L
    private const val BATCH = 8
    private const val BASE_PORT = 21700
    private const val PROBE_TIMEOUT_MS = 5_000
    private const val RUNTIME_CAP_MS = 4 * 60 * 1000L
    private const val LIMIT_METERED = 40
    private const val LIMIT_UNMETERED = 200
    private const val REPORTS_PER_HOUR = 200

    private const val STATE_PREFS = "background_scanner_state"
    private const val LAST_AT = "last_at"
    private const val LAST_OK = "last_ok"
    private const val REPORT_WINDOW = "report_window"
    private const val REPORT_COUNT = "report_count"

    @Volatile
    private var cancelled = false

    private fun settings(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private fun state(context: Context) = context.getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)

    fun enabled(context: Context): Boolean = settings(context).getBoolean(PREF, DEFAULT)

    fun lastScanAt(context: Context): Long = state(context).getLong(LAST_AT, 0L)
    fun lastHealthy(context: Context): Int = state(context).getInt(LAST_OK, 0)

    fun cancel() {
        cancelled = true
    }

    /** Schedule (enabled) or cancel (disabled) the hourly job. Idempotent. */
    fun schedule(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        if (!enabled(context)) {
            runCatching { scheduler.cancel(JOB_ID) }
            return
        }
        try {
            scheduler.schedule(
                JobInfo.Builder(JOB_ID, ComponentName(context, ShardRefreshJob::class.java))
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setRequiresBatteryNotLow(true)
                    .setPeriodic(PERIOD_MS)
                    .build()
            )
        } catch (e: Exception) {
            ConnectionLog.record("Background scanner could not be scheduled: ${e.message}")
        }
    }

    /**
     * True when a scan may run now: enabled, and no VPN-mode tunnel (the probes
     * would go through it). Proxy mode does not capture app traffic, so it probes directly.
     */
    fun canRun(context: Context): Boolean =
        enabled(context) && (!TunnelStatus.isActive() || TunnelStatus.isProxyMode)

    /** Blocking. Returns the number of healthy nodes found. */
    fun run(context: Context): Int {
        cancelled = false
        val app = context.applicationContext
        val started = System.currentTimeMillis()
        val metered = runCatching {
            app.getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered ?: true
        }.getOrDefault(true)
        val limit = if (metered) LIMIT_METERED else LIMIT_UNMETERED
        val all = runCatching {
            (ShardSubscription.nodes(app) +
                V2raySubscription.shardNodes(app) +
                MyConfigs.entries(app).mapNotNull { MyConfigs.node(it) }).distinctBy { it.key }
        }.getOrDefault(emptyList())
        // Most promising first, so the metered top-40 is the useful 40.
        val pool = runCatching { ShardHealth.rank(app, all) }.getOrDefault(all)
            .take(limit)
            .let { runCatching { SingBox.prepare(app, it) }.getOrDefault(emptyList()) }
        val binary = File(app.applicationInfo.nativeLibraryDir, "libxray.so")
        if (pool.isEmpty() || !binary.exists()) return 0
        val net = ConnectionReports.networkKey(app)
        val reports = ConnectionReports.enabled(app)
        val healthy = AtomicInteger(0)
        var tested = 0
        for (batch in pool.chunked(BATCH)) {
            if (cancelled || !canRun(app)) break
            if (System.currentTimeMillis() - started > RUNTIME_CAP_MS) break
            val file = runCatching {
                ShardConfigs.writeConfig(app, "bg-scan.json", ShardConfigs.probeConfig(app, batch, BASE_PORT))
            }.getOrNull() ?: continue
            val proc = runCatching {
                ProcessBuilder(binary.absolutePath, "run", "-c", file.absolutePath)
                    .directory(file.parentFile)
                    .redirectErrorStream(true)
                    .apply {
                        environment()["HOME"] = app.filesDir.absolutePath
                        environment()["XRAY_LOCATION_ASSET"] = file.parent
                    }
                    .start()
            }.getOrNull() ?: continue
            Thread({
                runCatching {
                    val buf = ByteArray(4096)
                    while (proc.inputStream.read(buf) >= 0) { /* drain */ }
                }
            }, "bg-scan-log").apply { isDaemon = true }.start()
            try {
                val deadline = System.currentTimeMillis() + 12_000
                var up = false
                while (System.currentTimeMillis() < deadline && !cancelled && proc.isAlive) {
                    if (portAccepts(BASE_PORT)) { up = true; break }
                    Thread.sleep(100)
                }
                if (!up) continue
                val exec = Executors.newFixedThreadPool(batch.size)
                batch.forEachIndexed { i, node ->
                    exec.execute {
                        if (cancelled) return@execute
                        val t0 = System.currentTimeMillis()
                        val ok = ShardProbe.check(BASE_PORT + i, PROBE_TIMEOUT_MS)
                        val ms = (System.currentTimeMillis() - t0).toInt()
                        if (cancelled) return@execute
                        if (ok) {
                            healthy.incrementAndGet()
                            ShardHealth.recordSuccess(app, node, ms)
                        } else {
                            ShardHealth.recordFailure(app, node)
                        }
                        ShardHealth.recordScan(app, node, net, ok, ms)
                        if (reports && reportAllowed(app)) {
                            ConnectionReports.report(
                                app, ConnectionReports.fingerprint(node.v2ray?.uri ?: node.key), ok, if (ok) ms else null
                            )
                        }
                    }
                }
                exec.shutdown()
                exec.awaitTermination(PROBE_TIMEOUT_MS + 3_000L, TimeUnit.MILLISECONDS)
                exec.shutdownNow()
                tested += batch.size
            } finally {
                runCatching {
                    proc.destroy()
                    if (!proc.waitFor(3, TimeUnit.SECONDS)) proc.destroyForcibly()
                }
            }
        }
        if (tested > 0) {
            state(app).edit()
                .putLong(LAST_AT, System.currentTimeMillis())
                .putInt(LAST_OK, healthy.get())
                .apply()
        }
        ConnectionLog.record(
            "Background scan ($net${if (metered) ", metered" else ""}): ${healthy.get()}/$tested healthy " +
                "in ${(System.currentTimeMillis() - started) / 1000}s"
        )
        return healthy.get()
    }

    /** At most [REPORTS_PER_HOUR] reports per rolling hour window. */
    @Synchronized
    private fun reportAllowed(context: Context): Boolean {
        val prefs = state(context)
        val now = System.currentTimeMillis()
        val window = prefs.getLong(REPORT_WINDOW, 0L)
        val count = if (now - window in 0 until PERIOD_MS) prefs.getInt(REPORT_COUNT, 0) else 0
        if (count >= REPORTS_PER_HOUR) return false
        val editor = prefs.edit()
        if (count == 0) editor.putLong(REPORT_WINDOW, now)
        editor.putInt(REPORT_COUNT, count + 1).commit()
        return true
    }

    private fun portAccepts(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 300); true }
    } catch (_: Exception) {
        false
    }
}
