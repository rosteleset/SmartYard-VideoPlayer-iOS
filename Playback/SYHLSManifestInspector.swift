//
//  SYHLSManifestInspector.swift
//  SmartYardVideoPlayer
//
//  Created by Александр Попов on 24.08.2026.
//

import Foundation
import RxCocoa
import RxSwift

struct SYHLSManifestResolution {
    let playbackURL: URL
    let mode: SYPlayerHLSLatencyMode
}

final class SYHLSManifestInspector {
    static let shared = SYHLSManifestInspector()

    private enum InspectionError: Error {
        case invalidData
    }

    private let cacheTTL: TimeInterval = 30
    private let requestTimeout: TimeInterval = 2
    private let lock = NSRecursiveLock()
    private let retryScheduler = SerialDispatchQueueScheduler(
        internalSerialQueueName: "sy.player.hls-manifest-inspector"
    )
    private var cache: [String: (resolution: SYHLSManifestResolution, expiresAt: Date)] = [:]
    private var inFlight: [String: Single<SYHLSManifestResolution>] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

    private init() {}

    func inspect(
        url: URL,
        options: [String: Any]?
    ) -> Single<SYHLSManifestResolution> {
        inspection(url: url, options: options, refreshesCache: false)
    }

    func refresh(
        url: URL,
        options: [String: Any]?
    ) -> Single<SYHLSManifestResolution> {
        inspection(url: url, options: options, refreshesCache: true)
    }

    func cachedResolution(
        url: URL,
        options: [String: Any]?
    ) -> SYHLSManifestResolution? {
        let key = cacheKey(url: url, headers: httpHeaders(from: options))
        return synchronized {
            cleanupExpiredCache()
            return cache[key]?.resolution
        }
    }

    func lowLatencyURL(for url: URL) -> URL {
        switch url.lastPathComponent.lowercased() {
        case "index.fmp4.m3u8", "index.m3u8":
            return url.deletingLastPathComponent().appendingPathComponent("index.ll.m3u8")
        default:
            return url
        }
    }
}

private extension SYHLSManifestInspector {
    func inspection(
        url: URL,
        options: [String: Any]?,
        refreshesCache: Bool
    ) -> Single<SYHLSManifestResolution> {
        let headers = httpHeaders(from: options)
        let key = cacheKey(url: url, headers: headers)

        return synchronized {
            cleanupExpiredCache()
            if refreshesCache {
                cache.removeValue(forKey: key)
            } else if let cached = cache[key] {
                return .just(cached.resolution)
            }
            if let active = inFlight[key] { return active.observe(on: MainScheduler.instance) }

            let lowLatencyURL = lowLatencyURL(for: url)
            let result = inspectLowLatencyPlaylist(
                lowLatencyURL: lowLatencyURL,
                headers: headers,
                attempt: 1
            )
            .map { mode in
                SYHLSManifestResolution(
                    playbackURL: mode == .lowLatency ? lowLatencyURL : url,
                    mode: mode
                )
            }
            .do(
                onSuccess: { [weak self] resolution in
                    self?.store(resolution: resolution, for: key)
                },
                onDispose: { [weak self] in
                    self?.synchronized { self?.inFlight.removeValue(forKey: key) }
                }
            )
            .asObservable()
            .share(replay: 1, scope: .whileConnected)
            .asSingle()

            inFlight[key] = result
            return result.observe(on: MainScheduler.instance)
        }
    }

    func inspectLowLatencyPlaylist(
        lowLatencyURL: URL,
        headers: [String: String],
        attempt: Int
    ) -> Single<SYPlayerHLSLatencyMode> {
        loadPlaylist(url: lowLatencyURL, headers: headers, depth: 0)
            .flatMap { [weak self] mode -> Single<SYPlayerHLSLatencyMode> in
                guard let self, mode != .lowLatency else { return .just(mode) }

                let maximumAttempts = max(
                    1,
                    SYPlayerConfig.shared.lowLatencyHLSManifestInspectionAttempts
                )
                guard attempt < maximumAttempts else { return .just(.standard) }

                let delay = max(
                    0,
                    SYPlayerConfig.shared.lowLatencyHLSManifestInspectionRetryDelay
                )
                SYPlayerConfig.shared.log(
                    "LL-HLS manifest is not ready; retrying inspection "
                        + "(attempt: \(attempt + 1)/\(maximumAttempts))",
                    level: .warning
                )
                return Single.just(())
                    .delay(.milliseconds(Int(delay * 1_000)), scheduler: retryScheduler)
                    .flatMap {
                        self.inspectLowLatencyPlaylist(
                            lowLatencyURL: lowLatencyURL,
                            headers: headers,
                            attempt: attempt + 1
                        )
                    }
            }
    }

