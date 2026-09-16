package com.molido.vpn

import android.content.Context

/**
 * Per-node health memory: which nodes worked, how fast, and which just failed.
 *
 * ## Why this exists
 *
 * Without it every connect pays the full race from scratch. Measured against the
 * live pool from this machine: a cold race over the publisher's first 12 nodes
 * found a winner in 760–864 ms across three runs, while probing all 28 nodes one
 * at a time took 82 s. The memory is also what makes a bad node stop being tried
 * first after it dies.
 *
 * ## Why latency alone is not the ranking
 *
 * Measured on the live pool: of 28 unique nodes, 20 carried a real HTTP request
 * and 8 did not — and the failures were not uniformly dead, several timed out at
 * exactly the 5 s ceiling while others answered in under a second. A pure "lowest
 * last latency" ranking promotes the intermittent ones, because a node that
 * half-works often answers fast when it answers at all.
 *
 * The score therefore carries a success streak alongside the latency, and a
 * failure is remembered rather than merely forgetting a success.
 */
object ShardHealth {

    private const val PREFS = "shard_health"

    /**
     * Highest latency still treated as a real measurement, in ms.
     *
     * Above this the node is recorded as a failure instead: the working nodes in
     * the live pool measured 727–5735 ms, so 8 s is not "slow but usable", it is a
     * node that will feel broken.
     */
    private const val LATENCY_CEILING_MS = 8_000

    /** How many consecutive failures before a node drops behind untried ones. */
    private const val FAILURE_TOLERANCE = 2

    /**
     * Memory older than this is forgotten, so a server that died (or came back)
     * is re-judged from scratch instead of riding an old score. The timestamp is
     * the 5th field; entries written before it existed count as expired.
     */
    private const val MAX_AGE_MS = 6 * 60 * 60 * 1000L

    private fun expired(raw: String, now: Long): Boolean {
        val at = raw.split(':').getOrNull(4)?.toLongOrNull() ?: 0L
        return now - at !in 0 until MAX_AGE_MS
    }

    /**
     * Ceiling and exchange rate for the measured-bandwidth bonus in [Score.rank].
     *
     * 30 Mbps × 50 ms = 1500 ms, i.e. a fast node may jump ahead of one whose
     * probe was up to 1.5 s quicker. Chosen so the bonus can overcome the
     * latency spread actually seen among working nodes (727–1773 ms) without
     * overwhelming the failure and streak terms, which are about reliability.
     */
    private const val THROUGHPUT_BONUS_CEILING_MBPS = 30
    private const val THROUGHPUT_BONUS_PER_MBPS = 50

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * What we know about one node.
     *
     * @param latencyMs last successful probe, 0 if never measured.
     * @param streak consecutive successes, reset to 0 by any failure.
     * @param failures consecutive failures, reset to 0 by any success.
     * @param kbps last measured download rate, 0 if never measured. See
     *   [recordThroughput] for why latency alone is not enough.
     */
    data class Score(
        val latencyMs: Int,
        val streak: Int,
        val failures: Int,
        val kbps: Int = 0,
    ) {
        val everWorked: Boolean get() = latencyMs > 0

        /**
         * Sort key: lower is tried earlier.
         *
         * A node that has failed [FAILURE_TOLERANCE] times in a row is pushed
         * behind everything untried, but not removed — the pool is small and a
         * node whose owner fixed their worker deserves another look eventually.
         * Untried nodes sort in the middle: ahead of known-bad, behind known-good.
         */
        fun rank(): Int = when {
            failures >= FAILURE_TOLERANCE -> 900_000 + latencyMs
            !everWorked -> 500_000
            // Two consecutive successes are worth roughly a second of latency:
            // enough to prefer a steady 2 s node over a flaky 1.2 s one, not
            // enough to bury a genuinely fast newcomer.
            else -> latencyMs - (streak.coerceAtMost(5) * 500) - throughputBonus()
        }

        /**
         * How much measured bandwidth is allowed to outweigh probe latency.
         *
         * Needed because the two are close to unrelated. Measured across the 23
         * reachable nodes of the live pool, probe latency against the rate of a
         * 4 MB download through the same node in the same minute:
         *
         * ```
         *   probe  778 ms -> 108 Mbps        probe 1488 ms ->   5.1 Mbps
         *   probe  942 ms ->  25 Mbps        probe 1773 ms ->  98.5 Mbps
         * ```
         *
         * A pure latency ranking therefore prefers the 5 Mbps node to the
         * 98 Mbps one. The bonus is capped at 30 Mbps' worth (1500 ms) so a
         * genuinely fast link cannot bury a node that is merely well-connected,
         * and so the ordering stays dominated by "does it work at all".
         */
        private fun throughputBonus(): Int {
            if (kbps <= 0) return 0
            val mbps = kbps / 1000
            return mbps.coerceAtMost(THROUGHPUT_BONUS_CEILING_MBPS) * THROUGHPUT_BONUS_PER_MBPS
        }
    }

