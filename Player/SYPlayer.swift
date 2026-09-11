//
//  SYPlayer.swift
//  SmartYard
//
//  Created by Александр Попов on 08.08.2024.
//  Copyright © 2024 Sesameware. All rights reserved.
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

private enum SYTransportCapability: String {
    case unknown
    case supported
    case unavailable
}

private final class SYTransportRaceCandidate {
    var capability: SYTransportCapability
    var hasFirstFrame = false
    var failureMessage: String?

    init(capability: SYTransportCapability) {
        self.capability = capability
    }

    var isTerminal: Bool {
        capability == .unavailable || failureMessage != nil
    }
}

private final class SYTransportRaceState {
    let id = UUID()
    let startedAt = Date()
    let hlsIndex: Int
    let hlsVideo: SYPlayerResourceVideo
    let webRTCConfiguration: (endpointURL: URL, iceServers: [String])?
    let retryAttempt: Int
    let webRTC: SYTransportRaceCandidate
    let lowLatencyHLS: SYTransportRaceCandidate
    let hls = SYTransportRaceCandidate(capability: .unknown)

    var visibleTransport: SYPlayerTransport?
    var hasReachedPresentationDeadline = false
    var presentationWorkItem: DispatchWorkItem?
    var decisionWorkItem: DispatchWorkItem?
    var lowLatencyFirstFrameWorkItem: DispatchWorkItem?

    init(
        hlsIndex: Int,
        hlsVideo: SYPlayerResourceVideo,
        webRTCConfiguration: (endpointURL: URL, iceServers: [String])?,
        includesLowLatencyHLS: Bool,
        retryAttempt: Int
    ) {
        self.hlsIndex = hlsIndex
        self.hlsVideo = hlsVideo
        self.webRTCConfiguration = webRTCConfiguration
        self.retryAttempt = retryAttempt
        webRTC = SYTransportRaceCandidate(
            capability: webRTCConfiguration == nil ? .unavailable : .unknown
        )
        lowLatencyHLS = SYTransportRaceCandidate(
            capability: includesLowLatencyHLS ? .unknown : .unavailable
        )
    }

    func candidate(for transport: SYPlayerTransport) -> SYTransportRaceCandidate {
        switch transport {
        case .webRTC:
            return webRTC
        case .lowLatencyHLS:
            return lowLatencyHLS
        case .hls:
            return hls
        }
    }
}

final class SYPlayer: UIView {

    private static let lowLatencyManifestErrorStatusCode = -15415
    private static let transportRaceSchedulingLeeway: TimeInterval = 0.5

    // MARK: - Public
    weak var delegate: SYPlayerDelegate?

