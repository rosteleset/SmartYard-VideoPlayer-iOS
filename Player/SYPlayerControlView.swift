//
//  SmartYardPlayerControlView.swift
//  SmartYard
//
//  Created by Александр Попов on 01.07.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import UIKit
import SnapKit
import RxSwift
import RxCocoa
import Lottie
import Kingfisher
import SwifterSwift
import TouchAreaInsets

extension SYPlayerControlView {
    enum ButtonType: Int { case play, pause, favourite, fullscreenToggle }
    typealias Mode = SYPlayerUIMode

    private enum Layout {
        static let sideAccessoryButtonSize: CGFloat = 36
        static let sideAccessorySpacing: CGFloat = 12
        static let sideAccessoryTopOffset: CGFloat = 24
        static let transportBadgeHeight: CGFloat = 28
        static let transportBadgeHorizontalInset: CGFloat = 10
        static let transportBadgeStatusSize: CGFloat = 7
        static let transportOverlayHorizontalInset: CGFloat = 16
        static let transportOverlayMaxWidth: CGFloat = 320
    }
}

protocol SYPlayerControlViewDelegate: AnyObject {
    /// Notifies about a playback rate change request.
    func controlView(
        controlView: SYPlayerControlView,
        didChangeVideoPlaybackRate rate: Float
    )

    /// Notifies about a control button tap.
    func controlView(
        controlView: SYPlayerControlView,
        didPressButton button: UIButton
    )
}

// swiftlint:disable type_body_length
final class SYPlayerControlView: UIView {

    weak var delegate: SYPlayerControlViewDelegate?
    weak var player: SYPlayer?

    // MARK: - Variables
    private(set) var resource: SYPlayerResource?
    private var delayItem: DispatchWorkItem?

    private var selectedIndex = 0
    private var isShowingControls = false

    private var videoType: SYPlayedVideoType = SYPlayerConfig.shared.videoType
    private var mode: Mode = .default

    private var hasSound = true

    private var playerLastState: SYPlayerState = .idle
    private var isLoaderVisible = false
    private var hasVisiblePlaybackStarted = false
    private var isControlsAutoHideEnabled = true
    private var rightAccessoryItems: [SYPlayerControlAccessoryItem] = []
    private var rightAccessoryButtons: [String: UIButton] = [:]
    private var transportState: SYPlayerTransportState = .hidden
    private var transportMessageWorkItem: DispatchWorkItem?
    private var transportTooltipWorkItem: DispatchWorkItem?

    // MARK: - UI Elements
    private let mainMaskView = UIView()
    private let mainView = UIView()
    private let topView = UIView()
    private let bottomView = UIView()

    private let imageView = UIImageView()

    private let titleLabel = UILabel()
    private let fullscreenButton = UIButton(type: .custom)
    private let soundToggleButton = UIButton(type: .custom)
    private let rightAccessoryStackView = UIStackView()

    private let videoLoadingAnimationView = LottieAnimationView()
    private let transportBadgeButton = UIButton(type: .custom)
    private let transportStatusDotView = UIView()
    private let transportActivityIndicator = UIActivityIndicatorView(style: .medium)
    private let transportMessageView = UIView()
    private let transportMessageLabel = UILabel()
    private let transportTooltipView = UIView()
    private let transportTooltipLabel = UILabel()

    // Archive only
    private let previousSpeedButton = UIButton(type: .custom)
    private let nextSpeedButton = UIButton(type: .custom)
    private let playButton = UIButton(type: .custom)
    private var periodCollectionView: UICollectionView?
    private let progressSlider = SYVideoRangeSlider()

    private let liveLabel = UILabel()

    // MARK: - Rx State
    private let isSoundOn = BehaviorSubject<Bool>(value: false)
    private let isControlViewShowing = BehaviorSubject<Bool>(value: false)
    private let playerStateSubject = BehaviorSubject<SYPlayerState>(value: .idle)

    private let disposeBag = DisposeBag()

    // MARK: - Gestures
    private lazy var tapGesture: UITapGestureRecognizer = {
        UITapGestureRecognizer(
            target: self,
            action: #selector(onTapGestureTapped(_:))
        )
    }()

