//
//  SYPlayerController.swift
//  SmartYard
//
//  Created by Александр Попов on 25.12.2025.
//  Copyright © 2025 LanTa. All rights reserved.
//

import UIKit
import Foundation
import RxSwift
import RxCocoa

public protocol SYPlayerControllerDelegate: AnyObject {
    /// Called when the player state changes.
    func playerController(
        _ controller: SYPlayerController,
        stateDidChange state: SYPlayerState
    )

    /// Called when the playing flag changes.
    func playerController(
        _ controller: SYPlayerController,
        isPlaying: Bool
    )
}

public final class SYPlayerController {

    // MARK: - Delegate

    public weak var delegate: SYPlayerControllerDelegate?

    // MARK: - State

    private let playerView = SYPlayer()
    private var resource: SYPlayerResource?
    private var currentContainer: UIView?

    private let disposeBag = DisposeBag()

    // MARK: - Rx Outputs

    private let stateRelay = BehaviorRelay<SYPlayerState>(value: .idle)
    private let isPlayingRelay = BehaviorRelay<Bool>(value: false)
    private let progressRelay = BehaviorRelay<(TimeInterval, TimeInterval)>(value: (0, 0))
    private let bufferRelay = BehaviorRelay<(TimeInterval, TimeInterval)>(value: (0, 0))
    private let isAttachedRelay = BehaviorRelay<Bool>(value: false)

    public var state: Driver<SYPlayerState> { stateRelay.asDriver() }
    public var isPlaying: Driver<Bool> { isPlayingRelay.asDriver() }
    public var progress: Driver<(TimeInterval, TimeInterval)> { progressRelay.asDriver() }
    public var buffer: Driver<(TimeInterval, TimeInterval)> { bufferRelay.asDriver() }
    public var isAttached: Driver<Bool> { isAttachedRelay.asDriver() }

    /// Автозапуск при появлении "владельца" (экрана/вью).
    public var shouldAutoPlayOnAppear: Bool = true

    // MARK: - Init
    /// Creates a controller and optionally sets an initial resource.
    public init(resource: SYPlayerResource? = nil) {
        SYPlayerConfig.shared.log(
            "Controller init (hasResource: \(resource != nil))",
            level: .info
        )
        self.resource = resource
        playerView.delegate = self
        bindAppLifecycle()

        if let resource {
            playerView.setVideo(resource: resource)
        }
    }

