package com.molido.vpn

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The user's imported AmneziaWG config: in practice a Cloudflare WARP account with
 * AmneziaWG junk-packet obfuscation (H1–H4 = 1..4, i.e. standard WireGuard headers).
 *
 * How it connects: through the Rust core's ordinary WireGuard path. The core loads
 * its identity from `wireguard_config_path` (a PersistedIdentity TOML), so the
 * imported private key / peer key / addresses are written there, the endpoints go
 * in `forced_peers` (tried in order, last working one first — see run_wireguard),
 * and Jc/Jmin/Jmax go in `obfuscation_parameters` on top of the "off" profile.
 *
 * Secrets: the parsed config lives only in [SecureStore] (Keystore-encrypted,
 * app-private) and in the app-private identity TOML. Nothing here logs a key, and
 * [Parsed.toString] is overridden so an accidental string template cannot either.
 * [LogRedactor] additionally codes any 44-char base64 key that reaches the log.
 */
object AmneziaConfig {

    /** Rail / preference / Auto name. Never reaches the core as a protocol. */
    const val PROTOCOL = "amnezia"

    /** Identity file name; the service recognises an Amnezia session by it. */
    const val TOML_NAME = "amnezia-wg.toml"

    /**
     * Built-in mode (nothing imported): the app's own WARP identity — the one
     * WireGuard mode registers and caches — with fixed Amnezia junk parameters and
     * this endpoint list, tried in order (the core moves the last working one to
     * the front), then the core's normal WARP endpoint scan as the last fallback.
     * No key is bundled: every install uses its own registered account.
     */
    val BUILTIN_ENDPOINTS = listOf(
        "188.114.97.6:7281",
        "162.159.195.8:3581",
        "162.159.192.2:878",
        "8.6.112.224:8886",
        "162.159.192.64:894",
    )
    private const val BUILTIN_JC = 5
    private const val BUILTIN_JMIN = 10
    private const val BUILTIN_JMAX = 40

    /** Copy of WireGuard's identity, so the built-in mode keeps its own lastconn. */
    private const val BUILTIN_TOML_NAME = "amnezia-wg-auto.toml"

    /** Present in every built-in Amnezia core config; the service's session marker. */
    const val BUILTIN_MARKER = "\"forced_peers_scan_fallback\":true"

    private const val SECRET_KEY = "amnezia_wg_config"
    private const val MAX_ENDPOINTS = 16
    const val MAX_TEXT_CHARS = 64 * 1024

    /** Validation failure. Messages never contain key material. */
    class Invalid(message: String) : Exception(message)

    data class Parsed(
        val privateKey: String,
        val peerPublicKey: String,
        val ipv4: String,
        val ipv6: String,
        val mtu: Int,
        val dns: List<String>,
        val jc: Int,
        val jmin: Int,
        val jmax: Int,
        val endpoints: List<String>,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("private_key", privateKey)
            .put("peer_public_key", peerPublicKey)
            .put("ipv4", ipv4)
            .put("ipv6", ipv6)
            .put("mtu", mtu)
            .put("dns", JSONArray(dns))
            .put("jc", jc)
            .put("jmin", jmin)
            .put("jmax", jmax)
            .put("endpoints", JSONArray(endpoints))

        /** Deliberately key-free. */
        override fun toString(): String =
            "AmneziaConfig(endpoints=${endpoints.size}, ipv6=${ipv6.isNotEmpty()}, jc=$jc, jmin=$jmin, jmax=$jmax)"
    }

    private class PeerBlock(var key: String = "", var endpoint: String = "", var psk: String = "")

    // ------------------------------------------------------------------ parsing