    // MARK: - Init
    /// Creates the control view with a frame.
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        addLayoutContstraints()
        bind()
    }

    /// Creates the control view from a storyboard or xib (not supported).
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API
    /// Configures the control view for video type and sound availability.
    func configure(videoType: SYPlayedVideoType, hasSound: Bool = true) {
        SYPlayerConfig.shared.log(
            "ControlView configure (type: \(videoType), hasSound: \(hasSound))",
            level: .debug
        )
        self.videoType = videoType
        self.hasSound = hasSound

        soundToggleButton.isHidden = !hasSound
        isSoundOn.onNext(hasSound)

        // Пересобираем archive UI если нужно
        rebuildArchiveUIIfNeeded()
        updateTitleVisibility()
        setNeedsLayout()
        layoutIfNeeded()
    }

    func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        updateTitleVisibility()
        fullscreenButton.isSelected = mode == .fullscreen
        updateTransportBadge()
        updateTransportMessage()
        updateVisibleTransportTooltip()
    }

    func setRightAccessoryItems(_ items: [SYPlayerControlAccessoryItem]) {
        rightAccessoryItems = items
        rebuildRightAccessoryStack()
    }

    func updateRightAccessoryItem(
        id: String,
        _ update: (inout SYPlayerControlAccessoryItem) -> Void
    ) {
        guard let index = rightAccessoryItems.firstIndex(where: { $0.id == id }) else { return }

        update(&rightAccessoryItems[index])
        configureRightAccessoryButton(
            rightAccessoryButtons[id],
            with: rightAccessoryItems[index]
        )
    }

    func removeRightAccessoryItem(id: String) {
        rightAccessoryItems.removeAll { $0.id == id }
        rebuildRightAccessoryStack()
    }

    func removeAllRightAccessoryItems() {
        rightAccessoryItems.removeAll()
        rebuildRightAccessoryStack()
    }

    func setControlsAutoHideEnabled(_ isEnabled: Bool) {
        isControlsAutoHideEnabled = isEnabled

        if isEnabled {
            autoFadeOutControlViewWithAnimation()
        } else {
            cancelAutoFadeOutAnimation()
            setControlsVisible(true)
        }
    }

    func setTransportState(_ state: SYPlayerTransportState) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setTransportState(state)
            }
            return
        }
        guard transportState != state else { return }

        transportState = state
        if case .failed = state {
            hideLoader()
        }
        updateTransportBadge()
        updateTransportMessage()
        updateVisibleTransportTooltip()
    }

    /// Prepares UI for a resource and selected index.
    func prepareUI(for resource: SYPlayerResource, selectedIndex index: Int) {
        SYPlayerConfig.shared.log(
            "ControlView prepareUI (name: \(resource.name), index: \(index))",
            level: .debug
        )
        self.resource = resource
        self.selectedIndex = index
        hasVisiblePlaybackStarted = false
        titleLabel.text = resource.name
        setTransportState(.hidden)
        showLoader()
        autoFadeOutControlViewWithAnimation()
    }

    // MARK: - Bind
    /// Binds UI interactions and reactive state.
    private func bind() {
        fullscreenButton.rx.tap
            .subscribe(onNext: { [weak self] in
                guard let self else { return }

                onButtonTapped(fullscreenButton)
            })
            .disposed(by: disposeBag)

        playButton.rx.tap
            .subscribe(onNext: { [weak self] in
                guard let self else { return }

                onButtonTapped(playButton)
            })
            .disposed(by: disposeBag)

        // Sound toggle -> state
        soundToggleButton.rx.tap
            .withLatestFrom(isSoundOn) { _, current in !current }
            .bind(to: isSoundOn)
            .disposed(by: disposeBag)

        // Sound state -> UI + Player
        isSoundOn
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe { [weak self] isOn in
                guard let self else { return }

                soundToggleButton.isSelected = isOn
                player?.setMuted(!isOn)
            }
            .disposed(by: disposeBag)

        // Orientation (оставил как было, но лучше получать от SYPlayer)
        NotificationCenter.default.rx.notification(UIDevice.orientationDidChangeNotification)
            .map { _ in UIDevice.current.orientation }
            .subscribe { [weak self] orientation in
                self?.handleOrientationChange(orientation)
            }
            .disposed(by: disposeBag)

        // Player state -> loader + controls
        playerStateSubject
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] state in
                guard let self else { return }

                playerLastState = state

                if hasVisiblePlaybackStarted {
                    if case .playing = state {
                        hideLoader()
                    } else {
                        showLoader()
                    }
                } else {
                    showLoader()
                }

                switch state {
                case .playing:
                    autoFadeOutControlViewWithAnimation()
                default:
                    setControlsVisible(true)
                }
            })
            .disposed(by: disposeBag)

        // Controls visible -> animate
        isControlViewShowing
            .distinctUntilChanged()
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] shouldShow in
                guard let self else { return }

                applyControlsVisibility(shouldShow)
            })
            .disposed(by: disposeBag)
    }

    // MARK: - Public from SYPlayer

    /// Updates UI state based on player state.
    func playerStateDidChange(state: SYPlayerState) {
        SYPlayerConfig.shared.log(
            "ControlView state changed: \(state)",
            level: .debug
        )
        playerStateSubject.onNext(state)
    }

    /// Updates play button state and auto-hide behavior.
    func playStateDidChange(isPlaying: Bool) {
        SYPlayerConfig.shared.log(
            "ControlView playState changed: \(isPlaying)",
            level: .debug
        )
        autoFadeOutControlViewWithAnimation()
        playButton.isSelected = isPlaying
    }

    /// Shows the preview image (or clears it if URL is nil).
    func showImageView(url: URL?, hideLoaderOnFinish: Bool = true) {
        SYPlayerConfig.shared.log(
            "ControlView show preview (hasURL: \(url != nil), hideLoaderOnFinish: \(hideLoaderOnFinish))",
            level: .debug
        )
        guard let url else {
            imageView.image = nil
            if hideLoaderOnFinish, hasVisiblePlaybackStarted, case .playing = playerLastState {
                hideLoader()
            }
            return
        }

        imageView.isHidden = false
        imageView.kf.setImage(with: url) { [weak self] _ in
            guard let self else { return }
            if hideLoaderOnFinish, hasVisiblePlaybackStarted, case .playing = playerLastState {
                hideLoader()
            }
        }
    }

    /// Hides the preview image.
    func hideImageView() {
        SYPlayerConfig.shared.log("ControlView hide preview", level: .debug)
        imageView.isHidden = true
    }

    /// Shows or hides control views via reactive state.
    func setControlsVisible(_ visible: Bool) {
        SYPlayerConfig.shared.log(
            "ControlView setControlsVisible: \(visible)",
            level: .debug
        )
        isControlViewShowing.onNext(visible)
    }

    /// Toggles controls visibility from an external tap surface.
    func toggleControlsVisibility() {
        if case .ended = playerLastState { return }
        guard isControlsAutoHideEnabled else {
            setControlsVisible(true)
            return
        }
        setControlsVisible(!isShowingControls)
    }

    /// Cancels any delayed UI work.
    func prepareToDealloc() {
        SYPlayerConfig.shared.log("ControlView prepareToDealloc", level: .debug)
        delayItem?.cancel()
        delayItem = nil
        transportMessageWorkItem?.cancel()
        transportMessageWorkItem = nil
        transportTooltipWorkItem?.cancel()
        transportTooltipWorkItem = nil
        hasVisiblePlaybackStarted = false
        setTransportState(.hidden)
        setLoaderVisible(false, animated: false)
    }

    func playbackDidBecomeVisible() {
        guard !hasVisiblePlaybackStarted else { return }
        hasVisiblePlaybackStarted = true
        hideLoader()
    }

    // MARK: - Loader

    /// Shows the loading animation.
    private func showLoader() {
        setLoaderVisible(true)
    }

    /// Hides the loading animation.
    private func hideLoader() {
        setLoaderVisible(false)
    }

    private func setLoaderVisible(_ visible: Bool, animated: Bool = true) {
        guard isLoaderVisible != visible else {
            if visible {
                videoLoadingAnimationView.isHidden = false
                videoLoadingAnimationView.alpha = 1
                if !videoLoadingAnimationView.isAnimationPlaying {
                    videoLoadingAnimationView.play()
                }
            } else {
                videoLoadingAnimationView.alpha = 0
                videoLoadingAnimationView.isHidden = true
                videoLoadingAnimationView.stop()
            }
            return
        }

        isLoaderVisible = visible
        videoLoadingAnimationView.layer.removeAllAnimations()

        if visible {
            videoLoadingAnimationView.isHidden = false
            videoLoadingAnimationView.alpha = animated ? 0 : 1
            videoLoadingAnimationView.play()
        }

        let applyVisibility: () -> Void = { [weak self] in
            guard let self else { return }
            videoLoadingAnimationView.alpha = visible ? 1 : 0
        }

        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self else { return }
            if !visible {
                videoLoadingAnimationView.stop()
                videoLoadingAnimationView.isHidden = true
            }
        }

        guard animated else {
            applyVisibility()
            completion(true)
            return
        }

        UIView.animate(
            withDuration: visible ? 0.22 : 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
            animations: applyVisibility,
            completion: completion
        )
    }

    // MARK: - Transport status

    private func updateTransportBadge() {
        guard mode == .fullscreen,
              let transport = transportState.transport else {
            transportBadgeButton.isHidden = true
            transportActivityIndicator.stopAnimating()
            hideTransportTooltip(animated: false)
            return
        }

        let appearance = SYPlayerConfig.shared.transportAppearance
        let accentColor = transportColor(for: transport)

        transportBadgeButton.isHidden = false
        transportBadgeButton.setTitle(transport.title, for: .normal)
        transportBadgeButton.setTitleColor(accentColor, for: .normal)
        transportBadgeButton.layer.borderColor = accentColor.withAlphaComponent(0.82).cgColor
        transportBadgeButton.accessibilityLabel = "\(transport.title). \(transportInfo(for: transport))"

        transportStatusDotView.isHidden = false

        switch transportState {
        case .connecting, .switchingToHLS:
            transportStatusDotView.isHidden = true
            if case .switchingToHLS = transportState {
                transportActivityIndicator.color = appearance.warningColor
            } else {
                transportActivityIndicator.color = accentColor
            }
            transportActivityIndicator.startAnimating()

        case .playing:
            transportActivityIndicator.stopAnimating()
            transportStatusDotView.backgroundColor = appearance.playingColor

        case .failed:
            transportActivityIndicator.stopAnimating()
            transportStatusDotView.backgroundColor = appearance.errorColor

        case .hidden:
            break
        }
    }

    private func updateTransportMessage() {
        transportMessageWorkItem?.cancel()
        transportMessageWorkItem = nil

        let appearance = SYPlayerConfig.shared.transportAppearance
        let strings = SYPlayerConfig.shared.transportStrings
        let isFailure: Bool

        if case .failed = transportState {
            isFailure = true
        } else {
            isFailure = false
        }

        updateTransportMessageLayout(isCentered: isFailure)

        guard mode == .fullscreen || isFailure else {
            hideTransportMessage()
            return
        }

        switch transportState {
        case .hidden:
            hideTransportMessage()

        case .connecting(.webRTC):
            showTransportMessage(
                strings.connectingWebRTC,
                accentColor: appearance.webRTCColor
            )

        case .connecting(.hls):
            showTransportMessage(
                strings.connectingHLS,
                accentColor: appearance.hlsColor
            )

        case .connecting(.lowLatencyHLS):
            showTransportMessage(
                strings.connectingLowLatencyHLS,
                accentColor: appearance.hlsColor
            )

        case .switchingToHLS(.hls):
            showTransportMessage(
                strings.switchingToHLS,
                accentColor: appearance.warningColor,
                announce: true
            )

        case .switchingToHLS(.lowLatencyHLS):
            showTransportMessage(
                strings.switchingToLowLatencyHLS,
                accentColor: appearance.warningColor,
                announce: true
            )

        case .switchingToHLS(.webRTC):
            hideTransportMessage()

        case .playing(.hls, let announceConnection) where announceConnection:
            showTransportMessage(
                strings.connectedHLS,
                accentColor: appearance.hlsColor,
                announce: true
            )
            scheduleTransportMessageDismissal()

        case .playing(.lowLatencyHLS, let announceConnection) where announceConnection:
            showTransportMessage(
                strings.connectedLowLatencyHLS,
                accentColor: appearance.hlsColor,
                announce: true
            )
            scheduleTransportMessageDismissal()

        case .playing:
            hideTransportMessage()

        case .failed:
            showTransportMessage(
                strings.videoUnavailable,
                accentColor: appearance.errorColor,
                announce: true
            )
        }
    }

    private func updateTransportMessageLayout(isCentered: Bool) {
        transportMessageView.snp.remakeConstraints {
            $0.centerX.equalToSuperview()

            if isCentered {
                $0.centerY.equalToSuperview()
            } else {
                $0.top.equalTo(videoLoadingAnimationView.snp.bottom).offset(12)
            }

            $0.leading.greaterThanOrEqualToSuperview().inset(Layout.transportOverlayHorizontalInset)
            $0.trailing.lessThanOrEqualToSuperview().inset(Layout.transportOverlayHorizontalInset)
            $0.width.lessThanOrEqualTo(Layout.transportOverlayMaxWidth)
        }
    }

    private func showTransportMessage(
        _ message: String,
        accentColor: UIColor,
        announce: Bool = false
    ) {
        transportMessageLabel.text = message
        transportMessageView.layer.borderColor = accentColor.withAlphaComponent(0.7).cgColor
        transportMessageView.isHidden = false
        transportMessageView.layer.removeAllAnimations()

        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) { [weak self] in
            self?.transportMessageView.alpha = 1
        }

        if announce {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func hideTransportMessage(animated: Bool = true) {
        let animations: () -> Void = { [weak self] in
            self?.transportMessageView.alpha = 0
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, transportMessageView.alpha == 0 else { return }
            transportMessageView.isHidden = true
        }

        transportMessageView.layer.removeAllAnimations()
        guard animated, !transportMessageView.isHidden else {
            animations()
            completion(true)
            return
        }

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
            animations: animations,
            completion: completion
        )
    }

    private func scheduleTransportMessageDismissal() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideTransportMessage()
        }
        transportMessageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func updateVisibleTransportTooltip() {
        guard !transportTooltipView.isHidden,
              let transport = transportState.transport else {
            return
        }

        updateVisibleTransportTooltipContent(for: transport)
    }

    private func showTransportTooltip() {
        guard let transport = transportState.transport else { return }

        transportTooltipWorkItem?.cancel()
        updateVisibleTransportTooltipContent(for: transport)
        transportTooltipView.isHidden = false
        transportTooltipView.alpha = 0
        transportTooltipView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)

        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) { [weak self] in
            self?.transportTooltipView.alpha = 1
            self?.transportTooltipView.transform = .identity
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideTransportTooltip()
        }
        transportTooltipWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func updateVisibleTransportTooltipContent(for transport: SYPlayerTransport) {
        let accentColor = transportColor(for: transport)
        let info = transportInfo(for: transport)
        transportTooltipLabel.text = info
        transportTooltipView.accessibilityLabel = info
        transportTooltipView.layer.borderColor = accentColor.withAlphaComponent(0.7).cgColor
    }

    private func hideTransportTooltip(animated: Bool = true) {
        transportTooltipWorkItem?.cancel()
        transportTooltipWorkItem = nil

        let animations: () -> Void = { [weak self] in
            self?.transportTooltipView.alpha = 0
            self?.transportTooltipView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, transportTooltipView.alpha == 0 else { return }
            transportTooltipView.isHidden = true
            transportTooltipView.transform = .identity
        }

        transportTooltipView.layer.removeAllAnimations()
        guard animated, !transportTooltipView.isHidden else {
            animations()
            completion(true)
            return
        }

        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
            animations: animations,
            completion: completion
        )
    }

    private func transportColor(for transport: SYPlayerTransport) -> UIColor {
        let appearance = SYPlayerConfig.shared.transportAppearance
        switch transport {
        case .webRTC:
            return appearance.webRTCColor
        case .hls, .lowLatencyHLS:
            return appearance.hlsColor
        }
    }

    private func transportInfo(for transport: SYPlayerTransport) -> String {
        let strings = SYPlayerConfig.shared.transportStrings
        switch transport {
        case .webRTC:
            return strings.webRTCInfo
        case .hls:
            return strings.hlsInfo
        case .lowLatencyHLS:
            return strings.lowLatencyHLSInfo
        }
    }

    // MARK: - Auto hide

    /// Schedules auto-hide for controls if playing.
    private func autoFadeOutControlViewWithAnimation() {
        cancelAutoFadeOutAnimation()
        guard isControlsAutoHideEnabled else {
            setControlsVisible(true)
            return
        }

        delayItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .playing = playerLastState else { return }
            setControlsVisible(false)
        }

        if let delayItem {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SYPlayerConfig.shared.animateTimeInterval,
                execute: delayItem
            )
        }
    }

    /// Cancels any pending auto-hide.
    private func cancelAutoFadeOutAnimation() {
        delayItem?.cancel()
    }

    // MARK: - UI

    /// Initializes subviews and static UI properties.
    private func setupUI() {
        let colors = SYPlayerConfig.shared.colors
        let fonts = SYPlayerConfig.shared.fonts
        let transportAppearance = SYPlayerConfig.shared.transportAppearance

        mainMaskView.backgroundColor = .clear
        mainView.clipsToBounds = true

        titleLabel.textAlignment = .center
        titleLabel.font = fonts.titleFont
        titleLabel.textColor = colors.controlsTextColor
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true

        fullscreenButton.imageForNormal = SYPlayerConfig.shared.icon(.fullscreenEnter)
        fullscreenButton.imageForSelected = SYPlayerConfig.shared.icon(.fullscreenExit)
        fullscreenButton.tintColor = colors.controlsTintColor
        fullscreenButton.tag = ButtonType.fullscreenToggle.rawValue
        fullscreenButton.touchAreaInsets = UIEdgeInsets(inset: 12)

        soundToggleButton.imageForNormal = SYPlayerConfig.shared.icon(.soundOff)
        soundToggleButton.imageForSelected = SYPlayerConfig.shared.icon(.soundOn)
        soundToggleButton.touchAreaInsets = UIEdgeInsets(inset: 12)
        soundToggleButton.isHidden = !hasSound

        rightAccessoryStackView.axis = .vertical
        rightAccessoryStackView.alignment = .fill
        rightAccessoryStackView.distribution = .fill
        rightAccessoryStackView.spacing = Layout.sideAccessorySpacing
        rightAccessoryStackView.isHidden = true

        let animation = LottieAnimation.named("LoaderAnimation", bundle: .syPlayer)
        videoLoadingAnimationView.animation = animation
        videoLoadingAnimationView.loopMode = .loop
        videoLoadingAnimationView.backgroundBehavior = .pauseAndRestore
        videoLoadingAnimationView.isHidden = true
        videoLoadingAnimationView.alpha = 0

        transportBadgeButton.contentEdgeInsets = UIEdgeInsets(
            top: 0,
            left: Layout.transportBadgeHorizontalInset,
            bottom: 0,
            right: Layout.transportBadgeHorizontalInset + Layout.transportBadgeStatusSize + 8
        )
        transportBadgeButton.titleLabel?.font = transportAppearance.badgeFont
        transportBadgeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        transportBadgeButton.backgroundColor = transportAppearance.badgeBackgroundColor
        transportBadgeButton.layer.cornerRadius = Layout.transportBadgeHeight / 2
        transportBadgeButton.layer.borderWidth = 1
        transportBadgeButton.isHidden = true
        transportBadgeButton.accessibilityTraits = .button
        transportBadgeButton.addTarget(
            self,
            action: #selector(onTransportBadgeTapped),
            for: .touchUpInside
        )

        transportStatusDotView.layer.cornerRadius = Layout.transportBadgeStatusSize / 2
        transportStatusDotView.isUserInteractionEnabled = false

        transportActivityIndicator.hidesWhenStopped = true
        transportActivityIndicator.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
        transportActivityIndicator.isUserInteractionEnabled = false

        transportMessageView.backgroundColor = transportAppearance.messageBackgroundColor
        transportMessageView.layer.cornerRadius = 12
        transportMessageView.layer.borderWidth = 1
        transportMessageView.isHidden = true
        transportMessageView.alpha = 0
        transportMessageView.isUserInteractionEnabled = false

        transportMessageLabel.font = transportAppearance.messageFont
        transportMessageLabel.textColor = transportAppearance.textColor
        transportMessageLabel.textAlignment = .center
        transportMessageLabel.numberOfLines = 0
        transportMessageLabel.adjustsFontForContentSizeCategory = true

        transportTooltipView.backgroundColor = transportAppearance.messageBackgroundColor
        transportTooltipView.layer.cornerRadius = 12
        transportTooltipView.layer.borderWidth = 1
        transportTooltipView.isHidden = true
        transportTooltipView.alpha = 0
        transportTooltipView.isUserInteractionEnabled = false
        transportTooltipView.isAccessibilityElement = true

        transportTooltipLabel.font = transportAppearance.messageFont
        transportTooltipLabel.textColor = transportAppearance.textColor
        transportTooltipLabel.numberOfLines = 0
        transportTooltipLabel.adjustsFontForContentSizeCategory = true

        playButton.imageForNormal = SYPlayerConfig.shared.icon(.play)
        playButton.imageForSelected = SYPlayerConfig.shared.icon(.pause)
        playButton.touchAreaInsets = UIEdgeInsets(inset: 6)
        playButton.tag = ButtonType.play.rawValue

        previousSpeedButton.titleForNormal = "0.5x"
        previousSpeedButton.setTitleColorForAllStates(colors.controlsTextColor)
        previousSpeedButton.touchAreaInsets = UIEdgeInsets(inset: 12)
        previousSpeedButton.titleLabel?.font = fonts.speedButtonFont

        nextSpeedButton.titleForNormal = "1.5x"
        nextSpeedButton.setTitleColorForAllStates(colors.controlsTextColor)
        nextSpeedButton.touchAreaInsets = UIEdgeInsets(inset: 12)
        nextSpeedButton.titleLabel?.font = fonts.speedButtonFont

        progressSlider.setReferenceCalendar(SYPlayerConfig.shared.referenceCalendar)
        progressSlider.touchAreaInsets = UIEdgeInsets(inset: 6)
        progressSlider.delegate = self

        addGestureRecognizer(tapGesture)
    }

    /// Builds or removes archive-specific UI based on video type.
    private func rebuildArchiveUIIfNeeded() {
        switch videoType {
        case .archive:
            // Если archive — создаём collectionView и показываем archive controls.
            guard periodCollectionView == nil else { return }

            let layout = UICollectionViewFlowLayout()
            layout.scrollDirection = .horizontal
            let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
            cv.touchAreaInsets = UIEdgeInsets(inset: 8)
            cv.isPrefetchingEnabled = true
            cv.backgroundColor = .clear
            cv.showsHorizontalScrollIndicator = false
            cv.showsVerticalScrollIndicator = false
            cv.delegate = self
            cv.dataSource = self
            cv.register(nibWithCellClass: VideoPeriodPickerCell.self)
            periodCollectionView = cv

        case .online:
            // Если online — чистим.
            periodCollectionView?.removeFromSuperview()
            periodCollectionView = nil
        }
    }

    /// Adds layout constraints for the view hierarchy.
    private func addLayoutContstraints() {
        addSubview(mainMaskView)
        mainMaskView.addSubview(mainView)
        mainMaskView.addSubview(videoLoadingAnimationView)
        mainMaskView.addSubview(transportBadgeButton)
        transportBadgeButton.addSubview(transportStatusDotView)
        transportBadgeButton.addSubview(transportActivityIndicator)
        mainMaskView.addSubview(transportMessageView)
        transportMessageView.addSubview(transportMessageLabel)
        mainMaskView.addSubview(transportTooltipView)
        transportTooltipView.addSubview(transportTooltipLabel)

        mainView.addSubview(topView)
        mainView.addSubview(bottomView)
        mainView.insertSubview(imageView, at: 0)

        topView.addSubview(fullscreenButton)
        topView.addSubview(soundToggleButton)
        topView.addSubview(titleLabel)
        mainView.addSubview(rightAccessoryStackView)

        mainMaskView.snp.makeConstraints { $0.directionalEdges.equalToSuperview() }
        mainView.snp.makeConstraints { $0.directionalEdges.equalTo(safeAreaLayoutGuide) }
        imageView.snp.makeConstraints { $0.directionalEdges.equalTo(mainView) }

        topView.snp.makeConstraints {
            $0.top.equalToSuperview()
            $0.left.right.equalToSuperview()
            $0.height.equalTo(44)
        }

        fullscreenButton.snp.makeConstraints {
            $0.centerY.equalToSuperview()
            $0.right.equalToSuperview().inset(16)
            $0.width.height.equalTo(32)
        }

        soundToggleButton.snp.makeConstraints {
            $0.centerY.equalToSuperview()
            $0.left.equalToSuperview().inset(16)
            $0.width.height.equalTo(32)
        }

        rightAccessoryStackView.snp.makeConstraints {
            $0.top.equalTo(fullscreenButton.snp.bottom).offset(Layout.sideAccessoryTopOffset)
            $0.centerX.equalTo(fullscreenButton)
            $0.width.equalTo(Layout.sideAccessoryButtonSize)
        }

        titleLabel.snp.makeConstraints {
            $0.top.equalTo(topView.snp.bottom).offset(26)
            $0.left.right.equalToSuperview().inset(26)
            $0.height.equalTo(44)
        }

        videoLoadingAnimationView.snp.makeConstraints {
            $0.centerX.centerY.equalToSuperview()
            $0.height.width.equalTo(80)
        }

        transportBadgeButton.snp.makeConstraints {
            $0.trailing.equalTo(safeAreaLayoutGuide).inset(Layout.transportOverlayHorizontalInset)
            $0.bottom.equalTo(safeAreaLayoutGuide).inset(12)
            $0.height.equalTo(Layout.transportBadgeHeight)
        }

        transportStatusDotView.snp.makeConstraints {
            $0.centerY.equalToSuperview()
            $0.trailing.equalToSuperview().inset(Layout.transportBadgeHorizontalInset)
            $0.width.height.equalTo(Layout.transportBadgeStatusSize)
        }

        transportActivityIndicator.snp.makeConstraints {
            $0.center.equalTo(transportStatusDotView)
            $0.width.height.equalTo(20)
        }

        transportMessageView.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.top.equalTo(videoLoadingAnimationView.snp.bottom).offset(12)
            $0.leading.greaterThanOrEqualToSuperview().inset(Layout.transportOverlayHorizontalInset)
            $0.trailing.lessThanOrEqualToSuperview().inset(Layout.transportOverlayHorizontalInset)
            $0.width.lessThanOrEqualTo(Layout.transportOverlayMaxWidth)
        }

        transportMessageLabel.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 9, left: 12, bottom: 9, right: 12))
        }

        transportTooltipView.snp.makeConstraints {
            $0.trailing.equalTo(transportBadgeButton)
            $0.bottom.equalTo(transportBadgeButton.snp.top).offset(-8)
            $0.leading.greaterThanOrEqualToSuperview().inset(Layout.transportOverlayHorizontalInset)
            $0.width.lessThanOrEqualTo(Layout.transportOverlayMaxWidth)
        }

        transportTooltipLabel.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        }

        // bottomView constraints зависят от mode
        layoutBottom()
    }

    /// Lays out the bottom controls for the current video type.
    private func layoutBottom() {
        bottomView.subviews.forEach { $0.removeFromSuperview() }

        if videoType == .online {
            bottomView.snp.remakeConstraints {
                $0.bottom.left.right.equalToSuperview()
                $0.height.equalTo(44)
            }
            // тут можно положить liveLabel и т.п.
            return
        }

        // archive
        bottomView.snp.remakeConstraints {
            $0.bottom.equalToSuperview().inset(8)
            $0.left.right.equalToSuperview()
            $0.top.equalTo(videoLoadingAnimationView.snp.bottom).offset(24)
        }

        let buttonsCentering = UIView()
        bottomView.addSubview(buttonsCentering)
        buttonsCentering.addSubview(playButton)
        buttonsCentering.addSubview(previousSpeedButton)
        buttonsCentering.addSubview(nextSpeedButton)

        buttonsCentering.snp.makeConstraints {
            $0.height.equalTo(68)
            $0.left.right.equalToSuperview().inset(16)
            $0.bottom.equalToSuperview()
        }

        playButton.snp.makeConstraints {
            $0.centerX.centerY.equalToSuperview()
            $0.height.width.equalTo(68)
        }

        previousSpeedButton.snp.makeConstraints {
            $0.centerY.equalToSuperview()
            $0.left.equalToSuperview().inset(20)
        }

        nextSpeedButton.snp.makeConstraints {
            $0.right.equalToSuperview().inset(20)
            $0.centerY.equalToSuperview()
        }

        if let cv = periodCollectionView {
            bottomView.addSubview(cv)
            bottomView.addSubview(progressSlider)

            cv.snp.makeConstraints {
                $0.left.right.equalToSuperview()
                $0.bottom.equalTo(buttonsCentering.snp.top).offset(-16)
                $0.height.equalTo(24)
            }

            progressSlider.snp.makeConstraints {
                $0.height.equalTo(37)
                $0.bottom.equalTo(cv.snp.top).offset(-16)
                $0.left.right.equalToSuperview().inset(12)
            }
        }
    }

    /// Updates layout for portrait or landscape orientation.
    func updateUI(isPortrait: Bool) {
        fullscreenButton.isSelected = mode == .fullscreen
        updateTitleVisibility()

        titleLabel.snp.remakeConstraints {
            if isPortrait {
                $0.top.equalTo(topView.snp.bottom).offset(26)
                $0.left.right.equalToSuperview().inset(26)
            } else {
                $0.left.equalTo(soundToggleButton.snp.right)
                $0.right.equalTo(fullscreenButton.snp.left)
            }
            $0.height.greaterThanOrEqualTo(44)
        }

        layoutIfNeeded()

        guard videoType == .archive else { return }

        bottomView.snp.remakeConstraints {
            if isPortrait {
                $0.bottom.equalToSuperview()
                $0.left.right.equalToSuperview()
                $0.top.equalTo(videoLoadingAnimationView.snp.bottom).offset(24)
            } else {
                $0.bottom.equalToSuperview().inset(4)
                $0.left.right.equalToSuperview()
                $0.top.equalTo(videoLoadingAnimationView)
            }
        }

        layoutIfNeeded()
    }

    // MARK: - Actions

    /// Forwards button taps to the delegate.
    private func onButtonTapped(_ button: UIButton) {
        delegate?.controlView(controlView: self, didPressButton: button)
    }

    @objc private func onRightAccessoryButtonTapped(_ sender: UIButton) {
        guard let id = sender.accessibilityIdentifier else { return }
        rightAccessoryItems.first { $0.id == id }?.action?()
    }

    @objc private func onTransportBadgeTapped() {
        transportTooltipView.isHidden ? showTransportTooltip() : hideTransportTooltip()
    }

    /// Toggles controls visibility on tap.
    @objc private func onTapGestureTapped(_ gestureRecognizer: UIGestureRecognizer) {
        let badgeLocation = gestureRecognizer.location(in: transportBadgeButton)
        guard !transportBadgeButton.bounds.contains(badgeLocation) else { return }

        if !transportTooltipView.isHidden {
            hideTransportTooltip()
            return
        }
        toggleControlsVisibility()
    }

    /// Applies visibility changes with animations.
    private func applyControlsVisibility(_ visible: Bool) {
        isShowingControls = visible

        let alpha: CGFloat = visible ? 1.0 : 0.0

        if !visible {
            hideTransportTooltip(animated: false)
        }

        UIApplication.shared.setStatusBarHidden(!visible, with: .fade)

        UIView.animate(
            withDuration: 0.3,
            animations: { [weak self] in
                guard let self else { return }

                topView.alpha = alpha
                bottomView.alpha = alpha
                mainView.alpha = alpha
                transportBadgeButton.alpha = alpha
                mainMaskView.backgroundColor = .clear
                layoutIfNeeded()
            },
            completion: { [weak self] _ in
                guard let self else { return }

                if visible { autoFadeOutControlViewWithAnimation() }
            }
        )
    }

    private func updateTitleVisibility() {
        if videoType == .online {
            titleLabel.isHidden = mode == .default
        } else {
            titleLabel.isHidden = false
        }
    }

    private func rebuildRightAccessoryStack() {
        rightAccessoryStackView.arrangedSubviews.forEach { view in
            rightAccessoryStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        rightAccessoryButtons.removeAll()
        rightAccessoryStackView.isHidden = rightAccessoryItems.isEmpty

        rightAccessoryItems.forEach { item in
            let button = UIButton(type: .custom)
            button.accessibilityIdentifier = item.id
            button.imageView?.contentMode = .scaleAspectFit
            button.adjustsImageWhenHighlighted = true
            button.touchAreaInsets = UIEdgeInsets(inset: 12)
            button.addTarget(
                self,
                action: #selector(onRightAccessoryButtonTapped(_:)),
                for: .touchUpInside
            )

            configureRightAccessoryButton(button, with: item)
            rightAccessoryButtons[item.id] = button
            rightAccessoryStackView.addArrangedSubview(button)

            button.snp.makeConstraints {
                $0.width.height.equalTo(Layout.sideAccessoryButtonSize)
            }
        }
    }

    private func configureRightAccessoryButton(
        _ button: UIButton?,
        with item: SYPlayerControlAccessoryItem
    ) {
        guard let button else { return }

        button.setImage(item.image, for: .normal)
        button.setImage(item.selectedImage ?? item.image, for: .selected)
        button.setImage(item.disabledImage ?? item.image, for: .disabled)
        button.setImage(
            item.selectedImage ?? item.disabledImage ?? item.image,
            for: [.selected, .disabled]
        )
        button.isEnabled = item.isEnabled
        button.isSelected = item.isSelected
        button.accessibilityLabel = item.accessibilityLabel

        let colors = SYPlayerConfig.shared.colors
        let appearance = item.appearance
        let defaultTintColor = colors.controlsTintColor
        let tintColor: UIColor

        if !item.isEnabled {
            tintColor = appearance.disabledTintColor ?? defaultTintColor.withAlphaComponent(0.5)
        } else if item.isSelected {
            tintColor = appearance.selectedTintColor ?? appearance.tintColor ?? defaultTintColor
        } else {
            tintColor = appearance.tintColor ?? defaultTintColor
        }

        let backgroundColor: UIColor?
        if !item.isEnabled {
            backgroundColor = appearance.disabledBackgroundColor ?? appearance.backgroundColor
        } else if item.isSelected {
            backgroundColor = appearance.selectedBackgroundColor ?? appearance.backgroundColor
        } else {
            backgroundColor = appearance.backgroundColor
        }

        let borderColor: UIColor?
        if !item.isEnabled {
            borderColor = appearance.disabledBorderColor ?? appearance.borderColor
        } else if item.isSelected {
            borderColor = appearance.selectedBorderColor ?? appearance.borderColor
        } else {
            borderColor = appearance.borderColor
        }

        button.tintColor = tintColor
        button.backgroundColor = backgroundColor ?? .clear
        button.layer.cornerRadius = appearance.cornerRadius
        button.layer.borderWidth = appearance.borderWidth
        button.layer.borderColor = borderColor?.cgColor
    }
}