    fun score(context: Context, node: ShardNode): Score {
        val raw = prefs(context).getString(node.key, null) ?: return Score(0, 0, 0)
        if (expired(raw, System.currentTimeMillis())) return Score(0, 0, 0)
        val parts = raw.split(':')
        return Score(
            latencyMs = parts.getOrNull(0)?.toIntOrNull() ?: 0,
            streak = parts.getOrNull(1)?.toIntOrNull() ?: 0,
            failures = parts.getOrNull(2)?.toIntOrNull() ?: 0,
            // Absent in entries written by older versions, which read back as 0
            // and simply score no bonus until the node is measured again.
            kbps = parts.getOrNull(3)?.toIntOrNull() ?: 0,
        )
    }

    /** Record a successful probe. A latency past the ceiling counts as a failure. */
    fun recordSuccess(context: Context, node: ShardNode, latencyMs: Int) {
        if (latencyMs > LATENCY_CEILING_MS) {
            recordFailure(context, node)
            return
        }
        RetryTweaks.recordSuccess(context, node)
        val previous = score(context, node)
        // Smoothed, not replaced: one lucky sample on a congested carrier link
        // should not promote a node to the top of the list on its own. Weighted
        // toward the new value so a genuine improvement is still visible quickly.
        val blended = if (previous.everWorked) {
            ((previous.latencyMs + latencyMs * 2) / 3)
        } else {
            latencyMs
        }
        prefs(context).edit()
            .putString(node.key, "$blended:${previous.streak + 1}:0:${previous.kbps}:${System.currentTimeMillis()}")
            .apply()
    }

    /**
     * Record how fast [node] actually carried data, in kbit/s.
     *
     * Kept separate from [recordSuccess] because the two are measured at
     * different moments: latency comes from the race, which must stay cheap,
     * while this comes from a real transfer over the live tunnel once it is up.
     * A missing or failed measurement leaves the previous value alone rather
     * than clearing it — an interrupted sample says nothing about the node.
     */
    fun recordThroughput(context: Context, node: ShardNode, kbps: Int) {
        if (kbps <= 0) return
        val previous = score(context, node)
        // Same smoothing as latency, and for the same reason: one sample taken
        // while the user was streaming video is not the node's capability.
        val blended = if (previous.kbps > 0) {
            ((previous.kbps + kbps * 2) / 3)
        } else {
            kbps
        }
        prefs(context).edit()
            .putString(
                node.key,
                "${previous.latencyMs}:${previous.streak}:${previous.failures}:$blended:${System.currentTimeMillis()}"
            )
            .apply()
    }

    fun recordFailure(context: Context, node: ShardNode) {
        RetryTweaks.recordFailure(context, node)
        val previous = score(context, node)
        prefs(context).edit()
            .putString(
                node.key,
                "${previous.latencyMs}:0:${previous.failures + 1}:${previous.kbps}:${System.currentTimeMillis()}"
            )
            .apply()
    }

