//
//  SYPlayer.swift
//  SmartYard
//
//  Created by Александр Попов on 08.08.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import UIKit
import SnapKit
import AVFoundation

protocol SYPlayerDelegate: AnyObject {
    /// Called when the player state changes.
    func syPlayer(
        player: SYPlayer,
        playerStateDidChange state: SYPlayerState
    )

    /// Called when the playing flag changes.
    func syPlayer(
        player: SYPlayer,
        playerIsPlaying playing: Bool
    )

    /// Called when the player orientation changes.
    func syPlayer(
        player: SYPlayer,
        playerOrientationChanged isLandscape: Bool
    )

    /// Called when buffered time changes.
    func syPlayer(
        player: SYPlayer,
        loadedTimeDidChange loadedDuration: TimeInterval,
        totalDuration: TimeInterval
    )

    /// Called when play time changes.
    func syPlayer(
        player: SYPlayer,
        playTimeDidChange currentTime: TimeInterval,
        totalTime: TimeInterval
    )
}

final class SYPlayer: UIView {

    // MARK: - Public
    weak var delegate: SYPlayerDelegate?

    var playOrientationChanged: ((Bool) -> Void)?
    var backBlock: (() -> Void)?
    var selectFavoriteBlock: (() -> Void)?

    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            playerLayer.videoGravity = videoGravity
            webRTCEngine.rendererView.videoContentMode = rtcVideoContentMode
        }
    }

    var aspectRatio: SYPlayerAspectRatio {
        get { playerLayer.aspectRatio }
        set { playerLayer.aspectRatio = newValue }
    }

    /// Текущее состояние проигрывания
    var isPlaying: Bool { isCurrentVideoWHEP ? webRTCEngine.isPlaying : engine.isPlaying }

    // MARK: - Private UI
    private let playerLayer = SYPlayerLayerView()
    private let controlView = SYPlayerControlView()
    private let engine = SYPlayerEngine()
    private let webRTCEngine = SYWebRTCPlayerEngine()

    // MARK: - Private state
    private var resource: SYPlayerResource?
    private var currentVideoIndex: Int = 0

    private var isPauseByUser: Bool = false
    private var isPlayToTheEnd: Bool = false
    private var isItemLoaded: Bool = false
    private var didAnimateVideoFadeIn: Bool = false

    private var isPortrait: Bool { bounds.height > bounds.width }
    private var currentVideo: SYPlayerResourceVideo? { resource?.video(at: currentVideoIndex) }
    private var isCurrentVideoWHEP: Bool {
        guard let currentVideo else { return false }
        if case .whep = currentVideo.source { return true }
        return false
    }
    private var rtcVideoContentMode: UIView.ContentMode {
        switch videoGravity {
        case .resizeAspectFill:
            return .scaleAspectFill
        case .resize:
            return .scaleToFill
        default:
            return .scaleAspectFit
        }
    }

    // MARK: - Init
    /// Creates the player with a frame.
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    /// Creates the player from a storyboard or xib.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        prepareToDealloc()
    }

    /// Builds the view hierarchy and hooks up the engine.
    private func setup() {
        SYPlayerConfig.shared.log("Player setup", level: .debug)
        backgroundColor = SYPlayerConfig.shared.colors.playerBackgroundColor

        playerLayer.videoGravity = videoGravity
        playerLayer.attach(player: engine.player)
        addSubview(playerLayer)
        addSubview(webRTCEngine.rendererView)

        playerLayer.snp.makeConstraints {
            $0.directionalEdges.equalToSuperview()
        }

        webRTCEngine.rendererView.isHidden = true
        webRTCEngine.rendererView.videoContentMode = rtcVideoContentMode
        webRTCEngine.rendererView.snp.makeConstraints {
            $0.directionalEdges.equalToSuperview()
        }

        playerLayer.onReadyForDisplay = { [weak self] isReady in
            guard let self, isReady else { return }
            self.revealVideoIfNeeded()
            self.controlView.hideImageView()
        }

        addSubview(controlView)
        controlView.delegate = self
        controlView.player = self
        controlView.configure(videoType: SYPlayerConfig.shared.videoType)

        controlView.snp.makeConstraints {
            $0.directionalEdges.equalToSuperview()
        }

        controlView.updateUI(isPortrait: isPortrait)

        // Orientation
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onOrientationChanged),
            name: UIApplication.didChangeStatusBarOrientationNotification,
            object: nil
        )

        engine.delegate = self
        webRTCEngine.delegate = self
    }

    // MARK: - Public API
    /// Loads a resource and prepares playback.
    func setVideo(resource: SYPlayerResource, videoIndex: Int = 0) {
        SYPlayerConfig.shared.log(
            "Player setVideo name: \(resource.name), index: \(videoIndex), videos: \(resource.videos.count), type: \(resource.videoType), hasSound: \(resource.hasSound)",
            level: .info
        )
        engine.stop()
        webRTCEngine.stop()
        self.resource = resource
        currentVideoIndex = videoIndex

        // Reset flags
        isPlayToTheEnd = false
        isItemLoaded = false
        isPauseByUser = false
        prepareVideoForSmoothStart()

        controlView.configure(videoType: resource.videoType, hasSound: resource.hasSound)

        controlView.prepareUI(for: resource, selectedIndex: videoIndex)

        if resource.videoType == .online,
           let video = resource.video(at: videoIndex),
           video.url.pathExtension.lowercased() == "m3u8" {
            SYPlayerConfig.shared.log(
                "Player prefetch HLS for \(video.url.absoluteString)",
                level: .debug
            )
            SYHLSPrefetchController.shared.prefetch(urls: [video.url])
        }

        let shouldAutoPlay = SYPlayerConfig.shared.shouldAutoPlay

        if shouldAutoPlay {
            // Сразу начинаем
            SYPlayerConfig.shared.log("Player autoPlay on setVideo", level: .debug)
            startCurrentVideo(autoPlay: true)
        }
    }

    /// Attempts to auto-play when allowed by user state.
    func autoPlay() {
        guard !isPauseByUser, !isPlayToTheEnd else {
            SYPlayerConfig.shared.log(
                "Player autoPlay skipped (isPauseByUser: \(isPauseByUser), isPlayToTheEnd: \(isPlayToTheEnd))",
                level: .debug
            )
            return
        }
        SYPlayerConfig.shared.log("Player autoPlay", level: .debug)
        play()
    }

    /// Starts playback for the current resource.
    func play() {
        guard resource != nil else {
            SYPlayerConfig.shared.log("Player play ignored (no resource)", level: .warning)
            return
        }

        if case .ended = engine.state {
            SYPlayerConfig.shared.log("Player restart from end", level: .debug)
            engine.seek(to: 0) { [weak self] in
                self?.engine.play()
            }
            isPlayToTheEnd = false
            isPauseByUser = false
            return
        }

        if !isItemLoaded {
            startCurrentVideo(autoPlay: true)
        } else if isCurrentVideoWHEP {
            SYPlayerConfig.shared.log("Player play existing WHEP item", level: .debug)
            webRTCEngine.play()
        } else {
            SYPlayerConfig.shared.log("Player play existing item", level: .debug)
            engine.play()
        }

        isPauseByUser = false
    }

    /// Pauses playback; if allowAutoPlay is true, treat it as temporary.
    func pause(allowAutoPlay allow: Bool = false) {
        SYPlayerConfig.shared.log("Player pause (allowAutoPlay: \(allow))", level: .debug)
        isCurrentVideoWHEP ? webRTCEngine.pause() : engine.pause()
        engine.player.isMuted = allow ? engine.player.isMuted : true
        isPauseByUser = !allow
    }

    /// Seeks to a specific time in seconds.
    func seek(_ to: TimeInterval, completion: (() -> Void)? = nil) {
        guard to.isFinite, to >= 0 else {
            SYPlayerConfig.shared.log("Player seek ignored (invalid time: \(to))", level: .warning)
            return
        }
        SYPlayerConfig.shared.log("Player seek to \(to)s", level: .debug)
        engine.seek(to: to, completion: completion)
    }

    /// Mutes or unmutes the underlying player.
    func setMuted(_ muted: Bool) {
        SYPlayerConfig.shared.log("Player setMuted: \(muted)", level: .debug)
        guard !isCurrentVideoWHEP else { return }
        engine.player.isMuted = muted
    }

    /// Updates UI layout for the given orientation.
    func updateUI(_ isPortrait: Bool) {
        controlView.updateUI(isPortrait: isPortrait)
    }

    /// Updates the control view UI mode.
    func setMode(_ mode: SYPlayerUIMode) {
        controlView.setMode(mode)
    }

    /// Replaces the right-side vertical accessory controls.
    func setRightAccessoryItems(_ items: [SYPlayerControlAccessoryItem]) {
        controlView.setRightAccessoryItems(items)
    }

    /// Updates a right-side accessory control by id.
    func updateRightAccessoryItem(
        id: String,
        _ update: (inout SYPlayerControlAccessoryItem) -> Void
    ) {
        controlView.updateRightAccessoryItem(id: id, update)
    }

    /// Removes a right-side accessory control by id.
    func removeRightAccessoryItem(id: String) {
        controlView.removeRightAccessoryItem(id: id)
    }

    /// Removes all right-side accessory controls.
    func removeAllRightAccessoryItems() {
        controlView.removeAllRightAccessoryItems()
    }

    /// Enables or disables automatic hiding of controls while playback is active.
    func setControlsAutoHideEnabled(_ isEnabled: Bool) {
        controlView.setControlsAutoHideEnabled(isEnabled)
    }

    /// Toggles controls visibility from an external tap surface.
    func toggleControlsVisibility() {
        controlView.toggleControlsVisibility()
    }

    /// Moves controls to a separate container, or back to the player when container is nil.
    func setControlsContainer(_ container: UIView?) {
        let targetContainer = container ?? self
        guard controlView.superview !== targetContainer else { return }

        SYPlayerConfig.shared.log(
            "Player setControlsContainer external: \(container != nil)",
            level: .debug
        )
        controlView.removeFromSuperview()
        targetContainer.addSubview(controlView)
        controlView.snp.remakeConstraints {
            $0.directionalEdges.equalToSuperview()
        }
        controlView.updateUI(isPortrait: isPortrait)
    }

    /// Releases resources and observers before deallocation.
    func prepareToDealloc() {
        SYPlayerConfig.shared.log("Player prepareToDealloc", level: .info)
        setControlsContainer(nil)
        engine.cleanup()
        webRTCEngine.cleanup()
        playerLayer.detachPlayer()
        controlView.prepareToDealloc()
    }

    // MARK: - Orientation
    /// Handles system orientation changes.
    @objc private func onOrientationChanged() {
        updateUI(isPortrait)

        SYPlayerConfig.shared.log(
            "Player orientation changed (isLandscape: \(!isPortrait))",
            level: .debug
        )
        delegate?.syPlayer(player: self, playerOrientationChanged: !isPortrait)
        playOrientationChanged?(!isPortrait)
    }

    // MARK: - Private
    /// Starts playback for the current video index.
    private func startCurrentVideo(autoPlay: Bool) {
        guard let video = resource?.video(at: currentVideoIndex) else {
            SYPlayerConfig.shared.log(
                "Player startCurrentVideo failed (no video at index \(currentVideoIndex))",
                level: .error
            )
            return
        }

        isItemLoaded = true
        SYPlayerConfig.shared.log(
            "Player startCurrentVideo url: \(video.url.absoluteString), autoPlay: \(autoPlay)",
            level: .info
        )

        switch video.source {
        case .hls(let url):
            startHLSVideo(url: url, autoPlay: autoPlay)
        case .whep(let endpointURL, let iceServers):
            startWHEPVideo(endpointURL: endpointURL, iceServers: iceServers, autoPlay: autoPlay)
        }
    }

    private func startHLSVideo(url: URL, autoPlay: Bool) {
        webRTCEngine.stop()
        webRTCEngine.rendererView.isHidden = true
        playerLayer.isHidden = false
        playerLayer.attach(player: engine.player)
        engine.set(url: url, autoPlay: autoPlay)
    }

    private func startWHEPVideo(endpointURL: URL, iceServers: [String], autoPlay: Bool) {
        engine.stop()
        playerLayer.detachPlayer()
        playerLayer.isHidden = true
        webRTCEngine.rendererView.isHidden = false
        webRTCEngine.set(endpointURL: endpointURL, iceServers: iceServers, autoPlay: autoPlay)
    }

    private func prepareVideoForSmoothStart() {
        didAnimateVideoFadeIn = false
        playerLayer.layer.removeAllAnimations()
        playerLayer.alpha = 0
        webRTCEngine.rendererView.layer.removeAllAnimations()
        webRTCEngine.rendererView.alpha = 0
    }

    private func revealVideoIfNeeded() {
        guard !didAnimateVideoFadeIn else { return }
        guard playerLayer.isReadyForDisplay else { return }
        guard case .playing = engine.state else { return }

        didAnimateVideoFadeIn = true
        controlView.playbackDidBecomeVisible()
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) { [weak self] in
            guard let self else { return }
            self.playerLayer.alpha = 1
        }
    }

    private func revealWebRTCVideoIfNeeded() {
        guard !didAnimateVideoFadeIn else { return }

        didAnimateVideoFadeIn = true
        controlView.playbackDidBecomeVisible()
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) { [weak self] in
            self?.webRTCEngine.rendererView.alpha = 1
        }
    }

    private func fallbackToNextVideoIfPossible() -> Bool {
        guard let resource,
              currentVideoIndex + 1 < resource.videos.count
        else {
            return false
        }

        currentVideoIndex += 1
        isItemLoaded = false
        prepareVideoForSmoothStart()
        SYPlayerConfig.shared.log(
            "Player fallback to video index \(currentVideoIndex)",
            level: .warning
        )
        startCurrentVideo(autoPlay: true)
        return true
    }
}

