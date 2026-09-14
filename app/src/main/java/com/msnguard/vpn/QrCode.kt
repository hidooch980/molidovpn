/*
 * QR Code generator library (Kotlin port, trimmed)
 *
 * Copyright (c) Project Nayuki. (MIT License)
 * https://www.nayuki.io/page/qr-code-generator-library
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 * - The above copyright notice and this permission notice shall be included in
 *   all copies or substantial portions of the Software.
 * - The Software is provided "as is", without warranty of any kind, express or
 *   implied, including but not limited to the warranties of merchantability,
 *   fitness for a particular purpose and noninfringement. In no event shall the
 *   authors or copyright holders be liable for any claim, damages or other
 *   liability, whether in an action of contract, tort or otherwise, arising from,
 *   out of or in connection with the Software or the use or other dealings in the
 *   Software.
 *
 * Trimmed for MolidoVPN: byte mode only, error correction level M only,
 * versions 1-15, plus a Bitmap renderer.
 */
package com.msnguard.vpn

import android.graphics.Bitmap
import android.graphics.Color
import kotlin.math.abs
import kotlin.math.max

class QrCode private constructor(val version: Int, dataCodewords: ByteArray) {

    val size: Int = version * 4 + 17
    private val modules = Array(size) { BooleanArray(size) }
    private val isFunction = Array(size) { BooleanArray(size) }

    init {
        drawFunctionPatterns()
        val allCodewords = addEccAndInterleave(dataCodewords)
        drawCodewords(allCodewords)
        var bestMask = 0
        var minPenalty = Int.MAX_VALUE
        for (mask in 0 until 8) {
            applyMask(mask)
            drawFormatBits(mask)
            val penalty = penaltyScore()
            if (penalty < minPenalty) {
                bestMask = mask
                minPenalty = penalty
            }
            applyMask(mask) // XOR undoes it
        }
        applyMask(bestMask)
        drawFormatBits(bestMask)
    }

    /** True for a dark module; out-of-range coordinates are light. */
    fun getModule(x: Int, y: Int): Boolean = x in 0 until size && y in 0 until size && modules[y][x]

    /** Renders with [scale] pixels per module and a [border]-module quiet zone. */
    fun toBitmap(scale: Int, border: Int = 4, dark: Int = Color.BLACK, light: Int = Color.WHITE): Bitmap {
        val dim = (size + border * 2) * scale
        val pixels = IntArray(dim * dim)
        for (py in 0 until dim) {
            val my = py / scale - border
            for (px in 0 until dim) {
                pixels[py * dim + px] = if (getModule(px / scale - border, my)) dark else light
            }
        }
        return Bitmap.createBitmap(pixels, dim, dim, Bitmap.Config.ARGB_8888)
    }

    private fun setFunctionModule(x: Int, y: Int, dark: Boolean) {
        modules[y][x] = dark
        isFunction[y][x] = true
    }

    private fun drawFunctionPatterns() {
        for (i in 0 until size) {
            setFunctionModule(6, i, i % 2 == 0)
            setFunctionModule(i, 6, i % 2 == 0)
        }
        drawFinderPattern(3, 3)
        drawFinderPattern(size - 4, 3)
        drawFinderPattern(3, size - 4)
        val alignPos = alignmentPatternPositions()
        val numAlign = alignPos.size
        for (i in 0 until numAlign) {
            for (j in 0 until numAlign) {
                if (!(i == 0 && j == 0 || i == 0 && j == numAlign - 1 || i == numAlign - 1 && j == 0)) {
                    drawAlignmentPattern(alignPos[i], alignPos[j])
                }
            }
        }
        drawFormatBits(0)
        drawVersion()
    }

    private fun drawFormatBits(mask: Int) {
        val data = (ECC_M_FORMAT_BITS shl 3) or mask
        var rem = data
        repeat(10) { rem = (rem shl 1) xor ((rem ushr 9) * 0x537) }
        val bits = ((data shl 10) or rem) xor 0x5412

        for (i in 0..5) setFunctionModule(8, i, getBit(bits, i))
        setFunctionModule(8, 7, getBit(bits, 6))
        setFunctionModule(8, 8, getBit(bits, 7))
        setFunctionModule(7, 8, getBit(bits, 8))
        for (i in 9 until 15) setFunctionModule(14 - i, 8, getBit(bits, i))

        for (i in 0 until 8) setFunctionModule(size - 1 - i, 8, getBit(bits, i))
        for (i in 8 until 15) setFunctionModule(8, size - 15 + i, getBit(bits, i))
        setFunctionModule(8, size - 8, true)
    }

    private fun drawVersion() {
        if (version < 7) return
        var rem = version
        repeat(12) { rem = (rem shl 1) xor ((rem ushr 11) * 0x1F25) }
        val bits = (version shl 12) or rem
        for (i in 0 until 18) {
            val bit = getBit(bits, i)
            val a = size - 11 + i % 3
            val b = i / 3
            setFunctionModule(a, b, bit)
            setFunctionModule(b, a, bit)
        }
    }

