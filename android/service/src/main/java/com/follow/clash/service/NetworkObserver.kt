package com.follow.clash.service

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkCapabilities.TRANSPORT_SATELLITE
import android.net.NetworkCapabilities.TRANSPORT_USB
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import androidx.core.content.getSystemService
import com.follow.clash.common.GlobalState
import com.follow.clash.core.Core
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap

private data class CapabilitySnapshot(
    val basePriority: Int = 100,
    val hasInternet: Boolean = false,
    val isValidated: Boolean = false,
)

private data class NetworkInfo(
    @Volatile var losingUntilMillis: Long = 0,
    @Volatile var dnsList: List<InetAddress> = emptyList(),
    @Volatile var capabilitySnapshot: CapabilitySnapshot? = null,
) {
    val priorityPenalty: Int
        get() = if (losingUntilMillis > System.currentTimeMillis()) 10 else 0
}

object NetworkObserver {

    private val networkInfos = ConcurrentHashMap<Network, NetworkInfo>()
    private val connectivity by lazy {
        GlobalState.application.getSystemService<ConnectivityManager>()
    }
    private val handler by lazy {
        Handler(HandlerThread("NetworkObserve").apply { start() }.looper)
    }

    @Volatile
    private var currentDnsList = listOf<String>()

    private val networkTransitions = NetworkTransitionTracker<Network>()

    @Volatile
    private var started = false

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            addCapability(NetworkCapabilities.NET_CAPABILITY_FOREGROUND)
        }
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
    }.build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            networkInfos[network] = NetworkInfo(
                capabilitySnapshot = connectivity?.getNetworkCapabilities(network)?.toSnapshot(),
            )
            scheduleUpdateDns()
        }

        override fun onLosing(network: Network, maxMsToLive: Int) {
            val info = networkInfos[network] ?: return
            info.losingUntilMillis = System.currentTimeMillis() + maxMsToLive
            scheduleUpdateDns()
            if (maxMsToLive > 0) {
                handler.postDelayed({
                    if (networkInfos.containsKey(network)) {
                        updateDns()
                    }
                }, maxMsToLive.toLong() + 50)
            }
        }

        override fun onLost(network: Network) {
            networkInfos.remove(network)
            scheduleUpdateDns()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val info = networkInfos[network] ?: return
            val nextDns = linkProperties.dnsServers
            if (info.dnsList != nextDns) {
                info.dnsList = nextDns
                scheduleUpdateDns()
            }
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            val info = networkInfos[network] ?: return
            val nextSnapshot = networkCapabilities.toSnapshot()
            // 仅当传输类型或联网校验状态发生实质改变时才调度，忽略信号强度 RSSI 波动
            if (info.capabilitySnapshot != nextSnapshot) {
                info.capabilitySnapshot = nextSnapshot
                scheduleUpdateDns()
            }
        }
    }

    private val updateDnsTask = Runnable(::updateDns)

    private fun scheduleUpdateDns() {
        handler.removeCallbacks(updateDnsTask)
        handler.postDelayed(updateDnsTask, DNS_UPDATE_DELAY_MILLIS)
    }

    @Synchronized
    fun start() {
        if (started) {
            handler.post(::updateDns)
            return
        }
        runCatching { requireNotNull(connectivity).registerNetworkCallback(request, callback) }
            .onSuccess { started = true }
            .onFailure { error -> GlobalState.log("Unable to observe networks: $error") }
    }

    @Synchronized
    fun reset() {
        // 仅移除待执行的延时任务，保留已注册网络的拓扑与 DNS 缓存
        handler.removeCallbacks(updateDnsTask)
    }

    private fun NetworkCapabilities.toSnapshot(): CapabilitySnapshot {
        val base = when {
            hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> 90
            hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
            hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 1
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                hasTransport(TRANSPORT_USB) -> 2
            hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> 3
            hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 4
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
                hasTransport(TRANSPORT_SATELLITE) -> 5
            else -> 20
        }
        return CapabilitySnapshot(
            basePriority = base,
            hasInternet = hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            isValidated = hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
        )
    }

    private fun networkPriority(entry: Map.Entry<Network, NetworkInfo>): Int {
        val snapshot = entry.value.capabilitySnapshot
            ?: connectivity?.getNetworkCapabilities(entry.key)?.toSnapshot()
            ?: return 1000
        val internetPenalty = if (snapshot.hasInternet) 0 else 500
        val validatedPenalty = if (snapshot.isValidated) 0 else 50
        return snapshot.basePriority + internetPenalty + validatedPenalty + entry.value.priorityPenalty
    }

    @Synchronized
    private fun updateDns() {
        val preferred = networkInfos.entries.minByOrNull(::networkPriority)
        val dnsList = preferred
            ?.value
            ?.dnsList
            .orEmpty()
            .map { address -> address.asSocketAddressText(DNS_PORT) }
            .distinct()
        if (dnsList != currentDnsList) {
            currentDnsList = dnsList
            Core.updateDNS(dnsList.joinToString(","))
        }
        val network = preferred?.key
        if (networkTransitions.update(network)) {
            Core.resetNetwork()
        }
    }
}

private const val DNS_PORT = 53
private const val DNS_UPDATE_DELAY_MILLIS = 200L

private fun InetAddress.asSocketAddressText(port: Int): String = when (this) {
    is Inet6Address -> "[$hostAddress]:$port"
    is Inet4Address -> "$hostAddress:$port"
    else -> error("Unsupported address type: ${javaClass.name}")
}