// MARK: - SYPlayerEngineDelegate
extension SYPlayer: SYPlayerEngineDelegate {
    /// Receives playback state updates from the engine.
    func playerEngine(
        _ engine: SYPlayerEngine,
        stateDidChange state: SYPlayerState
    ) {
        controlView.playerStateDidChange(state: state)
        delegate?.syPlayer(player: self, playerStateDidChange: state)

        switch state {
        case .ready, .playing:
            if case .playing = state {
                revealVideoIfNeeded()
            }
            if playerLayer.isReadyForDisplay {
                controlView.hideImageView()
            }
            if case .ready = state { isPlayToTheEnd = false }
        case .ended:
            isPlayToTheEnd = true
        case .error:
            if !fallbackToNextVideoIfPossible() {
                isPlayToTheEnd = false
            }
        case .idle:
            isPlayToTheEnd = false
        default:
            break
        }
    }

    /// Receives buffer progress updates from the engine.
    func playerEngine(
        _ engine: SYPlayerEngine,
        loadedTimeDidChange loaded: TimeInterval,
        total: TimeInterval
    ) {
        delegate?.syPlayer(
            player: self,
            loadedTimeDidChange: loaded,
            totalDuration: total
        )
    }

    /// Receives play time updates from the engine.
    func playerEngine(
        _ engine: SYPlayerEngine,
        playTimeDidChange current: TimeInterval,
        total: TimeInterval
    ) {
        delegate?.syPlayer(
            player: self,
            playTimeDidChange: current,
            totalTime: total
        )
    }

