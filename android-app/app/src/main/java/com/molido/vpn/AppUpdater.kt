package com.molido.vpn

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.appcompat.app.AlertDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * "Check for updates": tells the user a new version exists and hands the
 * download to the browser.
 *
 * ## Why it no longer installs the APK itself
 *
 * The previous version downloaded the APK into `cacheDir/updates` and invoked the
 * system installer through a `FileProvider` URI. That works, but it is also the
 * exact behavioural signature of an Android *dropper* — fetch a package at
 * runtime, then ask the platform to install it — and it required
 * `REQUEST_INSTALL_PACKAGES` in the manifest. Play Protect and the OEM scanners
 * flag both, and the manifest permission is the worse of the two because it is
 * visible from a static scan without the app ever running.
 *
 * So both signals are gone: no `REQUEST_INSTALL_PACKAGES`, no runtime APK
 * download, no call into the package installer. What is left is a version check
 * against the GitHub releases API and an ordinary `ACTION_VIEW` on an https URL,
 * which is indistinguishable from tapping a link.
 *
 * This does **not** remove the "unknown source / unknown developer" warning the
 * user sees when the browser's download is installed — that belongs to how the
 * app is distributed, not to this code. It removes the *scanner* signals only.
 *
 * ## Why the browser is sent to the asset, not the release page
 *
 * Every release carries two APKs (arm64-v8a and armeabi-v7a). On a release page a
 * user picks by hand, and picking the 32-bit build on a 64-bit phone is easy and
 * produces a working-but-slower install. [assetForAbi] already knows the right
 * one from `Build.SUPPORTED_ABIS`, so the browser is pointed straight at it. The
 * release page is only the fallback for when no matching asset is found.
 */