    var playOrientationChanged: ((Bool) -> Void)?
    var backBlock: (() -> Void)?
    var selectFavoriteBlock: (() -> Void)?

    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            playerLayer.videoGravity = videoGravity
            lowLatencyPlayerLayer.videoGravity = videoGravity
            webRTCEngine.rendererView.videoContentMode = rtcVideoContentMode
        }
    }

    var aspectRatio: SYPlayerAspectRatio {
        get { playerLayer.aspectRatio }
        set {
            playerLayer.aspectRatio = newValue
            lowLatencyPlayerLayer.aspectRatio = newValue
        }
    }

    /// Текущее состояние проигрывания
    var isPlaying: Bool {
        switch selectedTransport ?? visibleTransport {
        case .webRTC:
            return webRTCEngine.isPlaying
        case .hls, .lowLatencyHLS:
            return selectedHLSEngine?.isPlaying ?? visibleHLSEngine?.isPlaying ?? false
        case nil:
            return false
        }
    }

    // MARK: - Private UI
    private let playerLayer = SYPlayerLayerView()
    private let lowLatencyPlayerLayer = SYPlayerLayerView()
    private let controlView = SYPlayerControlView()
    private let engine = SYPlayerEngine()
    private let lowLatencyEngine = SYPlayerEngine()
    private let webRTCEngine = SYWebRTCPlayerEngine()

    // MARK: - Private state
    private var resource: SYPlayerResource?
    private var currentVideoIndex: Int = 0

    private var isPauseByUser: Bool = false
    private var isPlayToTheEnd: Bool = false
    private var isItemLoaded: Bool = false
    private var isFallbackPlayback = false
    private var didFallbackFromLowLatencyHLS = false
    private var didRetryLowLatencyHLSPlayback = false
    private var resolvedHLSLatencyMode: SYPlayerHLSLatencyMode?
    private var playbackDisposeBag = DisposeBag()
    private let lowLatencyFirstFrameFallbackDisposable = SerialDisposable()
    private var transportRace: SYTransportRaceState?
    private var selectedTransport: SYPlayerTransport?
    private var selectedHLSEngine: SYPlayerEngine?
    private var selectedHLSLayer: SYPlayerLayerView?
    private var visibleTransport: SYPlayerTransport?
    private var visibleVideoView: UIView?
    private var visibleHLSEngineReference: SYPlayerEngine?
    private var didNotifyVisiblePlayback = false
    private var requestedMuted = true

    private var visibleHLSEngine: SYPlayerEngine? {
        visibleHLSEngineReference
    }

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
        lowLatencyPlayerLayer.videoGravity = videoGravity
        lowLatencyPlayerLayer.attach(player: lowLatencyEngine.player)
        lowLatencyPlayerLayer.alpha = 0
        addSubview(lowLatencyPlayerLayer)
        addSubview(webRTCEngine.rendererView)

        playerLayer.snp.makeConstraints {
            $0.directionalEdges.equalToSuperview()
        }

        lowLatencyPlayerLayer.snp.makeConstraints {
            $0.directionalEdges.equalToSuperview()
        }

        webRTCEngine.rendererView.alpha = 0
        webRTCEngine.rendererView.videoContentMode = rtcVideoContentMode
        webRTCEngine.rendererView.snp.makeConstraints {
            $0.directionalEdges.equalToSuperview()
        }

        playerLayer.onReadyForDisplay = { [weak self] isReady in
            guard let self, isReady else { return }
            self.hlsLayerDidBecomeReady(engine: self.engine, layer: self.playerLayer)
        }
        lowLatencyPlayerLayer.onReadyForDisplay = { [weak self] isReady in
            guard let self, isReady else { return }
            self.hlsLayerDidBecomeReady(
                engine: self.lowLatencyEngine,
                layer: self.lowLatencyPlayerLayer
            )
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
        lowLatencyEngine.delegate = self
        webRTCEngine.delegate = self
    }

    // MARK: - Public API
    /// Loads a resource and prepares playback.
    func setVideo(resource: SYPlayerResource, videoIndex: Int = 0) {
        SYPlayerConfig.shared.log(
            "Player setVideo name: \(resource.name), index: \(videoIndex), videos: \(resource.videos.count), type: \(resource.videoType), hasSound: \(resource.hasSound)",
            level: .info
        )
        resetTransportSelection()
        engine.stop()
        lowLatencyEngine.stop()
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

        if let selectedHLSEngine, case .ended = selectedHLSEngine.state {
            SYPlayerConfig.shared.log("Player restart from end", level: .debug)
            selectedHLSEngine.seek(to: 0) { [weak selectedHLSEngine] in
                selectedHLSEngine?.play()
            }
            isPlayToTheEnd = false
            isPauseByUser = false
            return
        }

        if !isItemLoaded {
            startCurrentVideo(autoPlay: true)
        } else if let race = transportRace {
            SYPlayerConfig.shared.log("Player resume transport race", level: .debug)
            if !race.webRTC.isTerminal {
                webRTCEngine.play()
            }
            if !race.lowLatencyHLS.isTerminal {
                lowLatencyEngine.play()
            }
            if !race.hls.isTerminal {
                engine.play()
            }
        } else {
            switch selectedTransport {
            case .webRTC:
                SYPlayerConfig.shared.log("Player play existing WHEP item", level: .debug)
                webRTCEngine.play()
            case .hls, .lowLatencyHLS:
                SYPlayerConfig.shared.log("Player play existing HLS item", level: .debug)
                selectedHLSEngine?.play()
            case nil:
                startCurrentVideo(autoPlay: true)
            }
            if selectedTransport != .webRTC, let currentVideo {
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

        if let race = transportRace {
            if let visibleTransport = race.visibleTransport {
                finalizeTransportRace(
                    with: visibleTransport,
                    reason: "playback paused after a visible first frame"
                )
            } else {
                cancelTransportRace()
                isItemLoaded = false
            }
        }

        switch selectedTransport {
        case .webRTC:
            webRTCEngine.pause()
        case .hls, .lowLatencyHLS:
            selectedHLSEngine?.pause()
        case nil:
            break
        }
        if !allow {
            engine.player.isMuted = true
            lowLatencyEngine.player.isMuted = true
            webRTCEngine.setMuted(true)
        }
        isPauseByUser = !allow
    }

    /// Seeks to a specific time in seconds.
    func seek(_ to: TimeInterval, completion: (() -> Void)? = nil) {
        guard to.isFinite, to >= 0 else {
            SYPlayerConfig.shared.log("Player seek ignored (invalid time: \(to))", level: .warning)
            return
        }
        SYPlayerConfig.shared.log("Player seek to \(to)s", level: .debug)
        selectedHLSEngine?.seek(to: to, completion: completion)
    }

    /// Mutes or unmutes the underlying player.
    func setMuted(_ muted: Bool) {
        SYPlayerConfig.shared.log("Player setMuted: \(muted)", level: .debug)
        requestedMuted = muted
        applyRequestedAudioState()
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

    /// Hides the built-in button when the host supplies a persistent fullscreen control.
    func setFullscreenButtonHidden(_ isHidden: Bool) {
        controlView.setFullscreenButtonHidden(isHidden)
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
        resetTransportSelection()
        lowLatencyFirstFrameFallbackDisposable.dispose()
        playbackDisposeBag = DisposeBag()
        setControlsContainer(nil)
        engine.cleanup()
        lowLatencyEngine.cleanup()
        webRTCEngine.cleanup()
        playerLayer.detachPlayer()
        lowLatencyPlayerLayer.detachPlayer()
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
            if shouldRaceLowLatencyHLS(for: video, autoPlay: autoPlay) {
                startTransportRace(
                    webRTC: nil,
                    hlsIndex: currentVideoIndex,
                    hlsVideo: video
                )
            } else {
                startHLSVideo(autoPlay: autoPlay)
            }
        case .whep(let endpointURL, let iceServers):
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

            if autoPlay,
               resource?.videoType == .online,
               let fallbackIndex = firstHLSVideoIndex(after: currentVideoIndex),
               let fallbackVideo = resource?.video(at: fallbackIndex) {
                startTransportRace(
                    webRTC: (endpointURL, iceServers),
                    hlsIndex: fallbackIndex,
                    hlsVideo: fallbackVideo
                )
            } else {
                startWHEPVideo(
                    endpointURL: endpointURL,
                    iceServers: iceServers,
                    autoPlay: autoPlay
                )
            }
        }
    }

    private func startHLSVideo(autoPlay: Bool) {
        guard let video = currentVideo else { return }

        resetTransportSelection()
        lowLatencyEngine.stop()
        webRTCEngine.stop()
        configureHLSAudioSession()
        playerLayer.attach(player: engine.player)

        let resolution = hlsResolution(for: video)
        resolvedHLSLatencyMode = resolution.mode
        selectedTransport = hlsTransport(for: video, resolvedMode: resolution.mode)
        selectedHLSEngine = engine
        selectedHLSLayer = playerLayer

        if resource?.videoType == .online {
            controlView.setTransportState(
                isFallbackPlayback
                    ? .switching(from: .webRTC, to: currentHLSTransport)
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
        applyRequestedAudioState()
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
        resetTransportSelection()
        cancelLowLatencyFirstFrameFallback()
        isFallbackPlayback = false
        selectedTransport = .webRTC
        controlView.setTransportState(.connecting(.webRTC))
        engine.stop()
        lowLatencyEngine.stop()
        applyRequestedAudioState()
        webRTCEngine.set(endpointURL: endpointURL, iceServers: iceServers, autoPlay: autoPlay)
    }

    private func firstHLSVideoIndex(after index: Int) -> Int? {
        resource?.videos.indices.first { candidateIndex in
            guard candidateIndex > index,
                  let video = resource?.video(at: candidateIndex)
            else {
                return false
            }
            if case .hls = video.source { return true }
            return false
        }
    }

    private func shouldRaceLowLatencyHLS(
        for video: SYPlayerResourceVideo,
        autoPlay: Bool
    ) -> Bool {
        guard autoPlay,
              resource?.videoType == .online,
              video.hlsLatencyMode == .automatic
        else {
            return false
        }

        return !isLowLatencyHLSKnownUnavailable(for: video)
    }

    private func isLowLatencyHLSKnownUnavailable(
        for video: SYPlayerResourceVideo
    ) -> Bool {
        if case .standard? = SYStreamTransportPreferenceStore.shared.preferredHLSMode(
            for: video.url
        ) {
            return true
        }

        if let cached = SYHLSManifestInspector.shared.cachedResolution(
            url: video.url,
            options: video.options
        ), case .standard = cached.mode {
            return true
        }
        return false
    }

    private func startTransportRace(
        webRTC: (endpointURL: URL, iceServers: [String])?,
        hlsIndex: Int,
        hlsVideo: SYPlayerResourceVideo,
        retryAttempt: Int = 0
    ) {
        resetTransportSelection()
        engine.stop()
        lowLatencyEngine.stop()
        webRTCEngine.stop()
        cancelLowLatencyFirstFrameFallback()
        configureHLSAudioSession()

        let includesLowLatencyHLS = hlsVideo.hlsLatencyMode == .automatic
            && !isLowLatencyHLSKnownUnavailable(for: hlsVideo)
        let race = SYTransportRaceState(
            hlsIndex: hlsIndex,
            hlsVideo: hlsVideo,
            webRTCConfiguration: webRTC,
            includesLowLatencyHLS: includesLowLatencyHLS,
            retryAttempt: retryAttempt
        )
        transportRace = race
        isFallbackPlayback = currentVideoIndex != hlsIndex

        let preferredConnectingTransport: SYPlayerTransport = webRTC != nil
            ? .webRTC
            : (includesLowLatencyHLS ? .lowLatencyHLS : .hls)
        controlView.setTransportState(.connecting(preferredConnectingTransport))

        playerLayer.attach(player: engine.player)
        engine.player.isMuted = true
        engine.set(
            url: hlsVideo.url,
            autoPlay: true,
            isLiveHLS: true,
            hlsLatencyMode: .standard
        )

        if includesLowLatencyHLS {
            let lowLatencyURL = SYHLSManifestInspector.shared.lowLatencyURL(
                for: hlsVideo.url
            )
            lowLatencyPlayerLayer.attach(player: lowLatencyEngine.player)
            lowLatencyEngine.player.isMuted = true
            lowLatencyEngine.set(
                url: lowLatencyURL,
                autoPlay: true,
                isLiveHLS: true,
                hlsLatencyMode: .lowLatency
            )
            scheduleRaceLowLatencyFirstFrameTimeout(raceID: race.id)
        }

        if let webRTC {
            webRTCEngine.setMuted(true)
            webRTCEngine.set(
                endpointURL: webRTC.endpointURL,
                iceServers: webRTC.iceServers,
                autoPlay: true,
                enforceFirstFrameTimeout: false
            )
        }

        scheduleTransportRaceDecisionTimeout(raceID: race.id)
        if includesLowLatencyHLS {
            inspectHLSManifestIfNeeded(for: hlsVideo)
        }
        SYPlayerConfig.shared.log(
            "Player transport race started (id: \(race.id), WebRTC: "
                + "\(webRTC != nil), LL-HLS: \(includesLowLatencyHLS), HLS: true, "
                + "attempt: \(retryAttempt + 1))",
            level: .info
        )
    }

    private func scheduleRaceLowLatencyFirstFrameTimeout(raceID: UUID) {
        let timeout = SYPlayerConfig.shared.lowLatencyHLSFirstFrameTimeout
        guard timeout.isFinite, timeout > 0 else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let race = self.transportRace,
                  race.id == raceID,
                  !race.lowLatencyHLS.hasFirstFrame,
                  !race.lowLatencyHLS.isTerminal
            else {
                return
            }

            self.markRaceCandidateUnavailable(
                .lowLatencyHLS,
                reason: "LL-HLS first frame timeout",
                raceID: raceID
            )
        }
        transportRace?.lowLatencyFirstFrameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func scheduleTransportRaceDecisionTimeout(raceID: UUID) {
        guard let race = transportRace, race.id == raceID else { return }

        let config = SYPlayerConfig.shared
        let presentationTimeout = race.retryAttempt > 0
            ? config.transportRaceRetryDecisionTimeout
            : config.transportRaceDecisionTimeout
        var timeout = presentationTimeout
        if race.retryAttempt == 0, !race.webRTC.isTerminal {
            let webRTCBudget = max(0, config.whepIceGatheringTimeout)
                + max(
                    max(0, config.whepRequestTimeout),
                    max(0, config.whepHandshakeTimeout)
                )
                + max(0, config.whepFirstFrameTimeout)
                + Self.transportRaceSchedulingLeeway
            timeout = max(timeout, webRTCBudget)
        }
        guard timeout.isFinite, timeout > 0 else { return }

        if presentationTimeout.isFinite,
           presentationTimeout > 0,
           presentationTimeout < timeout {
            scheduleTransportRacePresentationTimeout(
                raceID: raceID,
                timeout: presentationTimeout
            )
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let race = self.transportRace,
                  race.id == raceID
            else {
                return
            }
            self.finalizeTransportRaceAtDeadline(race)
        }
        transportRace?.decisionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
        let formattedTimeout = String(format: "%.1f", timeout)
        SYPlayerConfig.shared.log(
            "Player transport race safety timeout scheduled: "
                + "\(formattedTimeout)s (attempt: \(race.retryAttempt + 1))",
            level: .debug
        )
    }

    private func scheduleTransportRacePresentationTimeout(
        raceID: UUID,
        timeout: TimeInterval
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let race = self.transportRace,
                  race.id == raceID
            else {
                return
            }

            race.presentationWorkItem = nil
            race.hasReachedPresentationDeadline = true
            SYPlayerConfig.shared.log(
                "Player low-latency presentation deadline reached at "
                    + "+\(self.raceElapsed(race))s",
                level: .warning
            )
            self.evaluateTransportRace(race)
        }
        transportRace?.presentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
        SYPlayerConfig.shared.log(
            "Player low-latency presentation deadline scheduled: "
                + "\(String(format: "%.1f", timeout))s",
            level: .debug
        )
    }

    private func markRaceCapability(
        _ capability: SYTransportCapability,
        for transport: SYPlayerTransport,
        raceID: UUID
    ) {
        guard let race = transportRace, race.id == raceID else { return }
        let candidate = race.candidate(for: transport)
        guard !candidate.hasFirstFrame,
              candidate.failureMessage == nil,
              candidate.capability == .unknown
        else {
            return
        }

        candidate.capability = capability
        SYPlayerConfig.shared.log(
            "Player transport capability \(transport.title): \(capability.rawValue) "
                + "at +\(raceElapsed(race))s",
            level: capability == .unavailable ? .warning : .debug
        )
    }

    private func markRaceCandidateUnavailable(
        _ transport: SYPlayerTransport,
        reason: String,
        raceID: UUID
    ) {
        guard let race = transportRace, race.id == raceID else { return }
        let candidate = race.candidate(for: transport)
        guard !candidate.hasFirstFrame, !candidate.isTerminal else { return }

        candidate.capability = .unavailable
        candidate.failureMessage = reason
        SYPlayerConfig.shared.log(
            "Player transport \(transport.title) unavailable at "
                + "+\(raceElapsed(race))s (reason: \(reason))",
            level: .warning
        )

        switch transport {
        case .webRTC:
            break
        case .lowLatencyHLS:
            race.lowLatencyFirstFrameWorkItem?.cancel()
            race.lowLatencyFirstFrameWorkItem = nil
            lowLatencyEngine.stop()
            SYStreamTransportPreferenceStore.shared.recordLowLatencyFailure(
                for: race.hlsVideo.url,
                cooldown: SYPlayerConfig.shared.lowLatencyHLSFailureCooldown,
                preferenceDuration: SYPlayerConfig.shared.streamTransportPreferenceDuration
            )
        case .hls:
            engine.stop()
        }
        evaluateTransportRace(race)
    }

    private func markRaceFirstFrame(
        for transport: SYPlayerTransport,
        raceID: UUID
    ) {
        guard let race = transportRace, race.id == raceID else { return }
        let candidate = race.candidate(for: transport)
        guard !candidate.hasFirstFrame, !candidate.isTerminal else { return }

        candidate.capability = .supported
        candidate.hasFirstFrame = true
        if transport == .lowLatencyHLS {
            race.lowLatencyFirstFrameWorkItem?.cancel()
            race.lowLatencyFirstFrameWorkItem = nil
            SYStreamTransportPreferenceStore.shared.recordLowLatencyAvailability(
                for: race.hlsVideo.url,
                duration: SYPlayerConfig.shared.streamTransportPreferenceDuration
            )
        }
        SYPlayerConfig.shared.log(
            "Player transport \(transport.title) first frame at "
                + "+\(raceElapsed(race))s",
            level: .info
        )

        if transport == .webRTC {
            finalizeTransportRace(with: .webRTC, reason: "WebRTC displayed first frame")
            return
        }

        if transport == .lowLatencyHLS, race.webRTC.isTerminal {
            finalizeTransportRace(with: .lowLatencyHLS, reason: "LL-HLS is highest ready transport")
            return
        }

        if transport == .hls,
           race.webRTC.isTerminal,
           race.lowLatencyHLS.isTerminal {
            finalizeTransportRace(with: .hls, reason: "only HLS displayed a frame")
            return
        }

        if race.hasReachedPresentationDeadline {
            finalizeTransportRace(
                with: transport,
                reason: "first frame after low-latency presentation deadline"
            )
            return
        }

        if race.visibleTransport == nil, transport != .hls {
            race.visibleTransport = transport
            showTransportFrame(transport)
        } else if race.visibleTransport == nil, transport == .hls {
            SYPlayerConfig.shared.log(
                "Player keeps the warmed HLS first frame hidden "
                    + "while low-latency transports resolve",
                level: .debug
            )
        }
        evaluateTransportRace(race)
    }

    private func evaluateTransportRace(_ race: SYTransportRaceState) {
        guard transportRace === race else { return }

        if race.webRTC.hasFirstFrame {
            finalizeTransportRace(with: .webRTC, reason: "WebRTC displayed first frame")
            return
        }

        if race.hasReachedPresentationDeadline {
            if race.lowLatencyHLS.hasFirstFrame {
                finalizeTransportRace(
                    with: .lowLatencyHLS,
                    reason: "best ready transport at presentation deadline"
                )
                return
            }
            if race.hls.hasFirstFrame {
                finalizeTransportRace(
                    with: .hls,
                    reason: "warmed fallback at presentation deadline"
                )
                return
            }
        }
        guard race.webRTC.isTerminal else { return }

        if race.lowLatencyHLS.hasFirstFrame {
            finalizeTransportRace(with: .lowLatencyHLS, reason: "WebRTC unavailable; LL-HLS is ready")
            return
        }
        guard race.lowLatencyHLS.isTerminal else { return }

        if race.hls.hasFirstFrame {
            finalizeTransportRace(with: .hls, reason: "higher-priority transports unavailable")
        } else if race.hls.isTerminal {
            retryOrFailTransportRace(race, reason: "all transports became unavailable")
        }
    }

    private func finalizeTransportRaceAtDeadline(_ race: SYTransportRaceState) {
        guard transportRace === race else { return }

        if !race.webRTC.hasFirstFrame, !race.webRTC.isTerminal {
            markRaceCandidateUnavailable(
                .webRTC,
                reason: "WebRTC did not display a frame within its full startup budget",
                raceID: race.id
            )
        }
        guard transportRace === race else { return }

        if !race.lowLatencyHLS.hasFirstFrame, !race.lowLatencyHLS.isTerminal {
            markRaceCandidateUnavailable(
                .lowLatencyHLS,
                reason: "LL-HLS did not display a frame within the transport race budget",
                raceID: race.id
            )
        }
        guard transportRace === race else { return }

        if race.webRTC.hasFirstFrame {
            finalizeTransportRace(with: .webRTC, reason: "race safety deadline")
        } else if race.lowLatencyHLS.hasFirstFrame {
            finalizeTransportRace(with: .lowLatencyHLS, reason: "race safety deadline")
        } else if race.hls.hasFirstFrame {
            finalizeTransportRace(with: .hls, reason: "race safety deadline")
        } else if !race.hls.isTerminal {
            markRaceCandidateUnavailable(
                .hls,
                reason: "HLS did not display a frame within the transport race budget",
                raceID: race.id
            )
        } else {
            retryOrFailTransportRace(race, reason: "transport race safety deadline")
        }
    }

    private func finalizeTransportRace(
        with winner: SYPlayerTransport,
        reason: String
    ) {
        guard let race = transportRace else { return }
        let winnerCandidate = race.candidate(for: winner)
        guard winnerCandidate.hasFirstFrame else { return }

        race.presentationWorkItem?.cancel()
        race.decisionWorkItem?.cancel()
        race.lowLatencyFirstFrameWorkItem?.cancel()
        race.presentationWorkItem = nil
        race.decisionWorkItem = nil
        race.lowLatencyFirstFrameWorkItem = nil

        selectedTransport = winner
        if winner == .hls || winner == .lowLatencyHLS {
            currentVideoIndex = race.hlsIndex
            resolvedHLSLatencyMode = winner == .lowLatencyHLS ? .lowLatency : .standard
            selectedHLSEngine = winner == .lowLatencyHLS ? lowLatencyEngine : engine
            selectedHLSLayer = winner == .lowLatencyHLS
                ? lowLatencyPlayerLayer
                : playerLayer
        } else {
            selectedHLSEngine = nil
            selectedHLSLayer = nil
        }
        transportRace = nil

        SYPlayerConfig.shared.log(
            "Player transport winner: \(winner.title) at +\(raceElapsed(race))s "
                + "(reason: \(reason))",
            level: .info
        )

        showTransportFrame(winner) { [weak self] in
            self?.stopUnselectedTransports(keeping: winner)
        }
        if winner != .webRTC {
            recordSuccessfulHLSPlayback()
        }
        isFallbackPlayback = false
        applyRequestedAudioState()
    }

    private func retryOrFailTransportRace(
        _ race: SYTransportRaceState,
        reason: String
    ) {
        guard transportRace === race else { return }

        let maxRetries = max(0, SYPlayerConfig.shared.transportRaceMaxFullRetries)
        guard race.retryAttempt < maxRetries else {
            failTransportRace(race)
            return
        }

        let webRTC: (endpointURL: URL, iceServers: [String])?
        if let configuration = race.webRTCConfiguration,
           SYWHEPCooldownStore.shared.activeCooldown(
               for: configuration.endpointURL
           ) == nil {
            webRTC = configuration
        } else {
            webRTC = nil
        }

        SYPlayerConfig.shared.log(
            "Player restarting the complete transport race with fresh sessions "
                + "(next attempt: \(race.retryAttempt + 2), reason: \(reason))",
            level: .warning
        )
        SYPlayerAssetWarmupStore.shared.invalidate(url: race.hlsVideo.url)
        SYPlayerAssetWarmupStore.shared.invalidate(
            url: SYHLSManifestInspector.shared.lowLatencyURL(for: race.hlsVideo.url)
        )
        startTransportRace(
            webRTC: webRTC,
            hlsIndex: race.hlsIndex,
            hlsVideo: race.hlsVideo,
            retryAttempt: race.retryAttempt + 1
        )
    }

    private func failTransportRace(_ race: SYTransportRaceState) {
        guard transportRace === race else { return }

        race.presentationWorkItem?.cancel()
        race.decisionWorkItem?.cancel()
        race.lowLatencyFirstFrameWorkItem?.cancel()
        transportRace = nil
        selectedTransport = nil
        selectedHLSEngine = nil
        selectedHLSLayer = nil
        visibleTransport = nil
        visibleVideoView = nil
        visibleHLSEngineReference = nil
        engine.stop()
        lowLatencyEngine.stop()
        webRTCEngine.stop()

        let message = race.hls.failureMessage
            ?? race.lowLatencyHLS.failureMessage
            ?? race.webRTC.failureMessage
            ?? "No transport displayed a video frame"
        controlView.setTransportState(.failed(.hls))
        controlView.playerStateDidChange(state: .error(message))
        delegate?.syPlayer(player: self, playerStateDidChange: .error(message))
        controlView.playStateDidChange(isPlaying: false)
        delegate?.syPlayer(player: self, playerIsPlaying: false)
        SYPlayerConfig.shared.log(
            "Player transport race failed at +\(raceElapsed(race))s: \(message)",
            level: .error
        )
    }

    private func hlsLayerDidBecomeReady(
        engine readyEngine: SYPlayerEngine,
        layer readyLayer: SYPlayerLayerView
    ) {
        guard readyEngine.player.currentItem != nil,
              readyLayer.isReadyForDisplay
        else {
            return
        }

        readyEngine.firstFrameDidDisplay()

        if let race = transportRace {
            let transport: SYPlayerTransport
            if readyEngine === engine, readyLayer === playerLayer {
                transport = .hls
            } else if readyEngine === lowLatencyEngine,
                      readyLayer === lowLatencyPlayerLayer {
                transport = .lowLatencyHLS
            } else {
                return
            }
            markRaceFirstFrame(for: transport, raceID: race.id)
            return
        }

        guard readyEngine === selectedHLSEngine,
              readyLayer === selectedHLSLayer,
              let selectedTransport,
              selectedTransport != .webRTC
        else {
            return
        }
        revealSelectedHLSVideoIfNeeded(transport: selectedTransport)
    }

    private func revealSelectedHLSVideoIfNeeded(transport: SYPlayerTransport) {
        guard transport == selectedTransport,
              let selectedHLSLayer,
              selectedHLSLayer.isReadyForDisplay,
              visibleTransport != transport
        else {
            return
        }

        cancelLowLatencyFirstFrameFallback()
        showTransportFrame(transport) { [weak self] in
            self?.stopUnselectedTransports(keeping: transport)
        }
        recordSuccessfulHLSPlayback()
        isFallbackPlayback = false
    }

    private func showTransportFrame(
        _ transport: SYPlayerTransport,
        completion: (() -> Void)? = nil
    ) {
        let targetView = view(for: transport)
        let previousTransport = visibleTransport
        let previousView = visibleVideoView
        let isTransportSwitch = previousTransport != nil

        if previousTransport == transport {
            backgroundColor = SYPlayerConfig.shared.colors.playerBackgroundColor
            controlView.setTransportState(
                .playing(transport, announceConnection: false)
            )
            applyRequestedAudioState()
            completion?()
            return
        }

        visibleTransport = transport
        visibleVideoView = targetView
        visibleHLSEngineReference = hlsEngine(for: transport)
        transportRace?.visibleTransport = transport
        targetView.layer.removeAllAnimations()
        previousView?.layer.removeAllAnimations()
        targetView.alpha = 0

        if let previousTransport {
            controlView.setTransportState(
                .switching(from: previousTransport, to: transport)
            )
        } else {
            controlView.setTransportState(
                .playing(transport, announceConnection: false)
            )
        }
        controlView.hideImageView()
        if !didNotifyVisiblePlayback {
            didNotifyVisiblePlayback = true
            controlView.playbackDidBecomeVisible()
            controlView.playerStateDidChange(state: .playing)
            delegate?.syPlayer(player: self, playerStateDidChange: .playing)
            controlView.playStateDidChange(isPlaying: true)
            delegate?.syPlayer(player: self, playerIsPlaying: true)
        }
        applyRequestedAudioState()

        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) {
            targetView.alpha = 1
            previousView?.alpha = 0
        } completion: { [weak self] _ in
            guard let self, visibleTransport == transport else { return }
            backgroundColor = SYPlayerConfig.shared.colors.playerBackgroundColor
            if isTransportSwitch {
                controlView.setTransportState(
                    .playing(transport, announceConnection: false)
                )
            }
            completion?()
        }
    }

    private func view(for transport: SYPlayerTransport) -> UIView {
        switch transport {
        case .webRTC:
            return webRTCEngine.rendererView
        case .lowLatencyHLS:
            return transportRace == nil
                ? (selectedHLSLayer ?? lowLatencyPlayerLayer)
                : lowLatencyPlayerLayer
        case .hls:
            return playerLayer
        }
    }

    private func hlsEngine(for transport: SYPlayerTransport) -> SYPlayerEngine? {
        switch transport {
        case .webRTC:
            return nil
        case .hls:
            return transportRace == nil ? (selectedHLSEngine ?? engine) : engine
        case .lowLatencyHLS:
            return transportRace == nil ? (selectedHLSEngine ?? lowLatencyEngine) : lowLatencyEngine
        }
    }

    private func stopUnselectedTransports(keeping transport: SYPlayerTransport) {
        switch transport {
        case .webRTC:
            engine.stop()
            lowLatencyEngine.stop()
            playerLayer.alpha = 0
            lowLatencyPlayerLayer.alpha = 0
        case .hls, .lowLatencyHLS:
            webRTCEngine.stop()
            webRTCEngine.rendererView.alpha = 0
            if selectedHLSEngine !== engine {
                engine.stop()
                playerLayer.alpha = 0
            }
            if selectedHLSEngine !== lowLatencyEngine {
                lowLatencyEngine.stop()
                lowLatencyPlayerLayer.alpha = 0
            }
        }
    }

    private func applyRequestedAudioState() {
        let audibleTransport = selectedTransport ?? visibleTransport
        let audibleHLSEngine: SYPlayerEngine? = {
            guard audibleTransport == .hls || audibleTransport == .lowLatencyHLS else {
                return nil
            }
            return selectedTransport == nil ? visibleHLSEngine : selectedHLSEngine
        }()

        engine.player.isMuted = requestedMuted || audibleHLSEngine !== engine
        lowLatencyEngine.player.isMuted = requestedMuted
            || audibleHLSEngine !== lowLatencyEngine
        webRTCEngine.setMuted(requestedMuted || audibleTransport != .webRTC)
    }

    private func prepareVideoForSmoothStart() {
        visibleTransport = nil
        visibleVideoView = nil
        visibleHLSEngineReference = nil
        didNotifyVisiblePlayback = false
        backgroundColor = resource?.previewImage == nil
            ? SYPlayerConfig.shared.colors.playerBackgroundColor
            : .clear
        [playerLayer, lowLatencyPlayerLayer, webRTCEngine.rendererView].forEach { view in
            view.layer.removeAllAnimations()
            view.alpha = 0
        }
    }

    private func resetTransportSelection() {
        transportRace?.presentationWorkItem?.cancel()
        transportRace?.decisionWorkItem?.cancel()
        transportRace?.lowLatencyFirstFrameWorkItem?.cancel()
        transportRace = nil
        selectedTransport = nil
        selectedHLSEngine = nil
        selectedHLSLayer = nil
        prepareVideoForSmoothStart()
    }

    private func cancelTransportRace() {
        guard transportRace != nil else { return }
        resetTransportSelection()
        engine.stop()
        lowLatencyEngine.stop()
        webRTCEngine.stop()
        applyRequestedAudioState()
    }

    private func raceElapsed(_ race: SYTransportRaceState) -> String {
        String(format: "%.3f", Date().timeIntervalSince(race.startedAt))
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
            let shouldAnnounceTransition = announceTransportSwitch
                && visibleTransport == .webRTC
            isFallbackPlayback = shouldAnnounceTransition
            if shouldAnnounceTransition {
                controlView.setTransportState(
                    .switching(
                        from: .webRTC,
                        to: hlsTransport(for: nextVideo)
                    )
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
        let failedLowLatencyEngine = selectedHLSEngine
        selectedTransport = .hls
        selectedHLSEngine = engine
        selectedHLSLayer = playerLayer
        playerLayer.attach(player: engine.player)
        if visibleVideoView !== playerLayer {
            playerLayer.alpha = 0
        }
        let transportState: SYPlayerTransportState = visibleTransport == .lowLatencyHLS
            ? .switching(from: .lowLatencyHLS, to: .hls)
            : .connecting(.hls)
        controlView.setTransportState(transportState)
        SYPlayerConfig.shared.log(
            "Player LL-HLS failed; retrying the original standard HLS playlist",
            level: .warning
        )

        DispatchQueue.main.async { [weak self] in
            guard let self, currentVideo === video else { return }
            if failedLowLatencyEngine === self.engine {
                self.engine.stop()
            }
            engine.set(
                url: video.url,
                autoPlay: true,
                isLiveHLS: true,
                hlsLatencyMode: .standard
            )
            self.applyRequestedAudioState()
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
        selectedHLSEngine?.stop()

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
                guard let selectedHLSEngine = owner.selectedHLSEngine else { return }
                selectedHLSEngine.set(
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
                      owner.visibleTransport != .lowLatencyHLS
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
        guard let selectedHLSEngine,
              selectedHLSEngine.lastErrorStatusCode == Self.lowLatencyManifestErrorStatusCode
        else {
            return false
        }
        return retryLowLatencyHLSAfterManifestFailureIfPossible(
            reason: selectedHLSEngine.lastErrorComment
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
        guard !isLowLatencyHLSKnownUnavailable(for: video) else {
            SYPlayerConfig.shared.log(
                "Player skip LL-HLS manifest inspection during the unavailability cooldown",
                level: .debug
            )
            return
        }
        SYHLSManifestInspector.shared
            .inspect(url: video.url, options: video.options)
            .asObservable()
            .subscribe(with: self) { owner, resolution in
                guard let race = owner.transportRace,
                      race.hlsVideo === video
                else {
                    if case .lowLatency = resolution.mode {
                        SYStreamTransportPreferenceStore.shared.recordLowLatencyAvailability(
                            for: video.url,
                            duration: SYPlayerConfig.shared.streamTransportPreferenceDuration
                        )
                    }
                    return
                }

                switch resolution.mode {
                case .lowLatency:
                    owner.markRaceCapability(
                        .supported,
                        for: .lowLatencyHLS,
                        raceID: race.id
                    )
                    SYStreamTransportPreferenceStore.shared.recordLowLatencyAvailability(
                        for: video.url,
                        duration: SYPlayerConfig.shared.streamTransportPreferenceDuration
                    )
                case .standard, .automatic:
                    owner.markRaceCandidateUnavailable(
                        .lowLatencyHLS,
                        reason: "LL-HLS manifest is unavailable",
                        raceID: race.id
                    )
                }
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
        _ sourceEngine: SYPlayerEngine,
        stateDidChange state: SYPlayerState
    ) {
        if let race = transportRace {
            let transport: SYPlayerTransport
            if sourceEngine === engine {
                transport = .hls
            } else if sourceEngine === lowLatencyEngine {
                transport = .lowLatencyHLS
            } else {
                return
            }

            switch state {
            case .ready:
                markRaceCapability(
                    .supported,
                    for: transport,
                    raceID: race.id
                )
            case .error(let message):
                markRaceCandidateUnavailable(
                    transport,
                    reason: message,
                    raceID: race.id
                )
            default:
                break
            }
            return
        }

        guard sourceEngine === selectedHLSEngine else { return }

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
            if let selectedTransport,
               let selectedHLSLayer,
               selectedHLSLayer.isReadyForDisplay {
                revealSelectedHLSVideoIfNeeded(transport: selectedTransport)
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
        _ sourceEngine: SYPlayerEngine,
        loadedTimeDidChange loaded: TimeInterval,
        total: TimeInterval
    ) {
        if transportRace != nil {
            guard sourceEngine === visibleHLSEngineReference else { return }
        } else {
            guard sourceEngine === selectedHLSEngine else { return }
        }
        delegate?.syPlayer(
            player: self,
            loadedTimeDidChange: loaded,
            totalDuration: total
        )
    }

    /// Receives play time updates from the engine.
    func playerEngine(
        _ sourceEngine: SYPlayerEngine,
        playTimeDidChange current: TimeInterval,
        total: TimeInterval
    ) {
        if transportRace != nil {
            guard sourceEngine === visibleHLSEngineReference else { return }
        } else {
            guard sourceEngine === selectedHLSEngine else { return }
        }
        delegate?.syPlayer(
            player: self,
            playTimeDidChange: current,
            totalTime: total
        )
    }

    /// Receives playing flag updates from the engine.
    func playerEngine(
        _ sourceEngine: SYPlayerEngine,
        isPlayingDidChange isPlaying: Bool
    ) {
        if transportRace != nil {
            guard sourceEngine === visibleHLSEngineReference else { return }
        } else {
            guard sourceEngine === selectedHLSEngine else { return }
        }
        controlView.playStateDidChange(isPlaying: isPlaying)
        delegate?.syPlayer(player: self, playerIsPlaying: isPlaying)
    }

    func playerEngine(
        _ sourceEngine: SYPlayerEngine,
        didReceiveErrorStatusCode statusCode: Int,
        comment: String?
    ) {
        guard transportRace == nil,
              sourceEngine === selectedHLSEngine
        else {
            return
        }
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
        if let race = transportRace, !race.webRTC.isTerminal {
            switch state {
            case .buffering, .ready, .playing:
                markRaceCapability(
                    .supported,
                    for: .webRTC,
                    raceID: race.id
                )
            default:
                break
            }

            switch state {
            case .playing:
                clearWHEPCooldownAfterSuccessfulPlayback()
                markRaceFirstFrame(for: .webRTC, raceID: race.id)
            case .error(let message):
                recordWHEPFailure(message: message)
                markRaceCandidateUnavailable(
                    .webRTC,
                    reason: message,
                    raceID: race.id
                )
            default:
                break
            }
            return
        }

        guard selectedTransport == .webRTC else { return }
        if case .error(let message) = state {
            recordWHEPFailure(message: message)
            if fallbackToNextVideoIfPossible() { return }
        }

        switch state {
        case .playing:
            clearWHEPCooldownAfterSuccessfulPlayback()
            showTransportFrame(.webRTC)
            isPlayToTheEnd = false
        case .ready:
            controlView.playerStateDidChange(state: state)
            delegate?.syPlayer(player: self, playerStateDidChange: state)
            isPlayToTheEnd = false
        case .ended:
            controlView.playerStateDidChange(state: state)
            delegate?.syPlayer(player: self, playerStateDidChange: state)
            isPlayToTheEnd = true
        case .error, .idle:
            controlView.playerStateDidChange(state: state)
            delegate?.syPlayer(player: self, playerStateDidChange: state)
            if case .error = state {
                controlView.setTransportState(.failed(.webRTC))
            }
            isPlayToTheEnd = false
        case .preparing, .buffering, .paused:
            controlView.playerStateDidChange(state: state)
            delegate?.syPlayer(player: self, playerStateDidChange: state)
        }
    }

    private func recordWHEPFailure(message: String) {
        guard let currentVideo,
              case .whep(let endpointURL, _) = currentVideo.source
        else {
            return
        }

        let cooldown = whepCooldown(for: message)
        SYWHEPCooldownStore.shared.recordFailure(
            endpointURL: endpointURL,
            reason: message,
            duration: cooldown.duration
        )
        guard cooldown.duration > 0 else { return }

        SYPlayerConfig.shared.log(
            "Player WHEP \(cooldown.kind) cooldown started for "
                + "\(Int(ceil(cooldown.duration)))s (reason: \(message))",
            level: .warning
        )
    }

    private func whepCooldown(
        for message: String
    ) -> (duration: TimeInterval, kind: String) {
        let config = SYPlayerConfig.shared
        guard let status = Self.whepHTTPStatus(from: message),
              400..<500 ~= status,
              ![408, 425, 429].contains(status)
        else {
            return (config.whepTransientFailureCooldownDuration, "transient")
        }
        return (config.whepCooldownDuration, "server-rejection")
    }

    private static func whepHTTPStatus(from message: String) -> Int? {
        guard let markerRange = message.range(
            of: "WHEP HTTP status ",
            options: .caseInsensitive
        ) else {
            return nil
        }

        let statusCharacters = message[markerRange.upperBound...].prefix {
            $0.isNumber
        }
        return Int(statusCharacters)
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
        if transportRace != nil {
            guard visibleTransport == .webRTC else { return }
        } else {
            guard selectedTransport == .webRTC else { return }
        }
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
        guard transportRace == nil, selectedTransport != .webRTC else { return }
        selectedHLSEngine?.player.rate = rate
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