    /// Receives playing flag updates from the engine.
    func playerEngine(
        _ engine: SYPlayerEngine,
        isPlayingDidChange isPlaying: Bool
    ) {
        controlView.playStateDidChange(isPlaying: isPlaying)
        delegate?.syPlayer(player: self, playerIsPlaying: isPlaying)
    }
}

// MARK: - SYWebRTCPlayerEngineDelegate
extension SYPlayer: SYWebRTCPlayerEngineDelegate {
    func webRTCPlayerEngine(
        _ engine: SYWebRTCPlayerEngine,
        stateDidChange state: SYPlayerState
    ) {
        if case .error = state, fallbackToNextVideoIfPossible() {
            return
        }

        controlView.playerStateDidChange(state: state)
        delegate?.syPlayer(player: self, playerStateDidChange: state)

        switch state {
        case .playing:
            controlView.hideImageView()
            controlView.playbackDidBecomeVisible()
            revealWebRTCVideoIfNeeded()
            isPlayToTheEnd = false
        case .ready:
            isPlayToTheEnd = false
        case .ended:
            isPlayToTheEnd = true
        case .error, .idle:
            isPlayToTheEnd = false
        default:
            break
        }
    }

    func webRTCPlayerEngine(
        _ engine: SYWebRTCPlayerEngine,
        isPlayingDidChange isPlaying: Bool
    ) {
        controlView.playStateDidChange(isPlaying: isPlaying)
        delegate?.syPlayer(player: self, playerIsPlaying: isPlaying)
    }
}

// MARK: - SYPlayerControlViewDelegate
extension SYPlayer: SYPlayerControlViewDelegate {

    /// Applies the requested playback rate.
    func controlView(
        controlView: SYPlayerControlView,
        didChangeVideoPlaybackRate rate: Float
    ) {
        guard !isCurrentVideoWHEP else { return }
        engine.player.rate = rate
    }

    /// Handles control button actions from the UI.
    func controlView(
        controlView: SYPlayerControlView,
        didPressButton button: UIButton
    ) {
        guard let action = SYPlayerControlView.ButtonType(rawValue: button.tag) else { return }
        SYPlayerConfig.shared.log("Player control action: \(action)", level: .debug)

        switch action {
        case .play:
            if button.isSelected {
                pause()
            } else {
                if isPlayToTheEnd { isPlayToTheEnd = false }
                play()
            }

        case .pause:
            pause()

        case .favourite:
            break

        case .fullscreenToggle:
            backBlock?()
        }
    }
}