    fun parse(input: String): Parsed {
        if (input.length > MAX_TEXT_CHARS) throw Invalid("file is too large")
        var section = ""
        var interfaces = 0
        var privateKey = ""
        val addresses = mutableListOf<String>()
        val dns = mutableListOf<String>()
        var mtu = 1280
        var jc = 0
        var jmin = 0
        var jmax = 0
        val peers = mutableListOf<PeerBlock>()

        input.removePrefix("﻿").lineSequence().forEachIndexed { index, raw ->
            val line = raw.substringBefore('#').trim()
            if (line.isEmpty() || line.startsWith(";")) return@forEachIndexed
            if (line.startsWith("[") && line.endsWith("]")) {
                section = line.substring(1, line.length - 1).trim().lowercase()
                when (section) {
                    "interface" -> interfaces++
                    "peer" -> peers += PeerBlock()
                    else -> throw Invalid("unknown section on line ${index + 1}")
                }
                return@forEachIndexed
            }
            val eq = line.indexOf('=')
            if (eq <= 0) throw Invalid("line ${index + 1} is not \"key = value\"")
            val key = line.substring(0, eq).trim().lowercase()
            val value = line.substring(eq + 1).trim()
            when (section) {
                "interface" -> when (key) {
                    "privatekey" -> privateKey = value
                    "address" -> addresses += splitList(value)
                    "dns" -> dns += splitList(value)
                    "mtu" -> mtu = value.toIntOrNull() ?: throw Invalid("MTU is not a number")
                    "jc" -> jc = number(value, "Jc")
                    "jmin" -> jmin = number(value, "Jmin")
                    "jmax" -> jmax = number(value, "Jmax")
                    "s1", "s2" -> if (number(value, key.uppercase()) != 0) {
                        throw Invalid("${key.uppercase()} (handshake padding) is not supported — it must be 0")
                    }
                    "h1", "h2", "h3", "h4" -> {
                        val expected = key.substring(1).toLong()
                        if (value.toLongOrNull() != expected) {
                            throw Invalid(
                                "${key.uppercase()} must be $expected (standard WireGuard headers); " +
                                    "custom H1–H4 values are not supported by this app"
                            )
                        }
                    }
                    else -> Unit // ListenPort, I1–I5, etc.: not used by WARP.
                }
                "peer" -> {
                    val peer = peers.lastOrNull() ?: throw Invalid("[Peer] field outside a [Peer] section")
                    when (key) {
                        "publickey" -> peer.key = value
                        "endpoint" -> peer.endpoint = value
                        "presharedkey" -> peer.psk = value
                        else -> Unit // AllowedIPs, PersistentKeepalive: the app routes everything.
                    }
                }
                else -> throw Invalid("line ${index + 1} is outside [Interface] / [Peer]")
            }
        }

        if (interfaces != 1) throw Invalid("expected exactly one [Interface] section")
        if (!isKey(privateKey)) throw Invalid("PrivateKey is missing or is not a 32-byte base64 key")
        if (peers.isEmpty()) throw Invalid("no [Peer] section")
        val publicKey = peers.first().key
        if (!isKey(publicKey)) throw Invalid("peer PublicKey is missing or is not a 32-byte base64 key")
        if (peers.any { it.key != publicKey }) throw Invalid("every [Peer] must use the same PublicKey")
        if (peers.any { it.psk.isNotEmpty() }) throw Invalid("PresharedKey is not supported")

        val hosts = addresses.map { it.substringBefore('/').trim() }
        val ipv4 = hosts.firstOrNull(::isIpv4) ?: throw Invalid("Address has no IPv4 address")
        val ipv6 = hosts.firstOrNull(::isIpv6).orEmpty()

        if (jc !in 0..10) throw Invalid("Jc must be 0–10")
        if (jmin !in 0..1024 || jmax !in 0..1024) throw Invalid("Jmin and Jmax must be 0–1024")
        if (jmax < jmin) throw Invalid("Jmax must be at least Jmin")
        if (mtu !in 576..9000) throw Invalid("MTU is out of range")

        val endpoints = LinkedHashSet<String>()
        peers.forEach { peer ->
            if (peer.endpoint.isEmpty()) return@forEach
            endpoints += normalizeEndpoint(peer.endpoint)
                ?: throw Invalid("Endpoint must be ip:port with a numeric IP (hostnames are not supported)")
        }
        if (endpoints.isEmpty()) throw Invalid("no Endpoint in any [Peer]")

        return Parsed(
            privateKey = privateKey,
            peerPublicKey = publicKey,
            ipv4 = ipv4,
            ipv6 = ipv6,
            mtu = mtu,
            dns = dns.filter { isIpv4(it) || isIpv6(it) },
            jc = jc,
            jmin = jmin,
            jmax = jmax,
            endpoints = endpoints.take(MAX_ENDPOINTS),
        )
    }

