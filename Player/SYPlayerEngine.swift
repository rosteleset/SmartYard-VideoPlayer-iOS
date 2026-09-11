//
//  SYPlayer.swift
//  SmartYard
//
//  Created by Александр Попов on 08.08.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import Foundation
import AVFoundation

protocol SYPlayerEngineDelegate: AnyObject {
    /// Called when the playback state changes.
    func playerEngine(
        _ engine: SYPlayerEngine,
        stateDidChange state: SYPlayerState
    )

    /// Called when buffered time changes.
    func playerEngine(
        _ engine: SYPlayerEngine,
        loadedTimeDidChange loaded: TimeInterval,
        total: TimeInterval
    )

    /// Called when current play time changes.
    func playerEngine(
        _ engine: SYPlayerEngine,
        playTimeDidChange current: TimeInterval,
        total: TimeInterval
    )

    /// Called when the playing flag changes.
    func playerEngine(
        _ engine: SYPlayerEngine,
        isPlayingDidChange isPlaying: Bool
    )

    /// Called when AVPlayer records a media error-log entry.
    func playerEngine(
        _ engine: SYPlayerEngine,
        didReceiveErrorStatusCode statusCode: Int,
        comment: String?
    )
}

final class SYPlayerEngine {
    weak var delegate: SYPlayerEngineDelegate?

    private(set) var player: AVPlayer = AVPlayer()

    private var item: AVPlayerItem?
    private var urlAsset: AVURLAsset?
    private var isUsingWarmedAsset = false
    private var currentURL: URL?
    private var currentAutoPlay = true
    private var isLiveHLS = false
    private var hlsLatencyMode: SYPlayerHLSLatencyMode = .standard
    private var shouldPlay = false
    private var hasDisplayedFirstFrame = false
    private var didRetryWithFreshAsset = false
    private var stallRecoveryAttempts = 0
    private var stallRecoveryWorkItem: DispatchWorkItem?

    private(set) var lastErrorStatusCode: Int?
    private(set) var lastErrorComment: String?

    // Time observer token
    private var timeObserverToken: Any?

    // KVO
    private var itemStatusObs: NSKeyValueObservation?
    private var loadedRangesObs: NSKeyValueObservation?
    private var bufferEmptyObs: NSKeyValueObservation?
    private var keepUpObs: NSKeyValueObservation?

    private var playerTimeControlStatusObs: NSKeyValueObservation?

    private var pendingSeek: TimeInterval?

    private(set) var state: SYPlayerState = .idle {
        didSet {
            guard oldValue != state else { return }
            let newState = state
            let level: SYPlayerLogLevel = {
                if case .error = newState { return .error }
                return .debug
            }()
            SYPlayerConfig.shared.log(
                "Engine state changed from \(oldValue) to \(newState)",
                level: level
            )
            notifyDelegate { engine, delegate in
                delegate.playerEngine(engine, stateDidChange: newState)
            }
        }
    }

    private(set) var isPlaying: Bool = false {
        didSet {
            guard oldValue != isPlaying else { return }
            let playingNow = isPlaying
            SYPlayerConfig.shared.log(
                "Engine isPlaying changed from \(oldValue) to \(playingNow)",
                level: .debug
            )
            notifyDelegate { engine, delegate in
                delegate.playerEngine(engine, isPlayingDidChange: playingNow)
            }
        }
    }

    deinit { cleanup() }

    // MARK: - Public API

    /// Loads a URL into the player and optionally starts playback.
    func set(
        url: URL,
        autoPlay: Bool = true,
        isLiveHLS: Bool = false,
        hlsLatencyMode: SYPlayerHLSLatencyMode = .standard
    ) {
        SYPlayerConfig.shared.log(
            "Engine set URL: \(url.absoluteString), autoPlay: \(autoPlay)",
            level: .info
        )
        currentURL = url
        currentAutoPlay = autoPlay
        self.isLiveHLS = isLiveHLS
        self.hlsLatencyMode = isLiveHLS ? hlsLatencyMode : .standard
        shouldPlay = autoPlay
        hasDisplayedFirstFrame = false
        didRetryWithFreshAsset = false
        stallRecoveryAttempts = 0
        lastErrorStatusCode = nil
        lastErrorComment = nil

        load(url: url, autoPlay: autoPlay, allowWarmedAsset: true)
    }

