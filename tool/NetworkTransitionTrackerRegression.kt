package com.follow.clash.service

// Run with the real Kotlin/JVM toolchain; no Android framework dependency.
fun main() {
    val tracker = NetworkTransitionTracker<String>()
    check(!tracker.update(null))
    check(!tracker.update("wifi"))
    check(!tracker.update("wifi"))
    check(tracker.update("cellular"))
    check(!tracker.update(null))
    check(tracker.update("wifi"))
    check(!tracker.update(null))
    check(tracker.update("wifi"))
    check(!tracker.update("wifi"))
    println("Network transition scenarios passed")
}
