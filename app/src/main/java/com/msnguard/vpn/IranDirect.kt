package com.msnguard.vpn

import android.content.Context

/**
 * "Iranian sites direct" (سایت‌های ایرانی مستقیم): a lightweight bypass that is
 * NOT Smart Split — no fragment profiles, no probing.
 *
 *  - SHARD / V2Ray: xray routes `domain:ir` + `geosite:category-ir` + `geoip:ir`
 *    to a plain freedom outbound ([ShardConfigs.tunnelConfig]). If the bundled geo
 *    files cannot be unpacked it degrades to the `domain:ir` rule only.
 *  - TUN (tun2socks transports) on Android 13+: Iranian IPv4 ranges are excluded
 *    from the VPN with `excludeRoute`. Older Android keeps only the xray rule.
 *
 * Default ON for new installs only; an existing install keeps its current
 * behaviour until the user turns it on.
 */
object IranDirect {

    const val PREF = "iran_direct"

    /** Cap on excluded routes: the aggregated /8../20 blocks, not every /24. */
    private const val MAX_ROUTES = 400
    private const val MAX_PREFIX = 20

    fun enabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        if (prefs.contains(PREF)) return prefs.getBoolean(PREF, false)
        val fresh = runCatching {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            info.firstInstallTime == info.lastUpdateTime
        }.getOrDefault(false)
        prefs.edit().putBoolean(PREF, fresh).apply()
        return fresh
    }

    fun setEnabled(context: Context, on: Boolean) {
        context.getSharedPreferences("settings", Context.MODE_PRIVATE).edit().putBoolean(PREF, on).apply()
    }

    @Volatile
    private var cached: List<Pair<String, Int>>? = null

    /**
     * Iranian IPv4 CIDRs as (address, prefix), read from the bundled trimmed
     * geoip.dat (protobuf GeoIPList). Empty on any parse problem.
     */
    fun ipv4Cidrs(context: Context): List<Pair<String, Int>> {
        cached?.let { return it }
        val result = runCatching {
            val bytes = context.assets.open("geoip.dat").use { it.readBytes() }
            parse(bytes)
        }.getOrDefault(emptyList())
        cached = result
        return result
    }

    private class Reader(val b: ByteArray, var pos: Int, val end: Int) {
        fun varint(): Long {
            var shift = 0
            var out = 0L
            while (pos < end) {
                val v = b[pos++].toInt() and 0xff
                out = out or ((v and 0x7f).toLong() shl shift)
                if (v and 0x80 == 0) return out
                shift += 7
                if (shift > 63) break
            }
            throw IllegalStateException("bad varint")
        }

        fun skip(wire: Int) {
            when (wire) {
                0 -> varint()
                1 -> pos += 8
                2 -> pos += varint().toInt()
                5 -> pos += 4
                else -> throw IllegalStateException("wire $wire")
            }
        }
    }

    private fun parse(bytes: ByteArray): List<Pair<String, Int>> {
        val out = ArrayList<Pair<String, Int>>()
        val top = Reader(bytes, 0, bytes.size)
        while (top.pos < top.end) {
            val tag = top.varint().toInt()
            if (tag ushr 3 != 1 || tag and 7 != 2) { top.skip(tag and 7); continue }
            val len = top.varint().toInt()
            val entryEnd = top.pos + len
            val entry = Reader(bytes, top.pos, entryEnd)
            var code = ""
            val cidrs = ArrayList<Pair<String, Int>>()
            while (entry.pos < entry.end) {
                val t = entry.varint().toInt()
                val field = t ushr 3
                val wire = t and 7
                if (field == 1 && wire == 2) {
                    val l = entry.varint().toInt()
                    code = String(bytes, entry.pos, l, Charsets.UTF_8)
                    entry.pos += l
                } else if (field == 2 && wire == 2) {
                    val l = entry.varint().toInt()
                    val c = Reader(bytes, entry.pos, entry.pos + l)
                    var ip: ByteArray? = null
                    var prefix = -1
                    while (c.pos < c.end) {
                        val ct = c.varint().toInt()
                        if (ct ushr 3 == 1 && ct and 7 == 2) {
                            val il = c.varint().toInt()
                            ip = bytes.copyOfRange(c.pos, c.pos + il)
                            c.pos += il
                        } else if (ct ushr 3 == 2 && ct and 7 == 0) {
                            prefix = c.varint().toInt()
                        } else {
                            c.skip(ct and 7)
                        }
                    }
                    val a = ip
                    if (a != null && a.size == 4 && prefix in 1..MAX_PREFIX) {
                        cidrs.add(a.joinToString(".") { (it.toInt() and 0xff).toString() } to prefix)
                    }
                    entry.pos += l
                } else {
                    entry.skip(wire)
                }
            }
            if (code.equals("IR", ignoreCase = true)) {
                out.addAll(cidrs.sortedBy { it.second }.take(MAX_ROUTES))
                break
            }
            top.pos = entryEnd
        }
        return out
    }
}
