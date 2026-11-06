package com.molido.vpn

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Ikev2VpnProfile
import android.net.VpnManager
import android.os.Build
import androidx.annotation.RequiresApi

/** Native Android IKEv2/IPsec manager backed by Android's platform VPN stack. */
@RequiresApi(Build.VERSION_CODES.R)
class NativeIkev2Manager(context: Context) {
    private val appContext = context.applicationContext
    private val vpnManager: VpnManager =
        appContext.getSystemService(VpnManager::class.java)
            ?: throw IllegalStateException("Android VpnManager is unavailable")

    data class Credentials(
        val username: String,
        val password: String,
        val identity: String,
    )

    fun isSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_IPSEC_TUNNELS)

    /** Installs/replaces the OS-managed profile and returns the optional consent Intent. */
    fun provision(serverHost: String, credentials: Credentials): Intent? {
        check(isSupported()) { "This Android device does not support platform IKEv2/IPsec" }
        require(validHost(serverHost)) { "Invalid IKEv2 server host" }
        require(credentials.username.isNotBlank()) { "IKEv2 username is required" }
        require(credentials.password.isNotEmpty()) { "IKEv2 password is required" }
        require(credentials.identity.isNotBlank()) { "IKEv2 identity is required" }

        val profile = Ikev2VpnProfile.Builder(serverHost, credentials.identity)
            .setAuthUsernamePassword(credentials.username, credentials.password, null)
            .setBypassable(false)
            .setMetered(false)
            .build()
        return vpnManager.provisionVpnProfile(profile)
    }

    /** Call only after the user has granted Android's VPN profile consent. */
    fun start(): String? {
        check(isSupported()) { "Platform IKEv2/IPsec is not supported" }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            vpnManager.startProvisionedVpnProfileSession()
        } else {
            @Suppress("DEPRECATION")
            vpnManager.startProvisionedVpnProfile()
            null
        }
    }

    fun stop() = vpnManager.stopProvisionedVpnProfile()

    fun removeProfile() {
        vpnManager.stopProvisionedVpnProfile()
        vpnManager.deleteProvisionedVpnProfile()
    }

    private fun validHost(value: String): Boolean {
        if (value.length !in 1..253 || value.any { it.isWhitespace() }) return false
        if (value.startsWith(".") || value.endsWith(".")) return false
        return value.matches(Regex("^[A-Za-z0-9.-]+$")) ||
            value.matches(Regex("^[0-9a-fA-F:]+$"))
    }
}
