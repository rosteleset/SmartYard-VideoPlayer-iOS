//
//  SYPlayerConfig.swift
//  SmartYard
//
//  Created by Александр Попов on 26.07.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import Foundation
import AVFoundation

public enum SYPlayerLogLevel: Int {
    case critical = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4

    var label: String {
        switch self {
        case .critical: return "CRITICAL"
        case .error: return "ERROR"
        case .warning: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }

    var isAlwaysEnabled: Bool {
        self == .critical || self == .error
    }
}

public final class SYPlayerConfig {
    public static let shared = SYPlayerConfig()

    // MARK: - Playback

    /// Auto-hide controls
    var animateTimeInterval: TimeInterval = 2

    /// online / archive
    var videoType: SYPlayedVideoType = .online

    /// Должен ли плеер стартовать сразу после setVideo
    var shouldAutoPlay: Bool = false

    /// Default buffer settings
    var preferredForwardBufferDuration: TimeInterval = 6

    /// Do we allow streaming resources when paused?
    var allowNetworkResourcesWhilePaused: Bool = true

    // MARK: - Assets

    public var icons: SYPlayerIcons = SYPlayerIcons()
    public var colors: SYPlayerColors = SYPlayerColors()

    // MARK: - Logs

    public var allowLogs: Bool = false

    public var logger: ((String) -> Void)?

    // MARK: - Init

    /// Creates a shared configuration instance.
    private init() {}

    // MARK: - Public

    /// Emits a log message; critical and error levels are always emitted.
    func log(
        _ message: String,
        level: SYPlayerLogLevel = .info,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        guard allowLogs || level.isAlwaysEnabled else { return }
        let timestamp = Self.logTimestamp()
        let caller = Self.logCaller(file: file, function: function, line: line)
        let formatted = "\(timestamp) \(caller) \(level.label): \(message)"
        if let logger {
            logger(formatted)
        } else {
            print(formatted)
        }
    }

    /// Builds an AVURLAsset for the given resource.
    func makeAsset(for resource: SYPlayerResourceVideo) -> AVURLAsset {
        makeAsset(url: resource.url, options: resource.options)
    }

    /// Builds an AVURLAsset for a URL, using proxy URL for HLS when needed.
    func makeAsset(url: URL, options: [String: Any]? = nil) -> AVURLAsset {
        if url.isFileURL {
            log("Build asset for file URL: \(url.path)", level: .debug)
            return AVURLAsset(url: url, options: options)
        }

        if url.pathExtension.lowercased() == "m3u8" {
            log("Build asset for HLS URL via proxy: \(url.absoluteString)", level: .debug)
            let proxyURL = SYKTVHTTPCacheCoordinator.proxyURL(for: url)
            return AVURLAsset(url: proxyURL, options: options)
        }

        log("Build asset for URL: \(url.absoluteString)", level: .debug)
        return AVURLAsset(url: url, options: options)
    }

    /// Builds an AVPlayerItem with the current configuration defaults.
    func makePlayerItem(from asset: AVURLAsset) -> AVPlayerItem {
        log("Build player item for asset", level: .debug)
        let item = AVPlayerItem(asset: asset)

        item.preferredForwardBufferDuration = preferredForwardBufferDuration

        // Live streaming while paused
        if allowNetworkResourcesWhilePaused {
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }

        return item
    }

    // MARK: - Log Helpers

    private static let logDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let logDateFormatterLock = NSLock()

    private static func logTimestamp() -> String {
        logDateFormatterLock.lock()
        defer { logDateFormatterLock.unlock() }
        return logDateFormatter.string(from: Date())
    }

    private static func logCaller(file: String, function: String, line: Int) -> String {
        let fileName = (file as NSString).lastPathComponent
        return "\(fileName):\(line) \(function)"
    }
}