    private fun splitList(value: String): List<String> =
        value.split(',', ' ', ';').map(String::trim).filter(String::isNotEmpty)

    private fun number(value: String, name: String): Int =
        value.toIntOrNull() ?: throw Invalid("$name is not a whole number")

    private fun isKey(value: String): Boolean =
        value.length == 44 && runCatching { Base64.decode(value, Base64.DEFAULT).size == 32 }.getOrDefault(false)

    private fun isIpv4(value: String): Boolean {
        val parts = value.split('.')
        return parts.size == 4 && parts.all { p -> p.isNotEmpty() && p.length <= 3 && p.all(Char::isDigit) && p.toInt() <= 255 }
    }

    private fun isIpv6(value: String): Boolean =
        value.count { it == ':' } >= 2 &&
            value.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' || it == ':' || it == '.' }

    private fun normalizeEndpoint(raw: String): String? {
        val s = raw.trim()
        val host: String
        val portText: String
        if (s.startsWith("[")) {
            val close = s.indexOf(']')
            if (close < 0 || close + 2 > s.length || s.getOrNull(close + 1) != ':') return null
            host = s.substring(1, close)
            portText = s.substring(close + 2)
            if (!isIpv6(host)) return null
        } else {
            if (s.count { it == ':' } != 1) return null
            host = s.substringBefore(':')
            portText = s.substringAfter(':')
            if (!isIpv4(host)) return null
        }
        val port = portText.toIntOrNull() ?: return null
        if (port !in 1..65535) return null
        return if (host.contains(':')) "[$host]:$port" else "$host:$port"
    }

    // ------------------------------------------------------------------ storage

    fun store(context: Context, parsed: Parsed) {
        SecureStore.putSecret(context, SECRET_KEY, parsed.toJson().toString())
    }

    fun load(context: Context): Parsed? {
        val raw = runCatching { SecureStore.getSecret(context, SECRET_KEY) }.getOrDefault("")
        if (raw.isBlank()) return null
        return runCatching { fromJson(JSONObject(raw)) }.getOrNull()
    }

    fun isImported(context: Context): Boolean = load(context) != null

    fun endpointCount(context: Context): Int = load(context)?.endpoints?.size ?: 0

    /** Removes the stored config, the identity TOML and the core's lastconn file for it. */
    fun clear(context: Context) {
        SecureStore.removeSecret(context, SECRET_KEY)
        context.filesDir.listFiles()
            ?.filter { it.name.startsWith(TOML_NAME.substringBefore('.')) }
            ?.forEach { it.delete() }
    }

    private fun fromJson(o: JSONObject): Parsed {
        fun list(name: String): List<String> {
            val array = o.optJSONArray(name) ?: return emptyList()
            return (0 until array.length()).map { array.getString(it) }
        }
        return Parsed(
            privateKey = o.getString("private_key"),
            peerPublicKey = o.getString("peer_public_key"),
            ipv4 = o.getString("ipv4"),
            ipv6 = o.optString("ipv6"),
            mtu = o.optInt("mtu", 1280),
            dns = list("dns"),
            jc = o.optInt("jc"),
            jmin = o.optInt("jmin"),
            jmax = o.optInt("jmax"),
            endpoints = list("endpoints"),
        ).also { if (it.endpoints.isEmpty()) throw IllegalStateException("no endpoints") }
    }

    // ------------------------------------------------------------------ core config

    /** Whether the built-in (no import) mode is what a connect will use. */
    fun usesBuiltin(context: Context): Boolean = !isImported(context)