    deinit {
        if Thread.isMainThread {
            stopHard()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.stopHard()
            }
        }
    }

    // MARK: - Public API
    /// Прикрепить плеер к контейнеру (старый контейнер отцепится).
    /// По умолчанию НЕ паузит — чтобы можно было "переезжать" в fullscreen без stop/start.
    /// Attaches the player view to a container.
    public func attach(to container: UIView, pauseBeforeDetach: Bool = false) {
        if currentContainer === container {
            SYPlayerConfig.shared.log("Controller attach skipped (already attached)", level: .debug)
            return
        }

        SYPlayerConfig.shared.log(
            "Controller attach to container (pauseBeforeDetach: \(pauseBeforeDetach))",
            level: .info
        )
        detach(pause: pauseBeforeDetach)

        currentContainer = container
        container.addSubview(playerView)

        playerView.frame = container.bounds
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        isAttachedRelay.accept(true)
    }

    /// Отцепить плеер от текущего контейнера.
    /// pause=false — "перецепить" без дерготни.
    /// Detaches the player view from its current container.
    public func detach(pause: Bool = false) {
        guard playerView.superview != nil else {
            SYPlayerConfig.shared.log("Controller detach skipped (no superview)", level: .debug)
            currentContainer = nil
            isAttachedRelay.accept(false)
            return
        }

        SYPlayerConfig.shared.log("Controller detach (pause: \(pause))", level: .info)
        if pause { playerView.pause() }

        playerView.removeFromSuperview()
        playerView.autoresizingMask = []
        currentContainer = nil
        isAttachedRelay.accept(false)
    }

    /// Установить ресурс. Важно: здесь нет автозапуска — решает owner (play / onAppear).
    /// Sets a new resource without auto-play.
    public func set(resource: SYPlayerResource) {
        SYPlayerConfig.shared.log(
            "Controller set resource name: \(resource.name), videos: \(resource.videos.count), type: \(resource.videoType)",
            level: .info
        )
        self.resource = resource
        playerView.setVideo(resource: resource)
    }

    /// Updates the player aspect ratio.
    public func setAspectRatio(_ ratio: SYPlayerAspectRatio) {
        SYPlayerConfig.shared.log("Controller setAspectRatio: \(ratio)", level: .debug)
        playerView.aspectRatio = ratio
    }

    /// Updates control UI mode (default or fullscreen).
    public func setMode(_ mode: SYPlayerUIMode) {
        SYPlayerConfig.shared.log("Controller setMode: \(mode)", level: .debug)
        playerView.setMode(mode)
    }

    /// Mutes or unmutes the player.
    public func setMuted(_ muted: Bool) {
        SYPlayerConfig.shared.log("Controller setMuted: \(muted)", level: .debug)
        playerView.setMuted(muted)
    }

    /// Sets a close handler for the player view.
    public func setCloseHandler(_ handler: (() -> Void)?) {
        SYPlayerConfig.shared.log("Controller setCloseHandler", level: .debug)
        playerView.backBlock = handler
    }

    /// Starts playback if a resource is set.
    public func play() {
        guard resource != nil else {
            SYPlayerConfig.shared.log("Controller play ignored (no resource)", level: .warning)
            return
        }
        SYPlayerConfig.shared.log("Controller play", level: .debug)
        playerView.play()
    }

    /// Pauses playback.
    public func pause() {
        SYPlayerConfig.shared.log("Controller pause", level: .debug)
        playerView.pause()
    }

    /// Seeks to a given time in seconds.
    public func seek(_ time: TimeInterval) {
        SYPlayerConfig.shared.log("Controller seek to \(time)s", level: .debug)
        playerView.seek(time, completion: nil)
    }

    /// Call when the owner view appears to auto-play if enabled.
    public func onAppear() {
        guard shouldAutoPlayOnAppear else {
            SYPlayerConfig.shared.log("Controller onAppear skipped (autoPlay disabled)", level: .debug)
            return
        }
        guard resource != nil else {
            SYPlayerConfig.shared.log("Controller onAppear skipped (no resource)", level: .debug)
            return
        }
        SYPlayerConfig.shared.log("Controller onAppear autoPlay", level: .debug)
        playerView.autoPlay()
    }

    /// Call when the owner view disappears to pause safely.
    public func onDisappear() {
        SYPlayerConfig.shared.log("Controller onDisappear", level: .debug)
        playerView.pause(allowAutoPlay: true)
    }

    /// Fully stops playback and clears state.
    public func stopHard() {
        SYPlayerConfig.shared.log("Controller stopHard", level: .info)
        detach(pause: false)
        playerView.pause()
        playerView.prepareToDealloc()

        stateRelay.accept(.idle)
        isPlayingRelay.accept(false)
        progressRelay.accept((0, 0))
        bufferRelay.accept((0, 0))

        resource = nil
    }

    // MARK: - Private
    /// Observes app lifecycle to pause/resume playback.
    private func bindAppLifecycle() {
        NotificationCenter.default.rx.notification(UIApplication.didEnterBackgroundNotification)
            .asDriver { _ in .empty() }
            .drive { [weak self] _ in
                SYPlayerConfig.shared.log("Controller app did enter background", level: .debug)
                self?.playerView.pause(allowAutoPlay: true)
            }
            .disposed(by: disposeBag)

        NotificationCenter.default.rx.notification(UIApplication.willEnterForegroundNotification)
            .asDriver { _ in .empty() }
            .drive { [weak self] _ in
                guard let self else { return }

                if shouldAutoPlayOnAppear, resource != nil {
                    SYPlayerConfig.shared.log("Controller app will enter foreground", level: .debug)
                    playerView.autoPlay()
                }
            }
            .disposed(by: disposeBag)
    }
}

// MARK: - SYPlayerDelegate
extension SYPlayerController: SYPlayerDelegate {
    /// Propagates state updates to delegates and drivers.
    func syPlayer(
        player: SYPlayer,
        playerStateDidChange state: SYPlayerState
    ) {
        delegate?.playerController(self, stateDidChange: state)
        stateRelay.accept(state)
    }

    /// Propagates playing flag updates.
    func syPlayer(
        player: SYPlayer,
        playerIsPlaying playing: Bool
    ) {
        delegate?.playerController(self, isPlaying: playing)
        isPlayingRelay.accept(playing)
    }

    /// Handles orientation changes from the player (currently unused).
    func syPlayer(
        player: SYPlayer,
        playerOrientationChanged isLandscape: Bool
    ) {

    }

    /// Updates buffered progress outputs.
    func syPlayer(
        player: SYPlayer,
        loadedTimeDidChange
        loadedDuration: TimeInterval,
        totalDuration: TimeInterval
    ) {
        bufferRelay.accept((loadedDuration, totalDuration))
    }

    /// Updates playback progress outputs.
    func syPlayer(
        player: SYPlayer,
        playTimeDidChange currentTime: TimeInterval,
        totalTime: TimeInterval
    ) {
        progressRelay.accept((currentTime, totalTime))
    }
}
