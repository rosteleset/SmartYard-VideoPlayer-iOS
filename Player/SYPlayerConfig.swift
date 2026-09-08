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
    public var connecting: String
    public var connectingWebRTC: String
    public var connectingHLS: String
    public var switchingToHLS: String
    public var connectedHLS: String
    public var videoUnavailable: String
    public var webRTCInfo: String
    public var hlsInfo: String
    public var lowLatencyHLSInfo: String

    public init(
        connecting: String = "Connecting…",
        connectingWebRTC: String = "Connecting via WebRTC…",
        connectingHLS: String = "Connecting via HLS…",
        switchingToHLS: String = "WebRTC is unavailable. Connecting via HLS…",
        connectedHLS: String = "Connected via HLS",
        videoUnavailable: String = "Unable to load video",
        webRTCInfo: String = "Video is delivered via WebRTC. This method usually provides lower latency.",
        hlsInfo: String = "HLS uses buffering, which can smooth brief network interruptions. A delay from real time is possible.",
        lowLatencyHLSInfo: String = "Low-latency video delivery."
    ) {
        self.connecting = connecting
        self.connectingWebRTC = connectingWebRTC
        self.connectingHLS = connectingHLS
        self.switchingToHLS = switchingToHLS
        self.connectedHLS = connectedHLS
        self.videoUnavailable = videoUnavailable
        self.webRTCInfo = webRTCInfo
        self.hlsInfo = hlsInfo
        self.lowLatencyHLSInfo = lowLatencyHLSInfo
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

    /// Whether regular HLS playback waits for enough buffered media to minimize stalls.
    public var automaticallyWaitsToMinimizeStalling: Bool = true

    /// Forward buffer used for live LL-HLS playback.
    public var lowLatencyHLSPreferredForwardBufferDuration: TimeInterval = 1

    /// LL-HLS always waits for enough buffered media to avoid a startup race.
    @available(*, deprecated, message: "LL-HLS always waits for its startup buffer.")
    public var lowLatencyHLSAutomaticallyWaitsToMinimizeStalling: Bool {
        get { true }
        set { _ = newValue }
    }

    /// Optional fixed distance from the live edge. Nil follows AVFoundation's recommendation.
    public var lowLatencyHLSTargetLiveOffset: TimeInterval?

    /// Keeps the LL-HLS playhead at the same distance from the live edge after buffering.
    public var lowLatencyHLSAutomaticallyPreservesLiveOffset: Bool = true

    /// Time allowed for LL-HLS to display its first frame before falling back to regular HLS.
    public var lowLatencyHLSFirstFrameTimeout: TimeInterval = 3

    /// Number of manifest checks before LL-HLS is considered temporarily unavailable.
    public var lowLatencyHLSManifestInspectionAttempts: Int = 3

    /// Delay between repeated LL-HLS manifest checks.
    public var lowLatencyHLSManifestInspectionRetryDelay: TimeInterval = 0.25

    /// Time to keep the last successful HLS transport choice between player resources.
    public var streamTransportPreferenceDuration: TimeInterval = 300

    /// Time to avoid LL-HLS after a playback error or first-frame timeout.
    public var lowLatencyHLSFailureCooldown: TimeInterval = 60

    /// Fallback live-edge distance used when AVFoundation has no LL-HLS recommendation yet.
    public var lowLatencyHLSRecoveryLiveEdgeOffset: TimeInterval = 2

    /// Do we allow streaming resources when paused?
    public var allowNetworkResourcesWhilePaused: Bool = true

    /// Time to skip WHEP after a failed attempt.
    public var whepCooldownDuration: TimeInterval = 60

    /// Maximum time for the WHEP HTTP, SDP, and ICE handshake.
    public var whepHandshakeTimeout: TimeInterval = 2

    /// Maximum time to receive the first video frame after the WHEP handshake.
    public var whepFirstFrameTimeout: TimeInterval = 1.25

    /// Time without live HLS progress before attempting recovery.
    public var liveHLSStallRecoveryTimeout: TimeInterval = 2.5

    /// Distance from the live edge used when recovering stalled HLS playback.
    public var liveHLSRecoveryLiveEdgeOffset: TimeInterval = 6

    /// Time allowed for a recovery seek before recreating the live HLS item.
    public var liveHLSPostSeekRecoveryTimeout: TimeInterval = 0.75

    /// Maximum recovery actions for one continuous live HLS stall.
    public var liveHLSMaxStallRecoveryAttempts: Int = 2

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

    /// Builds an AVURLAsset for a URL.
    func makeAsset(url: URL, options: [String: Any]? = nil) -> AVURLAsset {
        if url.isFileURL {
            log("Build asset for file URL: \(url.path)", level: .debug)
            return AVURLAsset(url: url, options: options)
        }

        if url.pathExtension.lowercased() == "m3u8" {
            log("Build asset for HLS URL: \(url.absoluteString)", level: .debug)
            return AVURLAsset(url: url, options: options)
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
