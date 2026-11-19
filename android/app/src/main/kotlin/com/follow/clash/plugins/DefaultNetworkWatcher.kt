package com.follow.clash.plugins

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import com.follow.clash.common.GlobalState

// Watches physical and VPN network states to notify Flutter of connectivity transitions.
class DefaultNetworkWatcher(
    private val connectivity: ConnectivityManager,
    private val onChanged: (Map<String, Boolean>) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val report = Runnable { onChanged(state()) }
    private var registered = false

    private val request = NetworkRequest.Builder().build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = schedule()

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            schedule()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            schedule()
        }

        override fun onLost(network: Network) = schedule()
    }

    fun start() {
        if (registered) return
        runCatching { connectivity.registerNetworkCallback(request, callback) }
            .onSuccess { registered = true }
            .onFailure { error -> GlobalState.log("Unable to watch networks: $error") }
        handler.post(report)
    }

    fun stop() {
        handler.removeCallbacks(report)
        if (!registered) return
        runCatching { connectivity.unregisterNetworkCallback(callback) }
        registered = false
    }

    fun notifyChanged() {
        schedule()
    }

    private fun schedule() {
        handler.removeCallbacks(report)
        handler.postDelayed(report, SETTLE_MILLIS)
    }

    private fun state(): Map<String, Boolean> {
        var isWifi = false
        var isVpn = false
        val networks = runCatching { connectivity.allNetworks }.getOrNull() ?: emptyArray()
        for (network in networks) {
            val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                isVpn = true
            }
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI_AWARE))
            ) {
                isWifi = true
            }
        }
        return mapOf(
            "wifi" to isWifi,
            "vpn" to isVpn,
        )
    }
}

private const val SETTLE_MILLIS = 500L
