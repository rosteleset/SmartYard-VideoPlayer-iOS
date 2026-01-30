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
}

final class SYPlayerEngine {
    weak var delegate: SYPlayerEngineDelegate?

    private(set) var player: AVPlayer = AVPlayer()

    private var item: AVPlayerItem?
    private var urlAsset: AVURLAsset?

    // Time observer token
    private var timeObserverToken: Any?

    // KVO
    private var itemStatusObs: NSKeyValueObservation?
    private var loadedRangesObs: NSKeyValueObservation?
    private var bufferEmptyObs: NSKeyValueObservation?
    private var keepUpObs: NSKeyValueObservation?

    private var playerRateObs: NSKeyValueObservation?

    private var pendingSeek: TimeInterval?

    private(set) var state: SYPlayerState = .idle {
        didSet {
            guard oldValue != state else { return }
            let level: SYPlayerLogLevel = {
                if case .error = state { return .error }
                return .debug
            }()
            SYPlayerConfig.shared.log(
                "Engine state changed from \(oldValue) to \(state)",
                level: level
            )
            delegate?.playerEngine(self, stateDidChange: state)
        }
    }

    private(set) var isPlaying: Bool = false {
        didSet {
            guard oldValue != isPlaying else { return }
            SYPlayerConfig.shared.log(
                "Engine isPlaying changed from \(oldValue) to \(isPlaying)",
                level: .debug
            )
            delegate?.playerEngine(self, isPlayingDidChange: isPlaying)
        }
    }

    deinit { cleanup() }

    // MARK: - Public API

    /// Loads a URL into the player and optionally starts playback.
    func set(url: URL, autoPlay: Bool = true) {
        SYPlayerConfig.shared.log(
            "Engine set URL: \(url.absoluteString), autoPlay: \(autoPlay)",
            level: .info
        )
        state = .preparing

        cleanupItemOnly()

        let asset = AVURLAsset(url: url)
        self.urlAsset = asset

        let newItem = AVPlayerItem(asset: asset)
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = SYPlayerConfig.shared.allowNetworkResourcesWhilePaused
        newItem.preferredForwardBufferDuration = SYPlayerConfig.shared.preferredForwardBufferDuration

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
        player.play()
        isPlaying = true

        // если уже ready — будет playing; если нет — останемся buffering/preparing
        if case .ready = state { state = .playing }
    }

    /// Pauses playback if an item is loaded.
    func pause() {
        guard player.currentItem != nil else { return }

        SYPlayerConfig.shared.log("Engine pause", level: .debug)
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
        state = .idle
        cleanupItemOnly()
        player.replaceCurrentItem(with: nil)
    }

    /// Stops playback and removes observers.
    func cleanup() {
        SYPlayerConfig.shared.log("Engine cleanup", level: .debug)
        stop()
        removePeriodicTimeObserver()
        removePlayerObservers()
    }
}

private extension SYPlayerEngine {

    // MARK: - Observing

    /// Observes player rate changes to update playing state.
    func observe(_ player: AVPlayer) {
        // player.rate -> isPlaying + статус
        playerRateObs = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            guard let self else { return }

            // проверка играем ли мы сейчас
            let playingNow = p.rate != 0
            isPlaying = playingNow

            // если пошёл rate и мы готовы —> считаем playing
            if playingNow { if case .ready = state { state = .playing } }
        }
    }

    /// Observes item status, buffering, and loaded ranges.
    func observe(_ item: AVPlayerItem) {
        // status -> ready/error
        itemStatusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }

            switch item.status {
            case .unknown:
                state = .buffering

            case .readyToPlay:
                let total = item.duration.seconds
                let duration = total.isFinite ? total : 0
                state = .ready(duration: duration)

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
                state = .error(item.error?.localizedDescription ?? "AVPlayerItem failed")
                isPlaying = false

            @unknown default:
                state = .error("Unknown AVPlayerItem status")
                isPlaying = false
            }
        }

        // loadedTimeRanges -> прогресс буфера
        loadedRangesObs = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            guard let self, let loaded = availableDuration(for: item) else { return }

            let total = item.duration.seconds
            let totalSafe = total.isFinite ? total : 0

            delegate?.playerEngine(self, loadedTimeDidChange: loaded, total: totalSafe)
        }

        // playbackBufferEmpty -> buffering
        bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self else { return }

            if item.isPlaybackBufferEmpty {
                // Не трогаем playing напрямую: rate обсервится отдельно
                state = .buffering
            }
        }

        // playbackLikelyToKeepUp -> buffer finished
        keepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }

            if item.isPlaybackLikelyToKeepUp {
                // если мы уже готовы/играем — не трогаем лишний раз
                if case .buffering = state {
                    // если длительность известна — можем перевести в ready
                    let total = item.duration.seconds
                    let duration = total.isFinite ? total : 0
                    state = .ready(duration: duration)
                }
            }
        }

        // ended notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidPlayToEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    /// Handles playback completion.
    @objc func itemDidPlayToEnd() {
        SYPlayerConfig.shared.log("Engine item did play to end", level: .info)
        state = .ended
        isPlaying = false

        // Финальный прогресс
        if let item = player.currentItem {
            let total = item.duration.seconds
            let totalSafe = total.isFinite ? total : 0
            delegate?.playerEngine(self, playTimeDidChange: totalSafe, total: totalSafe)
        }
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

            let current = time.seconds
            let total = item.duration.seconds

            let currentSafe = current.isFinite ? current : 0
            let totalSafe = total.isFinite ? total : 0

            delegate?.playerEngine(self, playTimeDidChange: currentSafe, total: totalSafe)

            // Авто-поддержка buffering/ready по текущему состоянию item
            if item.status == .failed {
                state = .error(item.error?.localizedDescription ?? "Playback failed")
            } else if item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
                // не насилуем состояние, если уже playing/paused/ended
                switch state {
                case .buffering: state = .ready(duration: totalSafe)
                default: break
                }
            } else {
                // если реально не тянет — buffering
                // (опционально: включать только когда rate==0)
                if case .playing = state {
                    // не трогаем, пока играет
                } else {
                    state = .buffering
                }
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

    /// Clears item-specific observers and state.
    func cleanupItemOnly() {
        SYPlayerConfig.shared.log("Engine cleanup current item", level: .debug)
        // notification
        if let item {
            NotificationCenter.default.removeObserver(
                self,
                name: .AVPlayerItemDidPlayToEndTime,
                object: item
            )
        }

        // KVO tokens
        itemStatusObs = nil
        loadedRangesObs = nil
        bufferEmptyObs = nil
        keepUpObs = nil

        item = nil
        pendingSeek = nil
    }

    /// Removes player-level observers.
    func removePlayerObservers() {
        playerRateObs = nil
        NotificationCenter.default.removeObserver(self)
    }
}