    private func load(
        url: URL,
        autoPlay: Bool,
        allowWarmedAsset: Bool
    ) {
        shouldPlay = autoPlay
        state = .preparing

        cleanupItemOnly()

        let asset: AVURLAsset
        if allowWarmedAsset,
           let warmedAsset = SYPlayerAssetWarmupStore.shared.preparedAsset(for: url) {
            asset = warmedAsset
            isUsingWarmedAsset = true
            SYPlayerConfig.shared.log(
                "Engine use warmed asset: \(warmedAsset.url.absoluteString)",
                level: .debug
            )
        } else {
            asset = SYPlayerConfig.shared.makeAsset(url: url)
            isUsingWarmedAsset = false
            SYPlayerConfig.shared.log(
                "Engine use fresh asset: \(asset.url.absoluteString)",
                level: .debug
            )
        }
        self.urlAsset = asset

        let newItem = AVPlayerItem(asset: asset)
        configurePlayback(item: newItem)
        SYPlayerConfig.shared.log(
            "Engine configure buffering: preferredForward="
                + "\(newItem.preferredForwardBufferDuration)s, "
                + "automaticallyWaitsToMinimizeStalling="
                + "\(player.automaticallyWaitsToMinimizeStalling), "
                + "hlsLatencyMode=\(hlsLatencyMode)",
            level: .info
        )

        self.item = newItem

        player.replaceCurrentItem(with: newItem)

        observe(player)
        observe(newItem)

        installPeriodicTimeObserver()

        autoPlay ? play() : pause()
    }

    /// Starts playback if an item is loaded.
    func play() {
        guard player.currentItem != nil else { return }

        SYPlayerConfig.shared.log("Engine play", level: .debug)
        shouldPlay = true
        currentAutoPlay = true
        player.play()
        if player.timeControlStatus != .playing {
            state = .buffering
        }
    }

    /// Pauses playback if an item is loaded.
    func pause() {
        guard player.currentItem != nil else { return }

        SYPlayerConfig.shared.log("Engine pause", level: .debug)
        shouldPlay = false
        currentAutoPlay = false
        cancelLiveHLSStallRecovery()
        player.pause()
        isPlaying = false

        // если не было ошибки/ended — ставим paused
        switch state {
        case .error, .ended, .idle: break
        default: state = .paused
        }
    }

    /// Seeks to a specific time in seconds.
    func seek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        guard seconds.isFinite, seconds >= 0 else { return }

        // Если item ещё не готов — запомним
        guard let currentItem = player.currentItem else {
            SYPlayerConfig.shared.log(
                "Engine seek queued (no current item) to \(seconds)s",
                level: .debug
            )
            pendingSeek = seconds
            completion?()
            return
        }

        if currentItem.status == .readyToPlay {
            let target = CMTime(seconds: seconds, preferredTimescale: 600)
            SYPlayerConfig.shared.log("Engine seek to \(seconds)s", level: .debug)
            player.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                completion?()
            }
        } else {
            SYPlayerConfig.shared.log(
                "Engine seek queued (item not ready) to \(seconds)s",
                level: .debug
            )
            pendingSeek = seconds
            completion?()
        }
    }

    /// Stops playback and resets the current item.
    func stop() {
        SYPlayerConfig.shared.log("Engine stop", level: .info)
        pause()
        shouldPlay = false
        currentAutoPlay = false
        state = .idle
        cleanupItemOnly()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        isLiveHLS = false
        hlsLatencyMode = .standard
        hasDisplayedFirstFrame = false
        stallRecoveryAttempts = 0
        didRetryWithFreshAsset = false
    }

    /// Stops playback and removes observers.
    func cleanup() {
        SYPlayerConfig.shared.log("Engine cleanup", level: .debug)
        stop()
        removePeriodicTimeObserver()
        removePlayerObservers()
    }

    /// Confirms that the current item produced a frame visible to the user.
    func firstFrameDidDisplay() {
        guard !hasDisplayedFirstFrame else { return }
        hasDisplayedFirstFrame = true
        stallRecoveryAttempts = 0
        cancelLiveHLSStallRecovery()
        SYPlayerConfig.shared.log(
            "Engine first frame displayed",
            level: .debug
        )
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            scheduleLiveHLSStallRecoveryIfNeeded()
        }
    }

    private func notifyDelegate(
        _ action: @escaping (SYPlayerEngine, SYPlayerEngineDelegate) -> Void
    ) {
        if Thread.isMainThread {
            guard let delegate else { return }
            action(self, delegate)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            action(self, delegate)
        }
    }
}

