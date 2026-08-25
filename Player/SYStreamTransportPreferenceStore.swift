//
//  SYStreamTransportPreferenceStore.swift
//  SmartYardVideoPlayer
//
//  Created by Александр Попов on 24.08.2026.
//

import Foundation

enum SYPreferredHLSMode: Equatable {
    case standard
    case lowLatency
}

final class SYStreamTransportPreferenceStore {
    static let shared = SYStreamTransportPreferenceStore()

    private struct PreferenceEntry {
        let mode: SYPreferredHLSMode
        let expiresAt: Date
    }

    private let queue = DispatchQueue(label: "sy.player.stream-transport-preference")
    private var preferences: [String: PreferenceEntry] = [:]
    private var lowLatencyCooldowns: [String: Date] = [:]

    private init() {}

    func preferredHLSMode(for url: URL) -> SYPreferredHLSMode? {
        withStreamKey(for: url) { key in
            lowLatencyCooldowns[key] == nil ? preferences[key]?.mode : .standard
        }
    }

    func recordLowLatencyAvailability(
        for url: URL,
        duration: TimeInterval
    ) {
        withStreamKey(for: url) { key in
            guard lowLatencyCooldowns[key] == nil else { return }
            setPreference(.lowLatency, for: key, duration: duration)
        }
    }

    func recordSuccessfulPlayback(
        _ mode: SYPreferredHLSMode,
        for url: URL,
        duration: TimeInterval
    ) {
        withStreamKey(for: url) { key in
            if mode == .standard, preferences[key]?.mode == .lowLatency {
                return
            }
            if mode == .lowLatency {
                lowLatencyCooldowns.removeValue(forKey: key)
            }
            setPreference(mode, for: key, duration: duration)
        }
    }

    func recordLowLatencyFailure(
        for url: URL,
        cooldown: TimeInterval,
        preferenceDuration: TimeInterval
    ) {
        withStreamKey(for: url) { key in
            lowLatencyCooldowns[key] = cooldown > 0
                ? Date().addingTimeInterval(cooldown)
                : nil
            setPreference(.standard, for: key, duration: preferenceDuration)
        }
    }
}

private extension SYStreamTransportPreferenceStore {
    func setPreference(
        _ mode: SYPreferredHLSMode,
        for key: String,
        duration: TimeInterval
    ) {
        preferences[key] = duration > 0
            ? PreferenceEntry(
                mode: mode,
                expiresAt: Date().addingTimeInterval(duration)
            )
            : nil
    }

    func cleanupExpiredEntries(for key: String) {
        if let preference = preferences[key], preference.expiresAt <= Date() {
            preferences.removeValue(forKey: key)
        }
        if let cooldown = lowLatencyCooldowns[key], cooldown <= Date() {
            lowLatencyCooldowns.removeValue(forKey: key)
        }
    }

    func withStreamKey<T>(for url: URL, _ action: (String) -> T) -> T {
        queue.sync {
            let key = url.syTransportCacheKey
            cleanupExpiredEntries(for: key)
            return action(key)
        }
    }
}

extension URL {
    var syTransportCacheKey: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? absoluteString
    }
}
