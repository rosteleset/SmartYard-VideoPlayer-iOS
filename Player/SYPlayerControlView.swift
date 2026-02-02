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

    private var hasSound = true

    private var playerLastState: SYPlayerState = .idle

    // MARK: - UI Elements
    private let mainMaskView = UIView()
    private let mainView = UIView()
    private let topView = UIView()
    private let bottomView = UIView()

    private let imageView = UIImageView()

    private let titleLabel = UILabel()
    private let fullscreenButton = UIButton(type: .custom)
    private let soundToggleButton = UIButton(type: .custom)

    private let videoLoadingAnimationView = LottieAnimationView()

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
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Prepares UI for a resource and selected index.
    func prepareUI(for resource: SYPlayerResource, selectedIndex index: Int) {
        SYPlayerConfig.shared.log(
            "ControlView prepareUI (name: \(resource.name), index: \(index))",
            level: .debug
        )
        self.resource = resource
        self.selectedIndex = index
        titleLabel.text = resource.name
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

                switch state {
                case .idle:
                    showLoader()
                    setControlsVisible(true)

                case .preparing, .buffering:
                    showLoader()
                    setControlsVisible(true)

                case .ready, .playing:
                    hideLoader()
                    autoFadeOutControlViewWithAnimation()

                case .paused:
                    hideLoader()
                    setControlsVisible(true)

                case .ended:
                    setControlsVisible(true)

                case .error:
                    hideLoader()
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
    func showImageView(url: URL?) {
        SYPlayerConfig.shared.log(
            "ControlView show preview (hasURL: \(url != nil))",
            level: .debug
        )
        guard let url else {
            imageView.image = nil
            hideLoader()
            return
        }

        imageView.isHidden = false
        imageView.kf.setImage(with: url) { [weak self] _ in
            self?.hideLoader()
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

    /// Cancels any delayed UI work.
    func prepareToDealloc() {
        SYPlayerConfig.shared.log("ControlView prepareToDealloc", level: .debug)
        delayItem?.cancel()
        delayItem = nil
    }

    // MARK: - Loader

    /// Shows the loading animation.
    private func showLoader() {
        videoLoadingAnimationView.isHidden = false
        videoLoadingAnimationView.play()
    }

    /// Hides the loading animation.
    private func hideLoader() {
        videoLoadingAnimationView.isHidden = true
        videoLoadingAnimationView.stop()
    }

    // MARK: - Auto hide

    /// Schedules auto-hide for controls if playing.
    private func autoFadeOutControlViewWithAnimation() {
        cancelAutoFadeOutAnimation()

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

        let animation = LottieAnimation.named("LoaderAnimation", bundle: .syPlayer)
        videoLoadingAnimationView.animation = animation
        videoLoadingAnimationView.loopMode = .loop
        videoLoadingAnimationView.backgroundBehavior = .pauseAndRestore

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

        progressSlider.setReferenceCalendar(.serverCalendar)
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

        mainView.addSubview(topView)
        mainView.addSubview(bottomView)
        mainView.insertSubview(imageView, at: 0)

        topView.addSubview(fullscreenButton)
        topView.addSubview(soundToggleButton)
        topView.addSubview(titleLabel)

        mainMaskView.snp.makeConstraints { $0.directionalEdges.equalToSuperview() }
        mainView.snp.makeConstraints { $0.directionalEdges.equalTo(safeAreaLayoutGuide) }
        imageView.snp.makeConstraints { $0.directionalEdges.equalTo(mainView) }

        topView.snp.makeConstraints {
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

        titleLabel.snp.makeConstraints {
            $0.top.equalTo(topView.snp.bottom).offset(26)
            $0.left.right.equalToSuperview().inset(26)
            $0.height.equalTo(44)
        }

        videoLoadingAnimationView.snp.makeConstraints {
            $0.centerX.centerY.equalToSuperview()
            $0.height.width.equalTo(80)
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
        fullscreenButton.isSelected = !isPortrait

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

    /// Toggles controls visibility on tap.
    @objc private func onTapGestureTapped(_: UIGestureRecognizer) {
        if case .ended = playerLastState { return }
        setControlsVisible(!isShowingControls)
    }

    /// Applies visibility changes with animations.
    private func applyControlsVisibility(_ visible: Bool) {
        isShowingControls = visible

        let alpha: CGFloat = visible ? 1.0 : 0.0
        let colors = SYPlayerConfig.shared.colors

        UIApplication.shared.setStatusBarHidden(!visible, with: .fade)

        UIView.animate(
            withDuration: 0.3,
            animations: { [weak self] in
                guard let self else { return }

                topView.alpha = alpha
                bottomView.alpha = alpha
                mainView.alpha = alpha
                mainMaskView.backgroundColor = visible ? colors.controlsMaskVisibleColor : .clear
                layoutIfNeeded()
            },
            completion: { [weak self] _ in
                guard let self else { return }

                if visible { autoFadeOutControlViewWithAnimation() }
            }
        )
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
