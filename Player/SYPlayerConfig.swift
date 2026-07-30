//
//  SYPlayerConfig.swift
//  SmartYard
//
//  Created by Александр Попов on 26.07.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import Foundation
import AVFoundation
import UIKit

public struct SYPlayerTransportAppearance {
    public var webRTCColor: UIColor
    public var hlsColor: UIColor
    public var playingColor: UIColor
    public var warningColor: UIColor
    public var errorColor: UIColor
    public var badgeBackgroundColor: UIColor
    public var messageBackgroundColor: UIColor
    public var textColor: UIColor
    public var badgeFont: UIFont
    public var messageFont: UIFont

    public init(
        webRTCColor: UIColor = UIColor(red: 0.18, green: 0.78, blue: 1.0, alpha: 1.0),
        hlsColor: UIColor = UIColor(red: 1.0, green: 0.64, blue: 0.20, alpha: 1.0),
        playingColor: UIColor = UIColor(red: 0.28, green: 0.84, blue: 0.48, alpha: 1.0),
        warningColor: UIColor = UIColor(red: 1.0, green: 0.76, blue: 0.24, alpha: 1.0),
        errorColor: UIColor = UIColor(red: 1.0, green: 0.31, blue: 0.31, alpha: 1.0),
        badgeBackgroundColor: UIColor = UIColor.black.withAlphaComponent(0.52),
        messageBackgroundColor: UIColor = UIColor.black.withAlphaComponent(0.76),
        textColor: UIColor = .white,
        badgeFont: UIFont = .systemFont(ofSize: 12, weight: .semibold),
        messageFont: UIFont = .systemFont(ofSize: 14, weight: .medium)
    ) {
        self.webRTCColor = webRTCColor
        self.hlsColor = hlsColor
        self.playingColor = playingColor
        self.warningColor = warningColor
        self.errorColor = errorColor
        self.badgeBackgroundColor = badgeBackgroundColor
        self.messageBackgroundColor = messageBackgroundColor
        self.textColor = textColor
        self.badgeFont = badgeFont
        self.messageFont = messageFont
    }
}

public struct SYPlayerTransportStrings {
    public var connectingWebRTC: String
    public var connectingHLS: String
    public var switchingToHLS: String
    public var connectedHLS: String
    public var videoUnavailable: String
    public var webRTCInfo: String
    public var hlsInfo: String

    public init(
        connectingWebRTC: String = "Connecting via WebRTC…",
        connectingHLS: String = "Connecting via HLS…",
        switchingToHLS: String = "WebRTC is unavailable. Connecting via HLS…",
        connectedHLS: String = "Connected via HLS",
        videoUnavailable: String = "Unable to load video",
        webRTCInfo: String = "Video is delivered via WebRTC. This method usually provides lower latency.",
        hlsInfo: String = "HLS uses buffering, which can smooth brief network interruptions. A delay from real time is possible."
    ) {
        self.connectingWebRTC = connectingWebRTC
        self.connectingHLS = connectingHLS
        self.switchingToHLS = switchingToHLS
        self.connectedHLS = connectedHLS
        self.videoUnavailable = videoUnavailable
        self.webRTCInfo = webRTCInfo
        self.hlsInfo = hlsInfo
    }
}

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
    public var animateTimeInterval: TimeInterval = 2

    /// online / archive
    public var videoType: SYPlayedVideoType = .online

    /// Должен ли плеер стартовать сразу после setVideo
    public var shouldAutoPlay: Bool = false

    /// Default buffer settings
    public var preferredForwardBufferDuration: TimeInterval = 6

    /// Do we allow streaming resources when paused?
    public var allowNetworkResourcesWhilePaused: Bool = true

    // MARK: - Assets

    public var icons: SYPlayerIcons = SYPlayerIcons()
    public var colors: SYPlayerColors = SYPlayerColors()
    public var fonts: SYPlayerFonts = SYPlayerFonts()
    public var transportAppearance = SYPlayerTransportAppearance()
    public var transportStrings = SYPlayerTransportStrings()

    // MARK: - Calendar

    /// Calendar used for time formatting in sliders.
    public var referenceCalendar: Calendar = .current

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