    private fun drawFinderPattern(x: Int, y: Int) {
        for (dy in -4..4) {
            for (dx in -4..4) {
                val dist = max(abs(dx), abs(dy))
                val xx = x + dx
                val yy = y + dy
                if (xx in 0 until size && yy in 0 until size) setFunctionModule(xx, yy, dist != 2 && dist != 4)
            }
        }
    }

    private fun drawAlignmentPattern(x: Int, y: Int) {
        for (dy in -2..2) {
            for (dx in -2..2) setFunctionModule(x + dx, y + dy, max(abs(dx), abs(dy)) != 1)
        }
    }

    private fun addEccAndInterleave(data: ByteArray): ByteArray {
        val numBlocks = NUM_ERROR_CORRECTION_BLOCKS[version]
        val blockEccLen = ECC_CODEWORDS_PER_BLOCK[version]
        val rawCodewords = numRawDataModules(version) / 8
        val numShortBlocks = numBlocks - rawCodewords % numBlocks
        val shortBlockLen = rawCodewords / numBlocks

        val blocks = arrayOfNulls<ByteArray>(numBlocks)
        val rsDiv = reedSolomonComputeDivisor(blockEccLen)
        var k = 0
        for (i in 0 until numBlocks) {
            val datLen = shortBlockLen - blockEccLen + if (i < numShortBlocks) 0 else 1
            val dat = data.copyOfRange(k, k + datLen)
            k += datLen
            val block = dat.copyOf(shortBlockLen + 1)
            val ecc = reedSolomonComputeRemainder(dat, rsDiv)
            System.arraycopy(ecc, 0, block, block.size - blockEccLen, ecc.size)
            blocks[i] = block
        }

        val result = ByteArray(rawCodewords)
        k = 0
        for (i in 0 until shortBlockLen + 1) {
            for (j in 0 until numBlocks) {
                // Skip the padding byte in short blocks.
                if (i != shortBlockLen - blockEccLen || j >= numShortBlocks) {
                    result[k++] = blocks[j]!![i]
                }
            }
        }
        return result
    }

    private fun drawCodewords(data: ByteArray) {
        var i = 0
        var right = size - 1
        while (right >= 1) {
            if (right == 6) right = 5
            for (vert in 0 until size) {
                for (j in 0 until 2) {
                    val x = right - j
                    val upward = ((right + 1) and 2) == 0
                    val y = if (upward) size - 1 - vert else vert
                    if (!isFunction[y][x] && i < data.size * 8) {
                        modules[y][x] = getBit(data[i ushr 3].toInt(), 7 - (i and 7))
                        i++
                    }
                }
            }
            right -= 2
        }
    }