private extension SYPlayerEngine {

    var isLowLatencyHLS: Bool {
        guard isLiveHLS else { return false }
        if case .lowLatency = hlsLatencyMode { return true }
        return false
    }

    func configurePlayback(item: AVPlayerItem) {
        let config = SYPlayerConfig.shared
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = config.allowNetworkResourcesWhilePaused

        guard isLiveHLS else {
            player.automaticallyWaitsToMinimizeStalling = config.automaticallyWaitsToMinimizeStalling
            item.preferredForwardBufferDuration = max(0, config.preferredForwardBufferDuration)
            return
        }

        guard isLowLatencyHLS else {
            player.automaticallyWaitsToMinimizeStalling =
                config.liveHLSWaitsToMinimizeStalling
            item.preferredForwardBufferDuration = max(
                0,
                config.liveHLSPreferredForwardBufferDuration
            )
            return
        }

        player.automaticallyWaitsToMinimizeStalling =
            config.lowLatencyHLSAutomaticallyWaitsToMinimizeStalling
        item.preferredForwardBufferDuration = max(
            0,
            config.lowLatencyHLSPreferredForwardBufferDuration
        )
        item.automaticallyPreservesTimeOffsetFromLive =
            config.lowLatencyHLSAutomaticallyPreservesLiveOffset

        guard let targetOffset = config.lowLatencyHLSTargetLiveOffset else { return }
        guard targetOffset.isFinite, targetOffset >= 0 else {
            config.log(
                "Engine ignore invalid LL-HLS target live offset: \(targetOffset)s",
                level: .warning
            )
            return
        }

        item.configuredTimeOffsetFromLive = CMTime(
            seconds: targetOffset,
            preferredTimescale: 600
        )
    }

    func applyRecommendedLiveOffsetIfNeeded(to item: AVPlayerItem) {
        let config = SYPlayerConfig.shared
        guard isLowLatencyHLS,
              config.lowLatencyHLSTargetLiveOffset == nil,
              let recommendedOffset = liveOffsetSeconds(
                from: item.recommendedTimeOffsetFromLive
              ) else { return }

        if let currentOffset = liveOffsetSeconds(from: item.configuredTimeOffsetFromLive),
           abs(currentOffset - recommendedOffset) < 0.05 {
            return
        }

        item.configuredTimeOffsetFromLive = CMTime(
            seconds: recommendedOffset,
            preferredTimescale: 600
        )
        let formattedOffset = String(format: "%.3f", recommendedOffset)
        config.log(
            "Engine apply recommended LL-HLS live offset: \(formattedOffset)s",
            level: .info
        )
    }

