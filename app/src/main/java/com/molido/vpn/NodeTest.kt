package com.molido.vpn

import android.content.Context
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * "Test servers from my internet": probes the whole V2Ray + SHARD pool from the
 * user's own connection, in batches of 12 probe inbounds, with the same real HTTP
 * probe the connect race uses. Runs its own xray process on a private port block,
 * so it never touches [ShardManager]'s process. Not meant to run under a VPN-mode
 * tunnel (the probes would go through it); the caller enforces that.
 */
object NodeTest {

    private const val BATCH = 12
    private const val BASE_PORT = 21500
    private const val PROBE_TIMEOUT_MS = 5_000

    class Tally {
        val ok = AtomicInteger(0)
        val total = AtomicInteger(0)
    }

    @Volatile
    private var cancelled = false

    fun cancel() {
        cancelled = true
    }

    /** vless-reality, vless-ws, trojan, vmess, ss… */
    fun label(node: ShardNode): String {
        val v = node.v2ray
        val proto = when (val p = v?.protocol ?: node.protocol) {
            "shadowsocks" -> "ss"
            else -> p
        }
        if (proto == "ss") return "ss"
        val sec = v?.security ?: node.security
        val net = v?.network ?: node.network
        return when {
            sec == "reality" -> "$proto-reality"
            net.isNotEmpty() && net != "tcp" -> "$proto-$net"
            else -> proto
        }
    }

    /**
     * Blocking. [onProgress] gets (label → tally) after every batch, [done] tested
     * so far and the pool size. Returns the final tallies.
     */
    fun run(
        context: Context,
        onProgress: (Map<String, Tally>, Int, Int) -> Unit,
    ): Map<String, Tally> {
        cancelled = false
        val app = context.applicationContext
        val tallies = java.util.concurrent.ConcurrentHashMap<String, Tally>()
        val pool = runCatching {
            (V2raySubscription.shardNodes(app) + ShardSubscription.nodes(app)).distinctBy { it.key }
        }.getOrDefault(emptyList()).let { SingBox.prepare(app, it) }
        pool.forEach { tallies.getOrPut(label(it)) { Tally() }.total.incrementAndGet() }
        onProgress(tallies, 0, pool.size)
        val binary = File(app.applicationInfo.nativeLibraryDir, "libxray.so")
        if (pool.isEmpty() || !binary.exists()) return tallies
        val reports = ConnectionReports.enabled(app)
        var done = 0
        for (batch in pool.chunked(BATCH)) {
            if (cancelled) break
            val config = ShardConfigs.probeConfig(app, batch, BASE_PORT)
            val file = ShardConfigs.writeConfig(app, "node-test.json", config)
            val proc = runCatching {
                ProcessBuilder(binary.absolutePath, "run", "-c", file.absolutePath)
                    .directory(file.parentFile)
                    .redirectErrorStream(true)
                    .apply {
                        environment()["HOME"] = app.filesDir.absolutePath
                        environment()["XRAY_LOCATION_ASSET"] = file.parent
                    }
                    .start()
            }.getOrNull()
            if (proc == null) {
                // One unlaunchable batch still counts as tested (failed).
                batch.forEach { report(app, reports, it, false, null) }
                done += batch.size
                onProgress(tallies, done, pool.size)
                continue
            }
            Thread({
                runCatching {
                    val buf = ByteArray(4096)
                    while (proc.inputStream.read(buf) >= 0) { /* drain */ }
                }
            }, "node-test-log").apply { isDaemon = true }.start()
            try {
                val deadline = System.currentTimeMillis() + 12_000
                var ready = false
                while (System.currentTimeMillis() < deadline && !cancelled && proc.isAlive) {
                    if (portAccepts(BASE_PORT)) { ready = true; break }
                    Thread.sleep(100)
                }
                if (ready) {
                    val exec = Executors.newFixedThreadPool(batch.size)
                    batch.forEachIndexed { i, node ->
                        exec.execute {
                            if (cancelled) return@execute
                            val started = System.currentTimeMillis()
                            val ok = ShardProbe.check(BASE_PORT + i, PROBE_TIMEOUT_MS)
                            val ms = (System.currentTimeMillis() - started).toInt()
                            if (ok) tallies[label(node)]?.ok?.incrementAndGet()
                            report(app, reports, node, ok, if (ok) ms else null)
                        }
                    }
                    exec.shutdown()
                    exec.awaitTermination(PROBE_TIMEOUT_MS + 3_000L, TimeUnit.MILLISECONDS)
                    exec.shutdownNow()
                }
            } finally {
                runCatching {
                    proc.destroy()
                    if (!proc.waitFor(3, TimeUnit.SECONDS)) proc.destroyForcibly()
                }
            }
            done += batch.size
            onProgress(tallies, done, pool.size)
        }
        ConnectionLog.record(
            "Node test: " + tallies.entries.sortedBy { it.key }
                .joinToString(" · ") { "${it.key} ${it.value.ok.get()}/${it.value.total.get()}" }
        )
        return tallies
    }

    /**
     * Blocking real probe of [nodes] (same request as the race), for the My configs
     * ping button. Returns node key → latency in ms; failed nodes are absent.
     */
    fun probe(context: Context, nodes: List<ShardNode>): Map<String, Int> {
        cancelled = false
        val app = context.applicationContext
        val results = java.util.concurrent.ConcurrentHashMap<String, Int>()
        val ready = SingBox.prepare(app, nodes)
        val binary = File(app.applicationInfo.nativeLibraryDir, "libxray.so")
        if (ready.isEmpty() || !binary.exists()) return results
        for (batch in ready.chunked(BATCH)) {
            if (cancelled) break
            val file = ShardConfigs.writeConfig(app, "node-ping.json", ShardConfigs.probeConfig(app, batch, BASE_PORT))
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
            }, "node-ping-log").apply { isDaemon = true }.start()
            try {
                val deadline = System.currentTimeMillis() + 12_000
                var up = false
                while (System.currentTimeMillis() < deadline && !cancelled && proc.isAlive) {
                    if (portAccepts(BASE_PORT)) { up = true; break }
                    Thread.sleep(100)
                }
                if (up) {
                    val exec = Executors.newFixedThreadPool(batch.size)
                    batch.forEachIndexed { i, node ->
                        exec.execute {
                            if (cancelled) return@execute
                            val started = System.currentTimeMillis()
                            if (ShardProbe.check(BASE_PORT + i, PROBE_TIMEOUT_MS)) {
                                results[node.key] = (System.currentTimeMillis() - started).toInt()
                            }
                        }
                    }
                    exec.shutdown()
                    exec.awaitTermination(PROBE_TIMEOUT_MS + 3_000L, TimeUnit.MILLISECONDS)
                    exec.shutdownNow()
                }
            } finally {
                runCatching {
                    proc.destroy()
                    if (!proc.waitFor(3, TimeUnit.SECONDS)) proc.destroyForcibly()
                }
            }
        }
        return results
    }

    private fun report(context: Context, enabled: Boolean, node: ShardNode, ok: Boolean, ms: Int?) {
        if (!enabled) return
        // Same node identity as the service's connect report; ConnectionReports adds op.
        ConnectionReports.report(context, ConnectionReports.fingerprint(node.v2ray?.uri ?: node.key), ok, ms)
    }

    private fun portAccepts(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 300); true }
    } catch (_: Exception) {
        false
    }
}
