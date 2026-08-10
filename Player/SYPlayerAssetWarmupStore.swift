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
    public var ttl: TimeInterval = 5

    private struct Entry {
        let asset: AVURLAsset
        let createdAt: Date
        let expiresAt: Date
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

            if let existing = entries[key], existing.expiresAt > Date() {
                let snapshot = statusSnapshot(for: existing.asset)
                let age = Date().timeIntervalSince(existing.createdAt)
                SYPlayerConfig.shared.log(
                    "Warmup reuse asset: \(url.absoluteString), age: \(age)s, "
                        + "statuses: \(snapshot.summary)",
                    level: snapshot.hasFailure ? .warning : .debug
                )
                return
            }

            let now = Date()
            let asset = SYPlayerConfig.shared.makeAsset(url: url, options: options)
            entries[key] = Entry(
                asset: asset,
                createdAt: now,
                expiresAt: now.addingTimeInterval(ttl)
            )

            asset.loadValuesAsynchronously(forKeys: keysToLoad) { [weak self] in
                guard let self else { return }
                queue.async {
                    guard let entry = self.entries[key], entry.asset === asset else { return }
                    let snapshot = self.statusSnapshot(for: asset)
                    let age = Date().timeIntervalSince(entry.createdAt)
                    SYPlayerConfig.shared.log(
                        "Warmup finished: \(url.absoluteString), age: \(age)s, "
                            + "statuses: \(snapshot.summary)",
                        level: snapshot.hasFailure ? .warning : .debug
                    )
                }
            }
        }
    }

    func preparedAsset(for url: URL) -> AVURLAsset? {
        let key = cacheKey(for: url)

        return queue.sync {
            cleanupExpiredLocked()

            guard let entry = entries[key], entry.expiresAt > Date() else {
                return nil
            }

            let snapshot = statusSnapshot(for: entry.asset)
            let age = Date().timeIntervalSince(entry.createdAt)
            SYPlayerConfig.shared.log(
                "Warmup provide asset: \(url.absoluteString), age: \(age)s, "
                    + "statuses: \(snapshot.summary)",
                level: snapshot.hasFailure ? .warning : .debug
            )
            return entry.asset
        }
    }

    func invalidate(url: URL) {
        let key = cacheKey(for: url)
        queue.sync {
            entries.removeValue(forKey: key)
        }
        SYPlayerConfig.shared.log(
            "Warmup invalidate asset: \(url.absoluteString)",
            level: .warning
        )
    }

    public func cancel(url: URL) {
        let key = cacheKey(for: url)
        queue.async { [weak self] in
            guard let self else { return }
            entries.removeValue(forKey: key)?.asset.cancelLoading()
        }
    }

    public func cancelAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let assets = entries.values.map(\.asset)
            entries.removeAll()
            assets.forEach { $0.cancelLoading() }
        }
    }

    private func cleanupExpiredLocked() {
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private func cacheKey(for url: URL) -> String {
        url.absoluteString
    }

    private func statusSnapshot(
        for asset: AVURLAsset
    ) -> (summary: String, hasFailure: Bool) {
        var hasFailure = false
        let summary = keysToLoad.map { key in
            var error: NSError?
            let status = asset.statusOfValue(forKey: key, error: &error)
            let statusName: String

            switch status {
            case .unknown: statusName = "unknown"
            case .loading: statusName = "loading"
            case .loaded: statusName = "loaded"
            case .failed:
                statusName = "failed"
                hasFailure = true
            case .cancelled:
                statusName = "cancelled"
                hasFailure = true
            @unknown default:
                statusName = "unknown(\(status.rawValue))"
            }

            guard let error else { return "\(key)=\(statusName)" }
            return "\(key)=\(statusName)[\(error.domain):\(error.code) \(error.localizedDescription)]"
        }

        return (summary.joined(separator: ", "), hasFailure)
    }
}