    func liveOffsetSeconds(from time: CMTime) -> TimeInterval? {
        let seconds = time.seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    // MARK: - Observing

    /// Observes actual AVPlayer playback instead of the requested playback rate.
    func observe(_ player: AVPlayer) {
        let installObserver = { [weak self] in
            guard let self else { return }
            playerTimeControlStatusObs = player.observe(
                \.timeControlStatus,
                options: [.initial, .new]
            ) { [weak self] player, _ in
                guard let self else { return }

                if let item {
                    logBufferSnapshot(
                        for: item,
                        context: "time control changed"
                    )
                }

                switch player.timeControlStatus {
                case .playing:
                    guard shouldPlay else {
                        player.pause()
                        return
                    }
                    isPlaying = true
                    if hasDisplayedFirstFrame {
                        stallRecoveryAttempts = 0
                        cancelLiveHLSStallRecovery()
                    } else {
                        scheduleLiveHLSStallRecoveryIfNeeded()
                    }
                    state = .playing

                case .waitingToPlayAtSpecifiedRate:
                    isPlaying = false
                    guard shouldPlay else { return }
                    switch state {
                    case .error, .ended, .idle:
                        break
                    default:
                        state = .buffering
                        scheduleLiveHLSStallRecoveryIfNeeded()
                    }

                case .paused:
                    isPlaying = false
                    if !shouldPlay {
                        cancelLiveHLSStallRecovery()
                    }

                @unknown default:
                    break
                }
            }
        }

        if Thread.isMainThread {
            installObserver()
        } else {
            DispatchQueue.main.async(execute: installObserver)
        }
    }

    /// Observes item status, buffering, and loaded ranges.
    func observe(_ item: AVPlayerItem) {
        // status -> ready/error
        itemStatusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self, self.item === item else { return }

            switch item.status {
            case .unknown:
                state = .buffering

            case .readyToPlay:
                let total = item.duration.seconds
                let duration = total.isFinite ? total : 0
                applyRecommendedLiveOffsetIfNeeded(to: item)
                logBufferSnapshot(for: item, context: "item ready")
                if shouldPlay,
                   isLiveHLS,
                   !player.automaticallyWaitsToMinimizeStalling {
                    SYPlayerConfig.shared.log(
                        "Engine start live HLS immediately after item became ready",
                        level: .debug
                    )
                    player.playImmediately(atRate: 1)
                }
                setReadyState(duration: duration)

                // если был отложенный seek — применяем
                if let pending = pendingSeek {
                    pendingSeek = nil
                    SYPlayerConfig.shared.log(
                        "Engine applying pending seek to \(pending)s",
                        level: .debug
                    )
                    seek(to: pending) { [weak self] in
                        guard let self else { return }
                        // если уже playing — оставим; иначе будем ready/paused
                    }
                }

            case .failed:
                logFailureDiagnostics(for: item)
                if retryWithFreshAssetIfNeeded(for: item, reason: "item failed") {
                    return
                }
                cancelLiveHLSStallRecovery()
                state = .error(item.error?.localizedDescription ?? "AVPlayerItem failed")
                isPlaying = false

            @unknown default:
                cancelLiveHLSStallRecovery()
                state = .error("Unknown AVPlayerItem status")
                isPlaying = false
            }
        }

        // loadedTimeRanges -> прогресс буфера
        loadedRangesObs = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            guard let self,
                  self.item === item,
                  let loaded = availableDuration(for: item) else { return }

            let total = item.duration.seconds
            let totalSafe = total.isFinite ? total : 0

            notifyDelegate { engine, delegate in
                delegate.playerEngine(engine, loadedTimeDidChange: loaded, total: totalSafe)
            }
        }

        // playbackBufferEmpty -> buffering
        bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self, self.item === item else { return }

