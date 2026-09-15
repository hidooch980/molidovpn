package com.molido.vpn

import android.content.Context
import java.util.concurrent.ConcurrentHashMap

/**
 * Retry-only outbound rewrites for SHARD / V2Ray nodes.
 *
 * A node's FIRST attempts are always rendered exactly as the subscription says.
 * Only after [FINGERPRINT_FROM] consecutive failures of the same node on the same
 * network does its outbound change:
 *
 *  - uTLS fingerprint rotates chrome -> firefox -> safari -> randomized, and
 *  - from the [EARLY_DATA_FROM]th failure, ws early data (`?ed=2048`) is added.
 *
 * Nodes whose TLS shape is interlocked with a specific fingerprint are never
 * rotated: SHARD nodes carrying `cs`/`fm` or `fp=unsafe` (see [ShardNode]'s doc —
 * the fragment lengths only line up with that exact ClientHello). Early data is
 * only for V2Ray nodes that are not on SHARD-style Cloudflare workers.
 *
 * Memory only, keyed by network: a success, a new network or a process restart
 * resets everything to the subscription's own values.
 */
object RetryTweaks {

    private const val FINGERPRINT_FROM = 2
    private const val EARLY_DATA_FROM = 3
    private val ROTATION = listOf("chrome", "firefox", "safari", "randomized")

    private val failures = ConcurrentHashMap<String, Int>()

    private fun id(context: Context, node: ShardNode): String =
        CleanIpScanner.networkKey(context) + "#" + node.key

    fun recordFailure(context: Context, node: ShardNode) {
        val k = id(context, node)
        failures[k] = (failures[k] ?: 0) + 1
    }

    fun recordSuccess(context: Context, node: ShardNode) {
        failures.remove(id(context, node))
    }

    private fun count(context: Context, node: ShardNode): Int = failures[id(context, node)] ?: 0

    /** Whether rewriting this node's fingerprint cannot break an interlocked shape. */
    private fun fingerprintFree(node: ShardNode): Boolean {
        val v2 = node.v2ray
        if (v2 != null) return v2.security == "tls" || v2.security == "reality"
        if (node.security != "tls") return false
        return node.cipherSuites.isEmpty() && node.finalMask.isEmpty() &&
            !node.fingerprint.equals("unsafe", ignoreCase = true)
    }

    private fun isWorkerHost(host: String): Boolean {
        val h = host.lowercase()
        return h.endsWith(".workers.dev") || h.endsWith(".pages.dev")
    }

    /** Fingerprint to use instead of the node's own, or null for "unchanged". */
    fun fingerprintFor(context: Context, node: ShardNode): String? {
        val n = count(context, node)
        if (n < FINGERPRINT_FROM || !fingerprintFree(node)) return null
        return ROTATION[(n - FINGERPRINT_FROM) % ROTATION.size]
    }

    /** ws path with early data for this retry, or null for "unchanged". */
    fun earlyDataPath(context: Context, node: ShardNode): String? {
        val v2 = node.v2ray ?: return null
        if (v2.network != "ws" || count(context, node) < EARLY_DATA_FROM) return null
        if (isWorkerHost(v2.host) || isWorkerHost(v2.sni)) return null
        val path = v2.path.ifEmpty { "/" }
        if (path.contains("ed=")) return null
        return path + (if (path.contains('?')) "&" else "?") + "ed=2048"
    }
}