// MARK: - Orientation helper
extension SYPlayerControlView {
    /// Updates UI based on device orientation changes.
    private func handleOrientationChange(_ orientation: UIDeviceOrientation) {
        switch orientation {
        case .portrait:
            updateUI(isPortrait: true)
        case .landscapeLeft, .landscapeRight:
            updateUI(isPortrait: false)
        default: break
        }
    }
}

// MARK: - UICollectionView Delegates
extension SYPlayerControlView: UICollectionViewDelegate {}

extension SYPlayerControlView: UICollectionViewDataSource {
    /// Returns the number of period items.
    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        4
    }

    /// Dequeues and configures a period cell.
    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {

        let cell = collectionView.dequeueReusableCell(
            withClass: VideoPeriodPickerCell.self,
            for: indexPath
        )
        cell.setTitle("period.title")
        return cell
    }
}

extension SYPlayerControlView: UICollectionViewDelegateFlowLayout {
    /// Returns the size for a period item cell.
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(width: 96, height: 24)
    }

    /// Returns horizontal spacing between period items.
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
        18
    }

    /// Returns inter-item spacing within a row.
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
        18
    }

    /// Returns section insets for the period list.
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        insetForSectionAt section: Int
    ) -> UIEdgeInsets {
        UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    }
}

// MARK: - SY Simple Video Range Slider Delegate
extension SYPlayerControlView: SYVideoRangeSliderDelegate {
    /// Receives range slider changes (currently unused).
    func didChangeDate(
        videoRangeSlider: SYVideoRangeSlider,
        isReceivingGesture: Bool,
        startDate: Date,
        endDate: Date,
        isLowerBoundReached: Bool,
        isUpperBoundReached: Bool,
        screenshotPolicy: SYVideoRangeSlider.ScreenshotPolicy
    ) {
        // сюда позже привяжем seek по времени архива
    }
}