    func loadPlaylist(
        url: URL,
        headers: [String: String],
        depth: Int
    ) -> Single<SYPlayerHLSLatencyMode> {
        loadPlaylistText(url: url, headers: headers)
            .flatMap { [weak self] playlist -> Single<SYPlayerHLSLatencyMode> in
                guard let self else { return .just(.standard) }
                if isLowLatencyPlaylist(playlist) { return .just(.lowLatency) }
                guard depth == 0,
                      let variantURL = firstVariantURL(in: playlist, relativeTo: url)
                else {
                    return .just(.standard)
                }
                return loadPlaylist(url: variantURL, headers: headers, depth: depth + 1)
            }
            .catch { error in
                SYPlayerConfig.shared.log(
                    "HLS manifest inspection failed for \(url.lastPathComponent): \(error)",
                    level: .warning
                )
                return .just(.standard)
            }
    }

    func loadPlaylistText(
        url: URL,
        headers: [String: String]
    ) -> Single<String> {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        return session.rx.response(request: request)
            .take(1)
            .map { response, data in
                guard (200..<300).contains(response.statusCode) else {
                    throw InspectionError.invalidData
                }
                guard let playlist = String(data: data, encoding: .utf8) else {
                    throw InspectionError.invalidData
                }
                return playlist
            }
            .asSingle()
    }

    func isLowLatencyPlaylist(_ playlist: String) -> Bool {
        let lines = playlist.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let hasPartialSegments = lines.contains { $0.hasPrefix("#EXT-X-PART:") }
        let hasServerControl = lines.contains { $0.hasPrefix("#EXT-X-SERVER-CONTROL:") }
        let hasPreloadHint = lines.contains {
            $0.hasPrefix("#EXT-X-PRELOAD-HINT:")
                && $0.contains("TYPE=PART")
                && $0.contains("URI=")
        }
        guard hasPartialSegments, hasServerControl else { return false }
        guard hasPreloadHint else {
            SYPlayerConfig.shared.log(
                "LL-HLS manifest is missing a valid EXT-X-PRELOAD-HINT",
                level: .warning
            )
            return false
        }

        guard let partInfo = lines.first(where: { $0.hasPrefix("#EXT-X-PART-INF:") }),
              let partTarget = decimalAttribute(named: "PART-TARGET", in: partInfo),
              partTarget > 0
        else {
            SYPlayerConfig.shared.log(
                "LL-HLS manifest is missing a valid PART-TARGET",
                level: .warning
            )
            return false
        }

        let minimumDuration = partTarget * 0.85
        var previousPartDuration: TimeInterval?

        for line in lines {
            if line.hasPrefix("#EXT-X-PART:"),
               let duration = decimalAttribute(named: "DURATION", in: line) {
                if let previousPartDuration,
                   previousPartDuration < minimumDuration {
                    logIncompatiblePartialSegment(
                        targetDuration: partTarget,
                        minimumDuration: minimumDuration
                    )
                    return false
                }
                previousPartDuration = duration
                continue
            }
            if line.hasPrefix("#EXTINF:") { previousPartDuration = nil }
        }
        return true
    }

    func decimalAttribute(named name: String, in line: String) -> Double? {
        guard let range = line.range(of: "\(name)=") else { return nil }
        let value = line[range.upperBound...].prefix { $0 != "," && $0 != "\"" }
        return Double(value)
    }

    func logIncompatiblePartialSegment(
        targetDuration: TimeInterval,
        minimumDuration: TimeInterval
    ) {
        SYPlayerConfig.shared.log(
            "LL-HLS manifest is incompatible with AVPlayer: "
                + "non-terminal parts must be at least 85% of PART-TARGET "
                + "(target: \(targetDuration)s, minimum: \(minimumDuration)s)",
            level: .warning
        )
    }

    func firstVariantURL(in playlist: String, relativeTo baseURL: URL) -> URL? {
        let lines = playlist.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let markerIndex = lines.firstIndex(where: {
            $0.hasPrefix("#EXT-X-STREAM-INF:")
        }),
            let candidate = lines.dropFirst(markerIndex + 1).first(where: { !$0.isEmpty }),
            !candidate.hasPrefix("#")
        else {
            return nil
        }
        return URL(string: candidate, relativeTo: baseURL)?.absoluteURL
    }

    func httpHeaders(from options: [String: Any]?) -> [String: String] {
        options?["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String] ?? [:]
    }

    func cacheKey(url: URL, headers: [String: String]) -> String {
        let headerSignature = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "|")
        return "\(url.absoluteString)|\(headerSignature)"
    }

    func store(resolution: SYHLSManifestResolution, for key: String) {
        synchronized {
            cache[key] = (
                resolution: resolution,
                expiresAt: Date().addingTimeInterval(cacheTTL)
            )
        }
    }

    func cleanupExpiredCache() {
        let now = Date()
        cache = cache.filter { $0.value.expiresAt > now }
    }

    func synchronized<T>(_ action: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }
}
