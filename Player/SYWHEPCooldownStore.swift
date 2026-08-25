//
//  SYWHEPCooldownStore.swift
//  SmartYardVideoPlayer
//
//  Created by Александр Попов on 10.08.2026.
//

import Foundation

struct SYWHEPCooldown {
    let remaining: TimeInterval
    let reason: String
}

final class SYWHEPCooldownStore {
    static let shared = SYWHEPCooldownStore()

    private struct Entry {
        let expiresAt: Date
        let reason: String
    }

    private let queue = DispatchQueue(label: "sy.player.whep-cooldown")
    private var entries: [String: Entry] = [:]

    private init() {}

    func activeCooldown(for endpointURL: URL) -> SYWHEPCooldown? {
        queue.sync {
            let key = endpointURL.syTransportCacheKey
            guard let entry = entries[key] else { return nil }

            let remaining = entry.expiresAt.timeIntervalSinceNow
            guard remaining > 0 else {
                entries.removeValue(forKey: key)
                return nil
            }

            return SYWHEPCooldown(remaining: remaining, reason: entry.reason)
        }
    }

    func recordFailure(endpointURL: URL, reason: String, duration: TimeInterval) {
        queue.sync {
            let key = endpointURL.syTransportCacheKey
            guard duration > 0 else {
                entries.removeValue(forKey: key)
                return
            }

            entries[key] = Entry(
                expiresAt: Date().addingTimeInterval(duration),
                reason: reason
            )
        }
    }

    @discardableResult
    func clear(endpointURL: URL) -> Bool {
        queue.sync {
            entries.removeValue(forKey: endpointURL.syTransportCacheKey) != nil
        }
    }
}