    /**
     * Order the pool for the next race: most likely to work, fastest first.
     *
     * Stable within a rank, so nodes we know nothing about keep the publisher's
     * own order — which is itself the output of a 3-of-3 health check, so it is
     * better than random.
     */
    fun rank(context: Context, nodes: List<ShardNode>): List<ShardNode> {
        val base = nodes.associateWith { score(context, it) }
        val net = try { ConnectionReports.networkKey(context) } catch (_: Exception) { "" }
        val now = System.currentTimeMillis()
        val scanPrefs = context.getSharedPreferences(SCAN_PREFS, Context.MODE_PRIVATE)
        val scores = base.mapValues { (node, s) -> ScanAdjusted(s, scanPrefs.getString("$net|${node.key}", null), now) }
        // Operator-aware remote scores (ConnectionReports.remoteScores) only break
        // ties within the same local rank — mostly the untried nodes — and are read
        // from cache, so they can never block or override local evidence.
        val remote = try {
            ConnectionReports.remoteScores(context)
        } catch (_: Exception) {
            emptyMap()
        }
        if (remote.isEmpty()) return nodes.sortedBy { scores[it]?.rank() ?: 500_000 }
        val remoteByNode = nodes.associateWith {
            remote[ConnectionReports.fingerprint(it.v2ray?.uri ?: it.key)] ?: 0.0
        }
        return nodes.sortedWith(
            compareBy<ShardNode> { scores[it]?.rank() ?: 500_000 }
                .thenByDescending { remoteByNode[it] ?: 0.0 }
        )
    }

    /** Background-scan memory keyed "net|nodeKey" → "consecutiveFails:at:ms". */
    private const val SCAN_PREFS = "shard_scan_health"
    private const val SCAN_FAIL_LIMIT = 3
    private const val SCAN_RECENT_BONUS_MS = 2_000

    /** [Score] rank adjusted by what the background scanner saw on this network. */
    private class ScanAdjusted(val score: Score, raw: String?, now: Long) {
        private val rankValue: Int

        init {
            val parts = raw?.split(':').orEmpty()
            val fails = parts.getOrNull(0)?.toIntOrNull() ?: 0
            val at = parts.getOrNull(1)?.toLongOrNull() ?: 0L
            val ms = parts.getOrNull(2)?.toIntOrNull() ?: 0
            val recent = now - at in 0 until MAX_AGE_MS
            val r = score.rank()
            rankValue = when {
                !recent -> r
                // Failed 3 scans in a row on this network: behind everything for 6 h.
                fails >= SCAN_FAIL_LIMIT -> maxOf(r, 950_000)
                // Worked on this network recently: ahead of nodes without that evidence.
                fails == 0 && ms > 0 -> (if (r >= 500_000) ms else r) - SCAN_RECENT_BONUS_MS
                else -> r
            }
        }

        fun rank(): Int = rankValue
    }

    /** Record one background-scan result for [node] on network [net]. */
    fun recordScan(context: Context, node: ShardNode, net: String, ok: Boolean, latencyMs: Int) {
        val prefs = context.getSharedPreferences(SCAN_PREFS, Context.MODE_PRIVATE)
        val key = "$net|${node.key}"
        val now = System.currentTimeMillis()
        val prev = prefs.getString(key, null)?.split(':').orEmpty()
        val prevAt = prev.getOrNull(1)?.toLongOrNull() ?: 0L
        val prevFails = if (now - prevAt in 0 until MAX_AGE_MS) prev.getOrNull(0)?.toIntOrNull() ?: 0 else 0
        val value = if (ok) "0:$now:${latencyMs.coerceAtLeast(1)}" else "${prevFails + 1}:$now:0"
        synchronized(this) {
            prefs.edit().putString(key, value).apply()
        }
    }

    /**
     * Drop memory for nodes that are no longer in the pool.
     *
     * Called after each subscription refresh. Without it this file grows forever:
     * the publisher's nodes rotate, and every departed node would keep its entry
     * indefinitely.
     */
    fun prune(context: Context, nodes: List<ShardNode>) {
        val live = nodes.map { it.key }.toSet()
        val v2 = nodes.firstOrNull()?.v2ray != null
        val now = System.currentTimeMillis()
        val editor = prefs(context).edit()
        prefs(context).all.forEach { (key, value) ->
            // Expired entries go for every pool. Departed keys are pruned by SHARD
            // only: the V2Ray servers and My configs share the "v2|" prefix, so
            // racing one must not wipe the other's memory — expiry cleans those.
            val stale = expired(value as? String ?: "", now)
            val departedShard = !v2 && !key.startsWith("v2|") && key !in live
            if (stale || departedShard) editor.remove(key)
        }
        editor.apply()
    }

    /** Forget everything. Exposed for the settings row that resets the transport. */
    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }
}
