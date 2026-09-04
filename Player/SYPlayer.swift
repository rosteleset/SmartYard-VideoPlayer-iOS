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
import RxSwift

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

    private static let lowLatencyManifestErrorStatusCode = -15415

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
    private var isFallbackPlayback = false
    private var didFallbackFromLowLatencyHLS = false
    private var didRetryLowLatencyHLSPlayback = false
    private var resolvedHLSLatencyMode: SYPlayerHLSLatencyMode?
    private var playbackDisposeBag = DisposeBag()
    private let lowLatencyFirstFrameFallbackDisposable = SerialDisposable()

    private var isPortrait: Bool { bounds.height > bounds.width }
    private var currentVideo: SYPlayerResourceVideo? { resource?.video(at: currentVideoIndex) }
    private var currentAutomaticLowLatencyVideo: SYPlayerResourceVideo? {
        guard resource?.videoType == .online,
              let currentVideo,
              currentVideo.hlsLatencyMode == .automatic,
              resolvedHLSLatencyMode == .lowLatency
        else {
            return nil
        }
        return currentVideo
    }
    private var currentHLSTransport: SYPlayerTransport {
        hlsTransport(for: currentVideo, resolvedMode: resolvedHLSLatencyMode)
    }
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
        cancelLowLatencyFirstFrameFallback()
        playbackDisposeBag = DisposeBag()
        self.resource = resource
        currentVideoIndex = videoIndex

        // Reset flags
        isPlayToTheEnd = false
        isItemLoaded = false
        isPauseByUser = false
        isFallbackPlayback = false
        resetHLSFallbackState()
        prepareVideoForSmoothStart()

        controlView.configure(videoType: resource.videoType, hasSound: resource.hasSound)

        controlView.prepareUI(for: resource, selectedIndex: videoIndex)

        let hlsVideo = resource.videos.first { video in
            guard case .hls = video.source else { return false }
            return true
        }
        if resource.videoType == .online, let hlsVideo {
            SYPlayerConfig.shared.log(
                "Player prefetch HLS for \(hlsVideo.url.absoluteString)",
                level: .debug
            )
            SYPlayerConfig.shared.prefetch(urls: [hlsVideo.url], maxCount: 1)
            inspectHLSManifestIfNeeded(for: hlsVideo)
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
            if let currentVideo {
                scheduleLowLatencyFirstFrameFallbackIfNeeded(
                    for: currentVideo,
                    autoPlay: true
                )
            }
        }

        isPauseByUser = false
    }

    /// Pauses playback; if allowAutoPlay is true, treat it as temporary.
    func pause(allowAutoPlay allow: Bool = false) {
        SYPlayerConfig.shared.log("Player pause (allowAutoPlay: \(allow))", level: .debug)
        cancelLowLatencyFirstFrameFallback()
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
        engine.player.isMuted = muted
        webRTCEngine.setMuted(muted)
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
        cancelLowLatencyFirstFrameFallback()
        lowLatencyFirstFrameFallbackDisposable.dispose()
        playbackDisposeBag = DisposeBag()
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
        case .hls:
            startHLSVideo(autoPlay: autoPlay)
        case .whep(let endpointURL, let iceServers):
            if let nextVideo = resource?.video(at: currentVideoIndex + 1),
               case .hls = nextVideo.source,
               SYStreamTransportPreferenceStore.shared.preferredHLSMode(
                   for: nextVideo.url
               ) != nil {
                SYPlayerConfig.shared.log(
                    "Player skip WHEP in favor of the remembered HLS transport",
                    level: .info
                )
                if fallbackToNextVideoIfPossible(announceTransportSwitch: false) { return }
            }

            if let cooldown = SYWHEPCooldownStore.shared.activeCooldown(for: endpointURL),
               let nextVideo = resource?.video(at: currentVideoIndex + 1),
               case .hls = nextVideo.source {
                let remainingSeconds = Int(ceil(cooldown.remaining))
                let message = "Player skip WHEP during cooldown "
                    + "(remaining: \(remainingSeconds)s, reason: \(cooldown.reason))"
                SYPlayerConfig.shared.log(
                    message,
                    level: .warning
                )
                if fallbackToNextVideoIfPossible(announceTransportSwitch: false) { return }
            }
            startWHEPVideo(endpointURL: endpointURL, iceServers: iceServers, autoPlay: autoPlay)
        }
    }

    private func startHLSVideo(autoPlay: Bool) {
        guard let video = currentVideo else { return }

        webRTCEngine.stop()
        configureHLSAudioSession()
        webRTCEngine.rendererView.isHidden = true
        playerLayer.isHidden = false
        playerLayer.attach(player: engine.player)

        let resolution = hlsResolution(for: video)
        resolvedHLSLatencyMode = resolution.mode

        if resource?.videoType == .online {
            controlView.setTransportState(
                isFallbackPlayback
                    ? .switchingToHLS(currentHLSTransport)
                    : .connecting(currentHLSTransport)
            )
        } else {
            controlView.setTransportState(.hidden)
        }

        engine.set(
            url: resolution.playbackURL,
            autoPlay: autoPlay,
            isLiveHLS: resource?.videoType == .online,
            hlsLatencyMode: resolution.mode
        )
        scheduleLowLatencyFirstFrameFallbackIfNeeded(
            for: video,
            autoPlay: autoPlay
        )
    }

    private func configureHLSAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback
            )
        } catch {
            SYPlayerConfig.shared.log(
                "HLS audio session configuration failed: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func startWHEPVideo(endpointURL: URL, iceServers: [String], autoPlay: Bool) {
        cancelLowLatencyFirstFrameFallback()
        isFallbackPlayback = false
        controlView.setTransportState(.connecting(.webRTC))
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

        cancelLowLatencyFirstFrameFallback()
        didAnimateVideoFadeIn = true
        recordSuccessfulHLSPlayback()
        if resource?.videoType == .online {
            controlView.setTransportState(
                .playing(
                    currentHLSTransport,
                    announceConnection: isFallbackPlayback
                )
            )
        }
        isFallbackPlayback = false
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

    private func fallbackToNextVideoIfPossible(
        announceTransportSwitch: Bool = true
    ) -> Bool {
        guard let resource,
              let currentVideo,
              currentVideoIndex + 1 < resource.videos.count
        else {
            return false
        }

        currentVideoIndex += 1
        cancelLowLatencyFirstFrameFallback()
        resetHLSFallbackState()
        let nextVideo = resource.videos[currentVideoIndex]
        if case .whep = currentVideo.source,
           case .hls = nextVideo.source {
            isFallbackPlayback = announceTransportSwitch
            if announceTransportSwitch {
                controlView.setTransportState(
                    .switchingToHLS(hlsTransport(for: nextVideo))
                )
            }
        } else {
            isFallbackPlayback = false
        }
        isItemLoaded = false
        prepareVideoForSmoothStart()
        SYPlayerConfig.shared.log(
            "Player fallback to video index \(currentVideoIndex)",
            level: .warning
        )
        startCurrentVideo(autoPlay: true)
        return true
    }

    private func fallbackFromLowLatencyHLSIfPossible() -> Bool {
        guard !didFallbackFromLowLatencyHLS,
              let video = currentAutomaticLowLatencyVideo
        else {
            return false
        }

        cancelLowLatencyFirstFrameFallback()
        SYStreamTransportPreferenceStore.shared.recordLowLatencyFailure(
            for: video.url,
            cooldown: SYPlayerConfig.shared.lowLatencyHLSFailureCooldown,
            preferenceDuration: SYPlayerConfig.shared.streamTransportPreferenceDuration
        )
        didFallbackFromLowLatencyHLS = true
        resolvedHLSLatencyMode = .standard
        isFallbackPlayback = true
        prepareVideoForSmoothStart()
        controlView.setTransportState(.switchingToHLS(.hls))
        SYPlayerConfig.shared.log(
            "Player LL-HLS failed; retrying the original standard HLS playlist",
            level: .warning
        )

        DispatchQueue.main.async { [weak self] in
            guard let self, currentVideo === video else { return }
            engine.set(
                url: video.url,
                autoPlay: true,
                isLiveHLS: true,
                hlsLatencyMode: .standard
            )
        }
        return true
    }

    private func retryLowLatencyHLSAfterManifestFailureIfPossible(
        reason: String
    ) -> Bool {
        guard !didRetryLowLatencyHLSPlayback,
              !didFallbackFromLowLatencyHLS,
              let video = currentAutomaticLowLatencyVideo
        else {
            return false
        }

        didRetryLowLatencyHLSPlayback = true
        cancelLowLatencyFirstFrameFallback()
        isFallbackPlayback = false
        isItemLoaded = true
        prepareVideoForSmoothStart()
        controlView.setTransportState(.connecting(.lowLatencyHLS))
        engine.stop()

        SYPlayerConfig.shared.log(
            "Player refreshing LL-HLS manifest before one retry "
                + "(reason: \(reason))",
            level: .warning
        )

        SYHLSManifestInspector.shared
            .refresh(url: video.url, options: video.options)
            .asObservable()
            .subscribe(with: self) { owner, resolution in
                guard owner.currentVideo === video else { return }
                guard case .lowLatency = resolution.mode else {
                    SYPlayerConfig.shared.log(
                        "Player LL-HLS manifest remained invalid after retries",
                        level: .warning
                    )
                    _ = owner.fallbackFromLowLatencyHLSIfPossible()
                    return
                }

                owner.resolvedHLSLatencyMode = .lowLatency
                SYStreamTransportPreferenceStore.shared.recordLowLatencyAvailability(
                    for: video.url,
                    duration: SYPlayerConfig.shared.streamTransportPreferenceDuration
                )
                owner.engine.set(
                    url: resolution.playbackURL,
                    autoPlay: true,
                    isLiveHLS: true,
                    hlsLatencyMode: .lowLatency
                )
                owner.scheduleLowLatencyFirstFrameFallbackIfNeeded(
                    for: video,
                    autoPlay: true
                )
            }
            .disposed(by: playbackDisposeBag)
        return true
    }

    private func scheduleLowLatencyFirstFrameFallbackIfNeeded(
        for video: SYPlayerResourceVideo,
        autoPlay: Bool
    ) {
        cancelLowLatencyFirstFrameFallback()
        guard autoPlay, currentAutomaticLowLatencyVideo === video else {
            return
        }

        let timeout = SYPlayerConfig.shared.lowLatencyHLSFirstFrameTimeout
        guard timeout.isFinite, timeout > 0 else { return }

        lowLatencyFirstFrameFallbackDisposable.disposable = Observable<Int>
            .timer(
                .milliseconds(Int(timeout * 1_000)),
                scheduler: MainScheduler.instance
            )
            .subscribe(with: self) { owner, _ in
                guard owner.currentVideo === video,
                      !owner.didAnimateVideoFadeIn
                else {
                    return
                }

                SYPlayerConfig.shared.log(
                    "Player LL-HLS first frame timed out after \(timeout)s",
                    level: .warning
                )
                if owner.retryLowLatencyHLSForLastManifestErrorIfPossible() {
                    return
                }
                _ = owner.fallbackFromLowLatencyHLSIfPossible()
            }
    }

    private func cancelLowLatencyFirstFrameFallback() {
        lowLatencyFirstFrameFallbackDisposable.disposable = Disposables.create()
    }

    private func retryLowLatencyHLSForLastManifestErrorIfPossible() -> Bool {
        guard engine.lastErrorStatusCode == Self.lowLatencyManifestErrorStatusCode else {
            return false
        }
        return retryLowLatencyHLSAfterManifestFailureIfPossible(
            reason: engine.lastErrorComment
                ?? "CoreMedia error \(Self.lowLatencyManifestErrorStatusCode)"
        )
    }

    private func resetHLSFallbackState() {
        didFallbackFromLowLatencyHLS = false
        didRetryLowLatencyHLSPlayback = false
        resolvedHLSLatencyMode = nil
    }

    private func hlsTransport(
        for video: SYPlayerResourceVideo?,
        resolvedMode: SYPlayerHLSLatencyMode? = nil
    ) -> SYPlayerTransport {
        (resolvedMode ?? video?.hlsLatencyMode) == .lowLatency ? .lowLatencyHLS : .hls
    }

    private func inspectHLSManifestIfNeeded(for video: SYPlayerResourceVideo) {
        guard case .automatic = video.hlsLatencyMode else { return }
        SYHLSManifestInspector.shared
            .inspect(url: video.url, options: video.options)
            .asObservable()
            .subscribe(with: self) { _, resolution in
                guard case .lowLatency = resolution.mode else { return }
                SYStreamTransportPreferenceStore.shared.recordLowLatencyAvailability(
                    for: video.url,
                    duration: SYPlayerConfig.shared.streamTransportPreferenceDuration
                )
            }
            .disposed(by: playbackDisposeBag)
    }

    private func hlsResolution(
        for video: SYPlayerResourceVideo
    ) -> SYHLSManifestResolution {
        guard resource?.videoType == .online else {
            return SYHLSManifestResolution(
                playbackURL: video.url,
                mode: .standard
            )
        }

        guard case .automatic = video.hlsLatencyMode else {
            return SYHLSManifestResolution(
                playbackURL: video.url,
                mode: video.hlsLatencyMode
            )
        }

        let preferredMode = SYStreamTransportPreferenceStore.shared.preferredHLSMode(
            for: video.url
        )
        if case .standard? = preferredMode {
            SYPlayerConfig.shared.log(
                "Player use remembered standard HLS transport",
                level: .info
            )
            return SYHLSManifestResolution(
                playbackURL: video.url,
                mode: .standard
            )
        }

        if let resolution = SYHLSManifestInspector.shared.cachedResolution(
            url: video.url,
            options: video.options
        ) {
            let transport = hlsTransport(for: video, resolvedMode: resolution.mode)
            SYPlayerConfig.shared.log(
                "Player resolved cached HLS transport: \(transport.title), "
                    + "playlist: \(resolution.playbackURL.lastPathComponent)",
                level: .info
            )
            return resolution
        }

        if case .lowLatency? = preferredMode {
            let lowLatencyURL = SYHLSManifestInspector.shared.lowLatencyURL(
                for: video.url
            )
            SYPlayerConfig.shared.log(
                "Player use remembered LL-HLS transport",
                level: .info
            )
            return SYHLSManifestResolution(
                playbackURL: lowLatencyURL,
                mode: .lowLatency
            )
        }

        SYPlayerConfig.shared.log(
            "Player HLS inspection is still running; starting standard HLS without delay",
            level: .info
        )
        return SYHLSManifestResolution(
            playbackURL: video.url,
            mode: .standard
        )
    }

    private func recordSuccessfulHLSPlayback() {
        guard let video = currentVideo,
              case .hls = video.source
        else {
            return
        }

        let mode: SYPreferredHLSMode = resolvedHLSLatencyMode == .lowLatency
            ? .lowLatency
            : .standard
        SYStreamTransportPreferenceStore.shared.recordSuccessfulPlayback(
            mode,
            for: video.url,
            duration: SYPlayerConfig.shared.streamTransportPreferenceDuration
        )
    }
}

// MARK: - SYPlayerEngineDelegate
extension SYPlayer: SYPlayerEngineDelegate {
    /// Receives playback state updates from the engine.
    func playerEngine(
        _ engine: SYPlayerEngine,
        stateDidChange state: SYPlayerState
    ) {
        if case .error = state {
            if retryLowLatencyHLSForLastManifestErrorIfPossible() {
                return
            }
            if fallbackFromLowLatencyHLSIfPossible() { return }
            if fallbackToNextVideoIfPossible() { return }
        }

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
            if resource?.videoType == .online {
                controlView.setTransportState(.failed(currentHLSTransport))
            }
            isFallbackPlayback = false
            isPlayToTheEnd = false
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

    func playerEngine(
        _ engine: SYPlayerEngine,
        didReceiveErrorStatusCode statusCode: Int,
        comment: String?
    ) {
        guard statusCode == Self.lowLatencyManifestErrorStatusCode else { return }
        _ = retryLowLatencyHLSAfterManifestFailureIfPossible(
            reason: comment ?? "CoreMedia error \(statusCode)"
        )
    }
}

// MARK: - SYWebRTCPlayerEngineDelegate
extension SYPlayer: SYWebRTCPlayerEngineDelegate {
    func webRTCPlayerEngine(
        _ engine: SYWebRTCPlayerEngine,
        stateDidChange state: SYPlayerState
    ) {
        if case .error(let message) = state {
            recordWHEPFailure(message: message)
            if fallbackToNextVideoIfPossible() { return }
        }

        controlView.playerStateDidChange(state: state)
        delegate?.syPlayer(player: self, playerStateDidChange: state)

        switch state {
        case .playing:
            clearWHEPCooldownAfterSuccessfulPlayback()
            controlView.setTransportState(
                .playing(.webRTC, announceConnection: false)
            )
            controlView.hideImageView()
            controlView.playbackDidBecomeVisible()
            revealWebRTCVideoIfNeeded()
            isPlayToTheEnd = false
        case .ready:
            isPlayToTheEnd = false
        case .ended:
            isPlayToTheEnd = true
        case .error, .idle:
            if case .error = state {
                controlView.setTransportState(.failed(.webRTC))
            }
            isPlayToTheEnd = false
        default:
            break
        }
    }

    private func recordWHEPFailure(message: String) {
        guard let currentVideo,
              case .whep(let endpointURL, _) = currentVideo.source
        else {
            return
        }

        let duration = SYPlayerConfig.shared.whepCooldownDuration
        SYWHEPCooldownStore.shared.recordFailure(
            endpointURL: endpointURL,
            reason: message,
            duration: duration
        )
        guard duration > 0 else { return }

        SYPlayerConfig.shared.log(
            "Player WHEP cooldown started for \(Int(ceil(duration)))s (reason: \(message))",
            level: .warning
        )
    }

    private func clearWHEPCooldownAfterSuccessfulPlayback() {
        guard let currentVideo,
              case .whep(let endpointURL, _) = currentVideo.source,
              SYWHEPCooldownStore.shared.clear(endpointURL: endpointURL)
        else {
            return
        }

        SYPlayerConfig.shared.log(
            "Player WHEP cooldown cleared after successful playback",
            level: .debug
        )
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
