package com.follow.clash.service

/** Tracks first connection separately from reconnecting after an offline gap. */
internal class NetworkTransitionTracker<T> {
    private var hasConnected = false
    private var current: T? = null

    @Synchronized
    fun update(next: T?): Boolean {
        if (next == null) {
            current = null
            return false
        }
        val recover = hasConnected && current != next
        current = next
        hasConnected = true
        return recover
    }
}
