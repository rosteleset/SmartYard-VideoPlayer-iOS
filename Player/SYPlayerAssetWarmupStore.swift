//
//  SYPlayerAssetWarmupStore.swift
//  SmartYard
//
//  Created by Александр Попов on 20.03.2026.
//

import Foundation
import AVFoundation

public final class SYPlayerAssetWarmupStore {
    public static let shared = SYPlayerAssetWarmupStore()

    public var isEnabled: Bool = true
    public var ttl: TimeInterval = 120

    private struct Entry {
        let asset: AVURLAsset
        var expiresAt: Date
    }

    private let queue = DispatchQueue(label: "sy.player.asset-warmup", qos: .utility)
    private let keysToLoad = ["playable", "tracks", "duration"]
    private var entries: [String: Entry] = [:]

    private init() {}

    public func warmup(url: URL, options: [String: Any]? = nil) {
        guard isEnabled, !url.isFileURL else { return }

        let key = cacheKey(for: url)
        queue.async { [weak self] in
            guard let self else { return }
            cleanupExpiredLocked()

            if var existing = entries[key], existing.expiresAt > Date() {
                existing.expiresAt = Date().addingTimeInterval(ttl)
                entries[key] = existing
                return
            }

            let asset = AVURLAsset(url: url, options: options)
            entries[key] = Entry(
                asset: asset,
                expiresAt: Date().addingTimeInterval(ttl)
            )

            asset.loadValuesAsynchronously(forKeys: keysToLoad) { [weak self] in
                guard let self else { return }
                queue.async {
                    guard var entry = self.entries[key] else { return }
                    entry.expiresAt = Date().addingTimeInterval(self.ttl)
                    self.entries[key] = entry
                }
            }
        }
    }

    func preparedAsset(for url: URL) -> AVURLAsset? {
        let key = cacheKey(for: url)

        return queue.sync {
            cleanupExpiredLocked()

            guard var entry = entries[key], entry.expiresAt > Date() else {
                return nil
            }

            entry.expiresAt = Date().addingTimeInterval(ttl)
            entries[key] = entry
            return entry.asset
        }
    }

    public func cancel(url: URL) {
        let key = cacheKey(for: url)
        queue.async { [weak self] in
            self?.entries[key] = nil
        }
    }

    private func cleanupExpiredLocked() {
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private func cacheKey(for url: URL) -> String {
        url.absoluteString
    }
}
