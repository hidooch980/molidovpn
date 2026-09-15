package com.molido.vpn

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Donate options, fetched from remote/donate.json so the owner can change them
 * without a release. The last good copy is cached in filesDir; a bundled
 * default is used when neither network nor cache is available.
 */
object Donate {
    data class Item(val label: String, val value: String, val url: String)
    data class Info(
        val titleFa: String,
        val titleEn: String,
        val textFa: String,
        val textEn: String,
        val items: List<Item>,
    )

    const val TELEGRAM_HANDLE = "Molido_Vpn"
    private const val CACHE_FILE = "donate.json"
    private val SOURCES = listOf(
        "https://raw.githubusercontent.com/hidooch980/molidovpn-android/main/remote/donate.json",
        "https://cdn.jsdelivr.net/gh/hidooch980/molidovpn-android@main/remote/donate.json",
    )

    private val DEFAULT = Info(
        titleFa = "حمایت مالی",
        titleEn = "Donate",
        textFa = "برای دریافت روش‌های حمایت مالی به پشتیبانی تلگرام پیام دهید.",
        textEn = "Message our Telegram support to get donation methods.",
        items = listOf(Item("Telegram", "@$TELEGRAM_HANDLE", "https://t.me/$TELEGRAM_HANDLE")),
    )

    fun cached(context: Context): Info =
        runCatching { parse(File(context.filesDir, CACHE_FILE).readText()) }.getOrNull() ?: DEFAULT

    /** Blocking: call off the main thread. Returns fresh info, else cached/default. */
    fun fetch(context: Context): Info {
        for (source in SOURCES) {
            val body = runCatching {
                val connection = URL(source).openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = 8000
                    connection.readTimeout = 8000
                    connection.setRequestProperty("User-Agent", "MolidoVPN-Android")
                    if (connection.responseCode != 200) null
                    else connection.inputStream.bufferedReader().use { it.readText() }
                } finally {
                    connection.disconnect()
                }
            }.getOrNull() ?: continue
            val info = runCatching { parse(body) }.getOrNull() ?: continue
            runCatching { File(context.filesDir, CACHE_FILE).writeText(body) }
            return info
        }
        return cached(context)
    }

    private fun parse(text: String): Info {
        val json = JSONObject(text)
        val array = json.optJSONArray("items")
        val items = buildList {
            if (array != null) for (i in 0 until array.length()) {
                val o = array.optJSONObject(i) ?: continue
                val label = o.optString("label").trim()
                val value = o.optString("value").trim()
                if (label.isEmpty() && value.isEmpty()) continue
                val url = o.optString("url").trim().takeIf { it.startsWith("https://") } ?: ""
                add(Item(label, value, url))
            }
        }
        return Info(
            titleFa = json.optString("title_fa").ifBlank { DEFAULT.titleFa },
            titleEn = json.optString("title_en").ifBlank { DEFAULT.titleEn },
            textFa = json.optString("text_fa"),
            textEn = json.optString("text_en"),
            items = items,
        )
    }
}
