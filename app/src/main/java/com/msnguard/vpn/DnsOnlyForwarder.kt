package com.msnguard.vpn

import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * DNS-only mode's data path.
 *
 * The TUN for this mode routes nothing but the gaming DNS server IPs (/32 each), so
 * the only packets that ever arrive here are resolver queries. Each IPv4/UDP query to
 * port 53 is re-sent from a protect()ed socket straight to the same server over the
 * normal internet, and the answer is wrapped back into an IPv4/UDP packet on the TUN.
 * Everything else (TCP 53, DoT 853, stray packets) is dropped; Android's resolver
 * falls back to UDP.
 */
class DnsOnlyForwarder(
    private val tun: ParcelFileDescriptor,
    private val protect: (DatagramSocket) -> Boolean,
) {
    private val running = AtomicBoolean(false)
    private var reader: Thread? = null
    private val pool: ExecutorService = Executors.newFixedThreadPool(4)
    private val out = FileOutputStream(tun.fileDescriptor)
    private val writeLock = Any()

    fun start() {
        if (!running.compareAndSet(false, true)) return
        reader = Thread({ readLoop() }, "MolidoDnsForwarder").apply { isDaemon = true; start() }
    }

    fun stop() {
        running.set(false)
        reader?.interrupt()
        reader = null
        pool.shutdownNow()
    }

    private fun readLoop() {
        val input = FileInputStream(tun.fileDescriptor)
        val buf = ByteArray(32767)
        while (running.get()) {
            val n = try {
                input.read(buf)
            } catch (e: Exception) {
                if (running.get()) Log.w(TAG, "tun read ended: ${e.message}")
                break
            }
            if (n <= 0) continue
            val packet = buf.copyOf(n)
            if (!isUdpDnsQuery(packet)) continue
            try {
                pool.execute { forward(packet) }
            } catch (_: Exception) {
                break
            }
        }
    }

    private fun isUdpDnsQuery(p: ByteArray): Boolean {
        if (p.size < 28) return false
        if ((p[0].toInt() ushr 4) != 4) return false
        if (p[9].toInt() != 17) return false
        val ihl = (p[0].toInt() and 0x0f) * 4
        if (p.size < ihl + 8) return false
        return u16(p, ihl + 2) == 53
    }

    private fun forward(p: ByteArray) {
        val ihl = (p[0].toInt() and 0x0f) * 4
        val srcIp = p.copyOfRange(12, 16)
        val dstIp = p.copyOfRange(16, 20)
        val srcPort = u16(p, ihl)
        val udpLen = u16(p, ihl + 4).coerceAtMost(p.size - ihl)
        if (udpLen < 8) return
        val payload = p.copyOfRange(ihl + 8, ihl + udpLen)
        try {
            DatagramSocket().use { socket ->
                if (!protect(socket)) {
                    Log.w(TAG, "protect() failed; dropping query")
                    return
                }
                socket.soTimeout = TIMEOUT_MS
                val server = InetAddress.getByAddress(dstIp)
                socket.send(DatagramPacket(payload, payload.size, server, 53))
                val reply = ByteArray(4096)
                val rp = DatagramPacket(reply, reply.size)
                socket.receive(rp)
                val answer = buildReply(dstIp, srcIp, srcPort, reply, rp.length)
                synchronized(writeLock) {
                    if (running.get()) out.write(answer)
                }
            }
        } catch (_: SocketTimeoutException) {
        } catch (e: Exception) {
            if (running.get()) Log.w(TAG, "forward failed: ${e.message}")
        }
    }

    /** IPv4 + UDP (checksum 0, valid for IPv4) from [from]:53 to [to]:[toPort]. */
    private fun buildReply(from: ByteArray, to: ByteArray, toPort: Int, data: ByteArray, len: Int): ByteArray {
        val total = 20 + 8 + len
        val r = ByteArray(total)
        r[0] = 0x45
        put16(r, 2, total)
        r[6] = 0x40 // don't fragment
        r[8] = 64
        r[9] = 17
        System.arraycopy(from, 0, r, 12, 4)
        System.arraycopy(to, 0, r, 16, 4)
        put16(r, 10, ipChecksum(r))
        put16(r, 20, 53)
        put16(r, 22, toPort)
        put16(r, 24, 8 + len)
        System.arraycopy(data, 0, r, 28, len)
        return r
    }

    private fun ipChecksum(r: ByteArray): Int {
        var sum = 0
        for (i in 0 until 20 step 2) sum += u16(r, i)
        while (sum ushr 16 != 0) sum = (sum and 0xffff) + (sum ushr 16)
        return sum.inv() and 0xffff
    }

    private fun u16(b: ByteArray, i: Int): Int = ((b[i].toInt() and 0xff) shl 8) or (b[i + 1].toInt() and 0xff)

    private fun put16(b: ByteArray, i: Int, v: Int) {
        b[i] = (v ushr 8).toByte()
        b[i + 1] = v.toByte()
    }

    companion object {
        private const val TAG = "MolidoDns"
        private const val TIMEOUT_MS = 4_000
    }
}
