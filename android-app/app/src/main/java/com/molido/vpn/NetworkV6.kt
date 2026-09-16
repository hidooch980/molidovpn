package com.molido.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet6Address

/**
 * Whether the underlying (non-VPN) network has a global IPv6 address.
 *
 * Used only to widen retries/scans (Auto's WARP candidates, the clean-IP scan);
 * a false answer leaves every IPv4-only behaviour exactly as before.
 */
object NetworkV6 {

    fun hasGlobalIpv6(context: Context): Boolean = try {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        @Suppress("DEPRECATION")
        val networks = cm.allNetworks
        networks.any { network ->
            val caps = cm.getNetworkCapabilities(network) ?: return@any false
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@any false
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return@any false
            val link = cm.getLinkProperties(network) ?: return@any false
            val hasAddress = link.linkAddresses.any { la ->
                val a = la.address
                a is Inet6Address && !a.isLinkLocalAddress && !a.isSiteLocalAddress &&
                    !a.isLoopbackAddress && (a.address[0].toInt() and 0xfe) != 0xfc
            }
            // A default v6 route, so the address is actually usable outward.
            hasAddress && link.routes.any { r -> r.isDefaultRoute && r.destination.address is Inet6Address }
        }
    } catch (_: Exception) {
        false
    }
}