    /**
     * Built-in AmneziaWG: WireGuard's own config (identity, team, DNS, listen) with
     * the fixed endpoint list and junk parameters. When WireGuard's identity file
     * exists it is copied so this mode's lastconn stays separate; before the first
     * registration the core provisions straight into WireGuard's file, which
     * WireGuard mode then reuses.
     */
    private fun builtinCoreJson(context: Context, listenOverride: Int?, ipScanOverride: String?): String {
        val base = JSONObject(CoreConfig.json(context, "wireguard", listenOverride, ipScanOverride))
        val shared = File(base.optString("config_path"))
        if (base.optString("team").isEmpty() && shared.isFile) {
            val copy = File(context.filesDir, BUILTIN_TOML_NAME)
            val copied = runCatching {
                shared.copyTo(copy, overwrite = true)
                copy.setReadable(false, false)
                copy.setReadable(true, true)
                true
            }.getOrDefault(false)
            if (copied) base.put("wireguard_config_path", copy.absolutePath)
        }
        base.remove("forced_peer")
        base.put("forced_peers", BUILTIN_ENDPOINTS.joinToString(","))
        base.put("forced_peers_scan_fallback", true)
        base.put("obfuscation_profile", "off")
        base.put(
            "obfuscation_parameters",
            JSONObject().put("jc", BUILTIN_JC).put("jmin", BUILTIN_JMIN).put("jmax", BUILTIN_JMAX).toString(),
        )
        base.put("retry_obfuscation_profiles", false)
        return base.toString()
    }

    /**
     * Written before every connect: if this file were missing, the core would
     * provision a brand-new WARP account instead of using the imported one.
     * Base64 and dotted addresses are safe inside TOML basic strings.
     */
    private fun writeIdentity(context: Context, parsed: Parsed): File {
        val file = File(context.filesDir, TOML_NAME)
        file.writeText(
            buildString {
                append("device_id = \"amnezia-import\"\n")
                append("access_token = \"\"\n")
                append("ipv4 = \"").append(parsed.ipv4).append("\"\n")
                append("ipv6 = \"").append(parsed.ipv6).append("\"\n")
                append("wg_private_key = \"").append(parsed.privateKey).append("\"\n")
                append("wg_peer_public_key = \"").append(parsed.peerPublicKey).append("\"\n")
            }
        )
        file.setReadable(false, false)
        file.setReadable(true, true)
        file.setWritable(false, false)
        file.setWritable(true, true)
        return file
    }

    /**
     * Core JSON for an Amnezia connect. Called from [CoreConfig.json] when the
     * requested protocol is [PROTOCOL]. Without an import it returns a config whose
     * protocol is still "amnezia"; the service refuses that with a clear message.
     */
    fun coreJson(context: Context, listenOverride: Int?, ipScanOverride: String?): String {
        val parsed = load(context) ?: return builtinCoreJson(context, listenOverride, ipScanOverride)
        val base = JSONObject(CoreConfig.json(context, "wireguard", listenOverride, ipScanOverride))
        val identity = writeIdentity(context, parsed)
        base.put("wireguard_config_path", identity.absolutePath)
        base.remove("forced_peer")
        base.put("forced_peers", parsed.endpoints.joinToString(","))
        base.put("obfuscation_profile", "off")
        base.put(
            "obfuscation_parameters",
            JSONObject().put("jc", parsed.jc).put("jmin", parsed.jmin).put("jmax", parsed.jmax).toString(),
        )
        base.put("retry_obfuscation_profiles", false)
        // A Zero Trust team would make the core call the account API with this
        // imported identity, get it "refused" and re-register over the file.
        listOf("team", "access_client_id", "access_client_secret", "access_token", "access_email")
            .forEach { base.remove(it) }
        base.put("gateway", false)
        // The config's own resolvers, unless the user picked a gaming DNS preset
        // (the service's applyDns handles that choice).
        if (DnsSettings.preset(context) == DnsSettings.Preset.AUTO && parsed.dns.isNotEmpty()) {
            base.put("dns_servers", parsed.dns.joinToString(","))
        }
        return base.toString()
    }
}