            if item.isPlaybackBufferEmpty {
                logBufferSnapshot(for: item, context: "buffer empty")
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    state = .buffering
                    scheduleLiveHLSStallRecoveryIfNeeded()
                }
            }
        }

        // playbackLikelyToKeepUp -> buffer finished
        keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self, self.item === item else { return }

            if item.isPlaybackLikelyToKeepUp {
                // если мы уже готовы/играем — не трогаем лишний раз
                if case .buffering = state {
                    logBufferSnapshot(for: item, context: "buffer recovered")
                    // если длительность известна — можем перевести в ready
                    let total = item.duration.seconds
                    let duration = total.isFinite ? total : 0
                    setReadyState(duration: duration)
                }
            }
        }

        // ended notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemNewErrorLogEntry(_:)),
            name: .AVPlayerItemNewErrorLogEntry,
            object: item
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemNewAccessLogEntry(_:)),
            name: .AVPlayerItemNewAccessLogEntry,
            object: item
        )
    }

    /// Handles playback completion.
    @objc func itemDidPlayToEnd(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              self.item === item else { return }
        SYPlayerConfig.shared.log("Engine item did play to end", level: .info)
        cancelLiveHLSStallRecovery()
        state = .ended
        isPlaying = false

        // Финальный прогресс
        let total = item.duration.seconds
        let totalSafe = total.isFinite ? total : 0
        notifyDelegate { engine, delegate in
            delegate.playerEngine(engine, playTimeDidChange: totalSafe, total: totalSafe)
        }
    }

    @objc func itemNewErrorLogEntry(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              self.item === item else { return }
        guard let event = logErrorLog(for: item, context: "new entry") else { return }
        if retryWithFreshAssetIfNeeded(for: item, reason: "error log entry") {
            return
        }

        let statusCode = event.errorStatusCode
        let comment = event.errorComment
        notifyDelegate { engine, delegate in
            delegate.playerEngine(
                engine,
                didReceiveErrorStatusCode: statusCode,
                comment: comment
            )
        }
    }

    @objc func itemNewAccessLogEntry(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              self.item === item else { return }
        logAccessLog(for: item, context: "new entry")
    }

    // MARK: - Periodic time observer

    /// Installs a periodic observer to report play time and buffer state.
    func installPeriodicTimeObserver() {
        removePeriodicTimeObserver()

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        SYPlayerConfig.shared.log("Engine install periodic time observer", level: .debug)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            guard let item = self.player.currentItem else { return }

            applyRecommendedLiveOffsetIfNeeded(to: item)

            let current = time.seconds
            let total = item.duration.seconds

            let currentSafe = current.isFinite ? current : 0
            let totalSafe = total.isFinite ? total : 0

            notifyDelegate { engine, delegate in
                delegate.playerEngine(engine, playTimeDidChange: currentSafe, total: totalSafe)
            }

            if item.status == .failed {
                if retryWithFreshAssetIfNeeded(for: item, reason: "periodic item failure") {
                    return
                }
                cancelLiveHLSStallRecovery()
                state = .error(item.error?.localizedDescription ?? "Playback failed")
            }
        }
    }

    /// Removes the periodic time observer if installed.
    func removePeriodicTimeObserver() {
        if let token = timeObserverToken {
            SYPlayerConfig.shared.log("Engine remove periodic time observer", level: .debug)
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    // MARK: - Helpers / Cleanup

    /// Returns the buffered duration for the item if available.
    func availableDuration(for item: AVPlayerItem) -> TimeInterval? {
        guard let first = item.loadedTimeRanges.first?.timeRangeValue else { return nil }
        let start = first.start.seconds
        let dur = first.duration.seconds
        let result = start + dur
        return result.isFinite ? result : nil
    }

    func logBufferSnapshot(for item: AVPlayerItem, context: String) {
        let current = player.currentTime().seconds
        let currentSafe = current.isFinite ? current : 0
        let bufferedAhead = bufferedAhead(for: item, at: currentSafe)
        let timeControlStatus: String
        switch player.timeControlStatus {
        case .paused:
            timeControlStatus = "paused"
        case .waitingToPlayAtSpecifiedRate:
            timeControlStatus = "waiting"
        case .playing:
            timeControlStatus = "playing"
        @unknown default:
            timeControlStatus = "unknown"
        }
        let waitingReason = player.reasonForWaitingToPlay
            .map { String(describing: $0) } ?? "none"

        SYPlayerConfig.shared.log(
            "Engine buffer snapshot (\(context)): current="
                + "\(String(format: "%.3f", currentSafe))s, bufferedAhead="
                + "\(String(format: "%.3f", bufferedAhead))s, ranges="
                + "\(item.loadedTimeRanges.count), empty=\(item.isPlaybackBufferEmpty), "
                + "likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp), "
                + "full=\(item.isPlaybackBufferFull), rate=\(player.rate), "
                + "timeControlStatus=\(timeControlStatus), waitingReason=\(waitingReason)",
            level: .info
        )
    }

    func bufferedAhead(
        for item: AVPlayerItem,
        at currentTime: TimeInterval? = nil
    ) -> TimeInterval {
        let current = currentTime ?? player.currentTime().seconds
        let currentSafe = current.isFinite ? current : 0
        return item.loadedTimeRanges
            .map(\.timeRangeValue)
            .compactMap { range -> TimeInterval? in
                let start = range.start.seconds
                let end = CMTimeRangeGetEnd(range).seconds
                guard start.isFinite,
                      end.isFinite,
                      currentSafe >= start - 0.05,
                      currentSafe <= end + 0.05 else { return nil }
                return max(0, end - currentSafe)
            }
            .max() ?? 0
    }

    func scheduleLiveHLSStallRecoveryIfNeeded() {
        let isWaitingForFirstFrame = !hasDisplayedFirstFrame
        if isWaitingForFirstFrame, stallRecoveryWorkItem != nil { return }
        cancelLiveHLSStallRecovery()

        let config = SYPlayerConfig.shared
        let timeout = isWaitingForFirstFrame || stallRecoveryAttempts == 0
            ? config.liveHLSStallRecoveryTimeout
            : config.liveHLSPostSeekRecoveryTimeout
        let maxAttempts = max(0, config.liveHLSMaxStallRecoveryAttempts)
        let isFinalStartupCheck = isWaitingForFirstFrame
            && stallRecoveryAttempts >= maxAttempts
        guard isLiveHLS,
              shouldPlay,
              isWaitingForFirstFrame
                || player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              timeout > 0,
              isWaitingForFirstFrame || stallRecoveryAttempts < maxAttempts,
              let item else { return }

        let startPosition = player.currentTime().seconds
        guard startPosition.isFinite else { return }

        let attemptDescription = isFinalStartupCheck
            ? "final first-frame check"
            : "attempt: \(stallRecoveryAttempts + 1)/\(maxAttempts)"
        SYPlayerConfig.shared.log(
            "Engine live HLS "
                + "\(isWaitingForFirstFrame ? "startup" : "stall") "
                + "watchdog scheduled: \(timeout)s (\(attemptDescription))",
            level: .warning
        )

        let workItem = DispatchWorkItem { [weak self, weak item] in
            guard let self,
                  let item,
                  self.item === item,
                  self.shouldPlay else { return }

            self.stallRecoveryWorkItem = nil
            let isStillWaitingForFirstFrame = !self.hasDisplayedFirstFrame
            guard isStillWaitingForFirstFrame
                    || self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            else {
                return
            }

            let currentPosition = self.player.currentTime().seconds
            guard currentPosition.isFinite else { return }
            if !isStillWaitingForFirstFrame,
               currentPosition - startPosition >= 0.25 {
                self.scheduleLiveHLSStallRecoveryIfNeeded()
                return
            }

            if isStillWaitingForFirstFrame,
               self.stallRecoveryAttempts >= maxAttempts {
                self.failLiveHLSStartup()
                return
            }

            self.stallRecoveryAttempts += 1
            self.logBufferSnapshot(for: item, context: "stall watchdog fired")
            if isStillWaitingForFirstFrame {
                self.reloadFreshLiveHLSForRecovery()
            } else if self.stallRecoveryAttempts == 1 {
                if !self.seekToLiveEdgeForRecovery(item: item) {
                    self.reloadFreshLiveHLSForRecovery()
                }
            } else {
                self.reloadFreshLiveHLSForRecovery()
            }
        }
        stallRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout,
            execute: workItem
        )
    }

    func cancelLiveHLSStallRecovery() {
        stallRecoveryWorkItem?.cancel()
        stallRecoveryWorkItem = nil
    }

    @discardableResult
    func seekToLiveEdgeForRecovery(item: AVPlayerItem) -> Bool {
        let current = player.currentTime().seconds
        guard current.isFinite else { return false }

        let offset = liveHLSRecoveryOffset(for: item)
        var candidates: [(target: TimeInterval, edge: TimeInterval, source: String)] = []

        for range in item.loadedTimeRanges.map(\.timeRangeValue) {
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite,
                  end.isFinite,
                  current >= start - 0.05,
                  current <= end + 0.05 else { continue }

            let target = max(start, end - offset)
            if target > current + 0.5 {
                candidates.append((target, end, "loaded"))
            }
        }

        for range in item.seekableTimeRanges.map(\.timeRangeValue) {
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite else { continue }

            let target = max(start, end - offset)
            if target > current + 0.5 {
                candidates.append((target, end, "seekable"))
            }
        }

        let loadedCandidate = candidates
            .filter { $0.source == "loaded" }
            .max(by: { $0.target < $1.target })
        guard let candidate = loadedCandidate
            ?? candidates.max(by: { $0.target < $1.target }) else {
            SYPlayerConfig.shared.log(
                "Engine cannot seek live HLS during recovery: live edge is not ahead",
                level: .warning
            )
            return false
        }

        SYPlayerConfig.shared.log(
            "Engine recover live HLS by seeking from "
                + "\(String(format: "%.3f", current))s to "
                + "\(String(format: "%.3f", candidate.target))s "
                + "(source: \(candidate.source), edge: "
                + "\(String(format: "%.3f", candidate.edge))s)",
            level: .warning
        )

        let targetTime = CMTime(seconds: candidate.target, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(
            to: targetTime,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self, weak item] _ in
            guard let self, let item, self.item === item, self.shouldPlay else { return }
            self.player.play()
            self.scheduleLiveHLSStallRecoveryIfNeeded()
        }
        return true
    }

    func liveHLSRecoveryOffset(for item: AVPlayerItem) -> TimeInterval {
        let config = SYPlayerConfig.shared
        guard isLowLatencyHLS else {
            return max(0, config.liveHLSRecoveryLiveEdgeOffset)
        }

        return liveOffsetSeconds(from: item.configuredTimeOffsetFromLive)
            ?? liveOffsetSeconds(from: item.recommendedTimeOffsetFromLive)
            ?? max(0, config.lowLatencyHLSRecoveryLiveEdgeOffset)
    }

    func reloadFreshLiveHLSForRecovery() {
        guard let url = currentURL else { return }

        SYPlayerConfig.shared.log(
            "Engine recover live HLS with fresh item",
            level: .warning
        )
        hasDisplayedFirstFrame = false
        SYPlayerAssetWarmupStore.shared.invalidate(url: url)
        load(url: url, autoPlay: shouldPlay, allowWarmedAsset: false)
    }

    func failLiveHLSStartup() {
        guard isLiveHLS, shouldPlay, !hasDisplayedFirstFrame else { return }

        SYPlayerConfig.shared.log(
            "Engine live HLS failed to display a first frame after all recovery attempts",
            level: .error
        )
        cancelLiveHLSStallRecovery()
        shouldPlay = false
        player.pause()
        isPlaying = false
        state = .error("Live HLS first frame timeout")
    }

    /// Clears item-specific observers and state.
    func cleanupItemOnly() {
        SYPlayerConfig.shared.log("Engine cleanup current item", level: .debug)
        cancelLiveHLSStallRecovery()
        // notification
        if let item {
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemDidPlayToEndTime,
                object: item
            )
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemNewErrorLogEntry,
                object: item
            )
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemNewAccessLogEntry,
                object: item
            )
        }

        // KVO tokens
        itemStatusObs = nil
        loadedRangesObs = nil
        bufferEmptyObs = nil
        keepUpObs = nil

        item = nil
        isUsingWarmedAsset = false
        pendingSeek = nil
    }

    /// Removes player-level observers.
    func removePlayerObservers() {
        playerTimeControlStatusObs = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// Moves to the state matching the actual AVPlayer playback status.
    func setReadyState(duration: TimeInterval) {
        switch player.timeControlStatus {
        case .playing:
            state = .playing
        case .waitingToPlayAtSpecifiedRate where shouldPlay:
            state = .buffering
        default:
            state = shouldPlay ? .ready(duration: duration) : .paused
        }
    }

    @discardableResult
    func retryWithFreshAssetIfNeeded(
        for item: AVPlayerItem,
        reason: String
    ) -> Bool {
        guard self.item === item,
              isUsingWarmedAsset,
              !didRetryWithFreshAsset,
              let url = currentURL else { return false }

        switch state {
        case .preparing, .buffering:
            break
        default:
            return false
        }

        didRetryWithFreshAsset = true
        SYPlayerAssetWarmupStore.shared.invalidate(url: url)
        SYPlayerConfig.shared.log(
            "Engine retry warmed asset with fresh item (reason: \(reason), "
                + "url: \(url.absoluteString))",
            level: .warning
        )
        load(
            url: url,
            autoPlay: currentAutoPlay,
            allowWarmedAsset: false
        )
        return true
    }

    func logFailureDiagnostics(for item: AVPlayerItem) {
        let source = isUsingWarmedAsset ? "warmed" : "fresh"
        let url = urlAsset?.url.absoluteString ?? "unknown"
        SYPlayerConfig.shared.log(
            "Engine item failed (asset: \(source), url: \(url), error: \(errorSummary(item.error)))",
            level: .error
        )
        logErrorLog(for: item, context: "item failed")
        logAccessLog(for: item, context: "item failed")
    }

    @discardableResult
    func logErrorLog(
        for item: AVPlayerItem,
        context: String
    ) -> AVPlayerItemErrorLogEvent? {
        guard let event = item.errorLog()?.events.last else {
            SYPlayerConfig.shared.log(
                "Engine error log unavailable (\(context))",
                level: .warning
            )
            return nil
        }

        let comment = event.errorComment ?? "none"
        let uri = event.uri ?? "none"
        let server = event.serverAddress ?? "none"
        let session = event.playbackSessionID ?? "none"
        lastErrorStatusCode = event.errorStatusCode
        lastErrorComment = event.errorComment
        SYPlayerConfig.shared.log(
            "Engine error log (\(context)): domain=\(event.errorDomain), "
                + "status=\(event.errorStatusCode), comment=\(comment), "
                + "uri=\(uri), server=\(server), session=\(session)",
            level: .error
        )
        return event
    }

    func logAccessLog(for item: AVPlayerItem, context: String) {
        guard let event = item.accessLog()?.events.last else {
            SYPlayerConfig.shared.log(
                "Engine access log unavailable (\(context))",
                level: .debug
            )
            return
        }

        let uri = event.uri ?? "none"
        let server = event.serverAddress ?? "none"
        let session = event.playbackSessionID ?? "none"
        let playbackType = event.playbackType ?? "none"
        SYPlayerConfig.shared.log(
            "Engine access log (\(context)): uri=\(uri), server=\(server), "
                + "session=\(session), type=\(playbackType), "
                + "requests=\(event.numberOfMediaRequests), "
                + "bytes=\(event.numberOfBytesTransferred), transfer=\(event.transferDuration)s, "
                + "observedBitrate=\(event.observedBitrate), indicatedBitrate=\(event.indicatedBitrate), "
                + "stalls=\(event.numberOfStalls), startup=\(event.startupTime)s",
            level: .debug
        )
    }

    func errorSummary(_ error: Error?, depth: Int = 0) -> String {
        guard let error else { return "none" }

        let nsError = error as NSError
        var summary = "\(nsError.domain):\(nsError.code) \(nsError.localizedDescription)"
        if let reason = nsError.localizedFailureReason {
            summary += ", reason=\(reason)"
        }
        if let suggestion = nsError.localizedRecoverySuggestion {
            summary += ", suggestion=\(suggestion)"
        }
        if depth < 3,
           let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            summary += ", underlying={\(errorSummary(underlying, depth: depth + 1))}"
        }
        return summary
    }
}