class AppUpdater(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var progressDialog: AlertDialog? = null
    private var busy = false

    /** [silent]: the launch-time check — no spinner, and only speaks up when a newer version exists. */
    fun checkForUpdate(silent: Boolean = false) {
        if (busy) return
        busy = true
        if (!silent) showProgress(Strings.t("Checking for updates"))
        worker.execute {
            val result = runCatching(::latestRelease)
            activity.runOnUiThread {
                dismissProgress()
                busy = false
                if (activity.isFinishing || activity.isDestroyed) return@runOnUiThread
                val release = result.getOrNull()
                if (silent) {
                    if (release != null && isNewer(release.version, appVersion())) announceUpdate(release)
                    return@runOnUiThread
                }
                result.onFailure { showMessage(Strings.t("Update check failed"), it.message ?: Strings.t("Try again later")) }
                    .onSuccess { found ->
                        when {
                            found == null -> showMessage(Strings.t("No update available"), Strings.t("No compatible release was found"))
                            !isNewer(found.version, appVersion()) ->
                                showMessage(Strings.t("You're up to date"), Strings.tf("MolidoVPN %s is installed", appVersion()))
                            else -> announceUpdate(found)
                        }
                    }
            }
        }
    }

    /**
     * The new-version notice.
     *
     * Deliberately says the download opens in the browser. A user who taps
     * "Update" and lands in Chrome without warning assumes the app misbehaved;
     * saying it up front makes the browser hand-off read as intentional.
     */
    private fun announceUpdate(release: Release) {
        dialogBuilder()
            .setTitle(Strings.t("Update available"))
            .setMessage(
                Strings.tf("MolidoVPN %s has been released. You are on %s.", release.version, appVersion()) + "\n\n" +
                    Strings.t("Tapping Update opens the download in your browser. Open the downloaded file to install it.")
            )
            .setNegativeButton(Strings.t("Later"), null)
            .setPositiveButton(Strings.t("Update")) { _, _ -> openDownload(release) }
            .show()
    }

    private fun openDownload(release: Release) {
        val opened = openLink(release.downloadUrl)
        if (!opened) {
            // No browser resolved the direct asset URL. The release page is served
            // by the same host, so if this fails too there is no usable browser at
            // all — worth saying rather than failing silently.
            if (!openLink(RELEASES_PAGE_URL)) {
                showMessage(Strings.t("No browser found"), Strings.t("Install a browser, then download the update from GitHub."))
            }
        }
    }

    private fun openLink(url: String): Boolean = try {
        activity.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (_: ActivityNotFoundException) {
        false
    }

    /** Our Cloudflare worker first (reachable where GitHub is filtered), then GitHub itself. */
    private fun latestRelease(): Release? {
        var lastError: Exception? = null
        for (url in listOf(MIRROR_RELEASE_URL, RELEASE_URL)) {
            try {
                return fetchRelease(url)
            } catch (error: Exception) {
                lastError = error
            }
        }
        throw lastError ?: IllegalStateException("no release source")
    }

    private fun fetchRelease(url: String): Release? {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 20_000
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "MolidoVPN-Android")
        }
        try {
            if (connection.responseCode == HttpURLConnection.HTTP_NOT_FOUND) return null
            check(connection.responseCode == HttpURLConnection.HTTP_OK) { "GitHub returned ${connection.responseCode}" }
            val json = JSONObject(connection.inputStream.bufferedReader().use { reader -> reader.readText() })
            val version = json.getString("tag_name").removePrefix("v")
            val assets = json.getJSONArray("assets")
            val apk = Build.SUPPORTED_ABIS.asSequence()
                .mapNotNull { abi -> assetForAbi(assets, abi) }
                .firstOrNull()
                ?: return null
            return Release(version, apk.first, apk.second)
        } finally {
            connection.disconnect()
        }
    }

    private fun assetForAbi(assets: org.json.JSONArray, abi: String): Pair<String, String>? {
        // MolidoVPN release assets are named MobinVPN-android-arm64.apk / -armv7.apk / -universal.apk.
        val token = when (abi) {
            "arm64-v8a" -> "android-arm64"
            "armeabi-v7a" -> "android-armv7"
            else -> "android-universal"
        }
        for (index in 0 until assets.length()) {
            val asset = assets.getJSONObject(index)
            val name = asset.getString("name")
            if (name.endsWith(".apk") && name.contains(token, ignoreCase = true)) {
                return name to asset.getString("browser_download_url")
            }
        }
        return null
    }

    /**
     * Indeterminate spinner for the version check.
     *
     * There is no determinate case left now that the APK download belongs to the
     * browser, so the old `indeterminate` parameter and the progress-percentage
     * plumbing are gone with it.
     */
    private fun showProgress(title: String) {
        val layout = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), dp(8))
        }
        layout.addView(ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true
            max = 100
        })
        progressDialog = dialogBuilder()
            .setTitle(title)
            .setView(layout)
            .setCancelable(false)
            .create()
            .also { it.show() }
    }

    private fun dismissProgress() {
        progressDialog?.dismiss()
        progressDialog = null
    }

    private fun showMessage(title: String, message: String) {
        dialogBuilder().setTitle(title).setMessage(message).setPositiveButton(Strings.t("OK"), null).show()
    }

    // The overlay is picked per palette. Passing a fixed one here overrides the
    // activity theme's own `materialAlertDialogTheme`, so on Porcelain the
    // updater was the one black dialog in an otherwise white app.
    private fun dialogBuilder() = MaterialAlertDialogBuilder(
        activity,
        if (AppAppearance.isNight(activity)) R.style.ThemeOverlay_Molido_AlertDialog
        else R.style.ThemeOverlay_Molido_Light_AlertDialog,
    )

    private fun appVersion(): String = activity.packageManager
        .getPackageInfo(activity.packageName, 0).versionName ?: "0.0.0"

    private fun dp(value: Int): Int = (value * activity.resources.displayMetrics.density).toInt()

    private data class Release(val version: String, val assetName: String, val downloadUrl: String)

    private companion object {
        const val RELEASE_HOST = "api.github.com"
        const val MIRROR_RELEASE_URL = "https://molido-sub.hidooch980.workers.dev/app/latest.json"
        const val RELEASE_URL ="https://$RELEASE_HOST/repos/hidooch980/molidovpn/releases/latest"
        const val RELEASES_PAGE_URL = "https://github.com/hidooch980/molidovpn/releases/latest"

        fun isNewer(remote: String, local: String): Boolean {
            val remoteParts = remote.split('.', '-', '+').map { it.toIntOrNull() ?: 0 }
            val localParts = local.split('.', '-', '+').map { it.toIntOrNull() ?: 0 }
            for (index in 0 until maxOf(remoteParts.size, localParts.size)) {
                val comparison = remoteParts.getOrElse(index) { 0 }.compareTo(localParts.getOrElse(index) { 0 })
                if (comparison != 0) return comparison > 0
            }
            return false
        }
    }
}