    private fun applyMask(mask: Int) {
        for (y in 0 until size) {
            for (x in 0 until size) {
                val invert = when (mask) {
                    0 -> (x + y) % 2 == 0
                    1 -> y % 2 == 0
                    2 -> x % 3 == 0
                    3 -> (x + y) % 3 == 0
                    4 -> (x / 3 + y / 2) % 2 == 0
                    5 -> x * y % 2 + x * y % 3 == 0
                    6 -> (x * y % 2 + x * y % 3) % 2 == 0
                    else -> ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                modules[y][x] = modules[y][x] xor (invert && !isFunction[y][x])
            }
        }
    }

    /**
     * Mask penalty (N1 runs, N2 2x2 blocks, N3 finder-like 1:1:3:1:1 patterns,
     * N4 dark balance). Every mask yields a valid symbol; this only picks the most
     * readable one.
     */
    private fun penaltyScore(): Int {
        var result = 0
        fun line(get: (Int) -> Boolean) {
            var runColor = false
            var run = 0
            for (i in 0 until size) {
                val c = get(i)
                if (i > 0 && c == runColor) {
                    run++
                    if (run == 5) result += PENALTY_N1 else if (run > 5) result++
                } else {
                    runColor = c
                    run = 1
                }
            }
            for (i in 0..size - 7) {
                if (get(i) && !get(i + 1) && get(i + 2) && get(i + 3) && get(i + 4) && !get(i + 5) && get(i + 6)) {
                    val lightBefore = (i - 4 until i).all { it < 0 || !get(it) }
                    val lightAfter = (i + 7 until i + 11).all { it >= size || !get(it) }
                    if (lightBefore || lightAfter) result += PENALTY_N3
                }
            }
        }
        for (y in 0 until size) line { modules[y][it] }
        for (x in 0 until size) line { modules[it][x] }
        for (y in 0 until size - 1) {
            for (x in 0 until size - 1) {
                val c = modules[y][x]
                if (c == modules[y][x + 1] && c == modules[y + 1][x] && c == modules[y + 1][x + 1]) result += PENALTY_N2
            }
        }
        var dark = 0
        for (row in modules) for (c in row) if (c) dark++
        val total = size * size
        val k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
        result += max(0, k) * PENALTY_N4
        return result
    }

    private fun alignmentPatternPositions(): IntArray {
        if (version == 1) return IntArray(0)
        val numAlign = version / 7 + 2
        val step = (version * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4) * 2
        val result = IntArray(numAlign)
        result[0] = 6
        var i = numAlign - 1
        var pos = size - 7
        while (i >= 1) {
            result[i] = pos
            i--
            pos -= step
        }
        return result
    }

    companion object {
        const val MIN_VERSION = 1
        const val MAX_VERSION = 15

        /** Format bits of error correction level M. */
        private const val ECC_M_FORMAT_BITS = 0

        private const val PENALTY_N1 = 3
        private const val PENALTY_N2 = 3
        private const val PENALTY_N3 = 40
        private const val PENALTY_N4 = 10

        // Level M only, index = version (0 unused).
        private val ECC_CODEWORDS_PER_BLOCK = intArrayOf(-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24)
        private val NUM_ERROR_CORRECTION_BLOCKS = intArrayOf(-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10)

        /** Encodes [text] as UTF-8 bytes; null when it does not fit version 15-M. */
        fun encodeText(text: String): QrCode? = encodeBytes(text.toByteArray(Charsets.UTF_8))

        fun encodeBytes(data: ByteArray): QrCode? {
            var version = MIN_VERSION
            while (true) {
                val capacityBits = numDataCodewords(version) * 8
                val ccBits = if (version <= 9) 8 else 16
                if (data.size < (1 shl ccBits) && 4 + ccBits + data.size * 8 <= capacityBits) break
                if (version >= MAX_VERSION) return null
                version++
            }
            val capacityBits = numDataCodewords(version) * 8
            val bits = BitBuffer()
            bits.append(0x4, 4)
            bits.append(data.size, if (version <= 9) 8 else 16)
            for (b in data) bits.append(b.toInt() and 0xFF, 8)
            bits.append(0, minOf(4, capacityBits - bits.length))
            bits.append(0, (8 - bits.length % 8) % 8)
            var pad = 0xEC
            while (bits.length < capacityBits) {
                bits.append(pad, 8)
                pad = pad xor 0xEC xor 0x11
            }
            val codewords = ByteArray(bits.length / 8)
            for (i in 0 until bits.length) {
                if (bits.get(i)) codewords[i ushr 3] = (codewords[i ushr 3].toInt() or (1 shl (7 - (i and 7)))).toByte()
            }
            return QrCode(version, codewords)
        }

        private fun numRawDataModules(ver: Int): Int {
            var result = (16 * ver + 128) * ver + 64
            if (ver >= 2) {
                val numAlign = ver / 7 + 2
                result -= (25 * numAlign - 10) * numAlign - 55
                if (ver >= 7) result -= 36
            }
            return result
        }

        private fun numDataCodewords(ver: Int): Int =
            numRawDataModules(ver) / 8 - ECC_CODEWORDS_PER_BLOCK[ver] * NUM_ERROR_CORRECTION_BLOCKS[ver]

        private fun reedSolomonComputeDivisor(degree: Int): ByteArray {
            val result = ByteArray(degree)
            result[degree - 1] = 1
            var root = 1
            for (i in 0 until degree) {
                for (j in result.indices) {
                    var v = reedSolomonMultiply(result[j].toInt() and 0xFF, root)
                    if (j + 1 < result.size) v = v xor (result[j + 1].toInt() and 0xFF)
                    result[j] = v.toByte()
                }
                root = reedSolomonMultiply(root, 0x02)
            }
            return result
        }

        private fun reedSolomonComputeRemainder(data: ByteArray, divisor: ByteArray): ByteArray {
            val result = ByteArray(divisor.size)
            for (b in data) {
                val factor = (b.toInt() xor result[0].toInt()) and 0xFF
                System.arraycopy(result, 1, result, 0, result.size - 1)
                result[result.size - 1] = 0
                for (i in result.indices) {
                    result[i] = (result[i].toInt() xor reedSolomonMultiply(divisor[i].toInt() and 0xFF, factor)).toByte()
                }
            }
            return result
        }

        private fun reedSolomonMultiply(x: Int, y: Int): Int {
            var z = 0
            for (i in 7 downTo 0) {
                z = (z shl 1) xor ((z ushr 7) * 0x11D)
                z = z xor (((y ushr i) and 1) * x)
            }
            return z
        }

        private fun getBit(x: Int, i: Int): Boolean = ((x ushr i) and 1) != 0
    }

    private class BitBuffer {
        private val bits = java.util.BitSet()
        var length = 0
            private set

        fun append(value: Int, count: Int) {
            for (i in count - 1 downTo 0) {
                if (((value ushr i) and 1) != 0) bits.set(length)
                length++
            }
        }

        fun get(i: Int): Boolean = bits.get(i)
    }
}
