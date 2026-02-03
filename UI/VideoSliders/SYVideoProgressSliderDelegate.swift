//
//  SYSimpleVideoProgressSlider.swift
//  SmartYard
//
//  Created by admin on 08.06.2020.
//  Copyright © 2021 LanTa. All rights reserved.
//

import UIKit
import AVKit

// swiftlint:disable all

@objc protocol SYVideoProgressSliderDelegate: AnyObject {

    /// Notifies when the indicator position changes during a gesture.
    func indicatorDidChangePosition(
        videoRangeSlider: SYVideoProgressSlider,
        isReceivingGesture: Bool,
        position: Float64
    )

    /// Optional callback when gestures begin.
    @objc optional func sliderGesturesBegan()
    /// Optional callback when gestures end.
    @objc optional func sliderGesturesEnded()

}

final class SYVideoProgressSlider: UIView, UIGestureRecognizerDelegate {

    weak var delegate: SYVideoProgressSliderDelegate? = nil

    private let progressTimeView = SYVideoTimeView(size: .zero)
    private let progressIndicator = SYVideoProgressIndicator()

    private let thumbnailsContainer = UIView()
    private var thumbnailViews = [(UIImageView, UIActivityIndicatorView)]()

    private var duration: Float64 = 0

    private var progressPercentage: CGFloat = 0         // Represented in percentage

    public var isReceivingGesture: Bool = false

    private var relativeStartDate: Date?
    private var referenceCalendar = SYPlayerConfig.shared.referenceCalendar

    /// Initializes after loading from nib.
    override func awakeFromNib() {
        super.awakeFromNib()
        self.setup()
    }

    /// Creates the slider with a frame.
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setup()
    }

    /// Creates the slider from a storyboard or xib.
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    /// Sets up subviews and gesture recognizers.
    private func setup(){
        backgroundColor = .clear

        let colors = SYPlayerConfig.shared.colors

        layer.cornerRadius = 3
        layer.borderColor = colors.borderColor.cgColor
        layer.borderWidth = 1

        isUserInteractionEnabled = true

        // Setup Progress Indicator

        let progressDrag = UIPanGestureRecognizer(
            target:self,
            action: #selector(progressDragged(recognizer:))
        )

        progressIndicator.addGestureRecognizer(progressDrag)
        addSubview(progressIndicator)

        // Setup time labels

        addSubview(progressTimeView)

        // Setup previews

        thumbnailsContainer.backgroundColor = colors.thumbnailsBackgroundColor
        addSubview(thumbnailsContainer)
        sendSubviewToBack(thumbnailsContainer)
        thumbnailsContainer.layer.cornerRadius = 3

        let thumbnailViews = [
            (UIImageView(), UIActivityIndicatorView()),
            (UIImageView(), UIActivityIndicatorView()),
            (UIImageView(), UIActivityIndicatorView()),
            (UIImageView(), UIActivityIndicatorView()),
            (UIImageView(), UIActivityIndicatorView())
        ]

        self.thumbnailViews = thumbnailViews

        thumbnailViews.forEach { imageView, activityIndicator in
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true

            thumbnailsContainer.addSubview(imageView)
            thumbnailsContainer.sendSubviewToBack(imageView)

            activityIndicator.color = colors.accentColor

            thumbnailsContainer.addSubview(activityIndicator)
        }
    }

    /// Updates the indicator based on the current playback time.
    func setCurrentTime(_ time: CMTime) {
        guard !isReceivingGesture, time.seconds <= duration else {
            return
        }

        self.progressPercentage = self.valueFromSeconds(seconds: Float(time.seconds))

        layoutSubviews()
    }

    /// Sets the total duration for the slider.
    func setVideoDuration(_ duration: Double) {
        self.duration = duration

        self.layoutSubviews()
    }

    /// Sets a thumbnail image at a given index.
    func setThumbnailImage(_ image: UIImage?, atIndex index: Int) {
        guard let (imageView, activityIndicator) = thumbnailViews[safe: index] else {
            return
        }

        imageView.image = image
        activityIndicator.stopAnimating()
    }

    /// Clears all thumbnail images.
    func resetThumbnailImages() {
        thumbnailViews.forEach { imageView, _ in
            imageView.image = nil
        }
    }

    /// Shows or hides thumbnail activity indicators.
    func setActivityIndicatorsHidden(_ isHidden: Bool) {
        thumbnailViews.forEach { _, activityIndicator in
            isHidden ? activityIndicator.stopAnimating() : activityIndicator.startAnimating()
        }
    }

    /// Sets the relative start date used for time labels.
    func setRelativeStartDate(_ date: Date?) {
        relativeStartDate = date

        layoutSubviews()
    }

    /// Sets the calendar used for time formatting.
    func setReferenceCalendar(_ calendar: Calendar) {
        referenceCalendar = calendar

        layoutSubviews()
    }

    // MARK: - Private functions

    /// Handles dragging of the progress indicator.
    @objc func progressDragged(recognizer: UIPanGestureRecognizer) {
        guard duration > 0 else {
            return
        }

        updateGestureStatus(recognizer: recognizer)

        let translation = recognizer.translation(in: self)

        let positionLimitStart  = positionFromValue(value: 0)
        let positionLimitEnd    = positionFromValue(value: 100)

        var position = positionFromValue(value: self.progressPercentage)
        position = position + translation.x

        if position < positionLimitStart {
            position = positionLimitStart
        }

        if position > positionLimitEnd {
            position = positionLimitEnd
        }

        recognizer.setTranslation(CGPoint.zero, in: self)

        progressIndicator.center = CGPoint(x: position , y: progressIndicator.center.y)

        let percentage = valueFromPosition(position: progressIndicator.center.x)

        let progressSeconds = negateConversionLosses(secondsFromValue(value: progressPercentage))

        self.delegate?.indicatorDidChangePosition(
            videoRangeSlider: self,
            isReceivingGesture: isReceivingGesture,
            position: progressSeconds
        )

        self.progressPercentage = percentage

        layoutSubviews()
    }

    // MARK: - Drag Functions Helpers
    /// Converts percentage value to x-position in the view.
    private func positionFromValue(value: CGFloat) -> CGFloat {
        let startPosition = progressIndicator.bounds.width / 2
        let endPosition = frame.size.width - progressIndicator.bounds.width / 2
        let neededPosition = startPosition + value * (endPosition - startPosition) / 100

        return neededPosition
    }

    /// Converts x-position in the view to a percentage value.
    private func valueFromPosition(position: CGFloat) -> CGFloat {
        let startPosition = progressIndicator.bounds.width / 2
        let endPosition = frame.size.width - progressIndicator.bounds.width / 2

        return (position - startPosition) * 100 / (endPosition - startPosition)
    }

    /// Converts a percentage value to seconds.
    private func secondsFromValue(value: CGFloat) -> Float64 {
        return duration * Float64((value / 100))
    }

    /// Converts seconds to a percentage value.
    private func valueFromSeconds(seconds: Float) -> CGFloat {
        guard duration > 0 else {
            return 0
        }

        return CGFloat(seconds * 100) / CGFloat(duration)
    }

    /// Updates gesture state and notifies the delegate.
    private func updateGestureStatus(recognizer: UIGestureRecognizer) {
        if recognizer.state == .began {

            self.isReceivingGesture = true
            SYPlayerConfig.shared.log("ProgressSlider gesture began", level: .debug)
            self.delegate?.sliderGesturesBegan?()

        } else if recognizer.state == .ended {

            self.isReceivingGesture = false
            SYPlayerConfig.shared.log("ProgressSlider gesture ended", level: .debug)
            self.delegate?.sliderGesturesEnded?()
        }
    }

    // MARK: -

    /// Lays out the indicator, time label, and thumbnails.
    override func layoutSubviews() {
        super.layoutSubviews()

        progressTimeView.timeLabel.text = getProgressTextValue(percentage: progressPercentage)

        let progressPosition = positionFromValue(value: self.progressPercentage)

        progressIndicator.frame = CGRect(
            x: progressPosition - 1.5,
            y: 1,
            width: 3,
            height: self.frame.size.height - 2
        )

        progressIndicator.center = CGPoint(x: progressPosition, y: progressIndicator.center.y)

        UIView.animate(withDuration: 0.05) { [weak self] in
            guard let self = self else {
                return
            }

            let timeViewWidth = self.progressTimeView.intrinsicContentSize.width
            let timeViewHeight = self.progressTimeView.intrinsicContentSize.height

            let preferredX = self.progressIndicator.center.x - timeViewWidth / 2
            let minPossibleX: CGFloat = 0
            let maxPossibleX = self.bounds.width - timeViewWidth
            let resultingX = min(max(minPossibleX, preferredX), maxPossibleX)

            self.progressTimeView.frame = CGRect(
                x: resultingX,
                y: -timeViewHeight - 7,
                width: timeViewWidth,
                height: timeViewHeight
            )
        }

        // Update fake thumbnails frames

        thumbnailsContainer.frame = bounds

        guard !thumbnailViews.isEmpty else {
            return
        }

        let imageWidth = bounds.width / CGFloat(thumbnailViews.count)

        thumbnailViews.enumerated().forEach { offset, element in
            let (imageView, activityIndicator) = element

            imageView.frame = CGRect(
                x: CGFloat(offset) * imageWidth,
                y: 0,
                width: imageWidth,
                height: bounds.height
            )

            activityIndicator.center = imageView.center
        }
    }

    /// Returns formatted progress text for a given percentage.
    private func getProgressTextValue(percentage: CGFloat) -> String {
        let progressSeconds = negateConversionLosses(secondsFromValue(value: percentage))

        guard let relativeStartDate = relativeStartDate else {
            let hours:Int = Int(progressSeconds.truncatingRemainder(dividingBy: 86400) / 3600)
            let minutes:Int = Int(progressSeconds.truncatingRemainder(dividingBy: 3600) / 60)
            let seconds:Int = Int(progressSeconds.truncatingRemainder(dividingBy: 60))

            if hours > 0 {
                return String(format: "%02i:%02i:%02i", hours, minutes, seconds)
            } else {
                return String(format: "%02i:%02i", minutes, seconds)
            }
        }

        let progressIndicatorDate = relativeStartDate.addingTimeInterval(progressSeconds)

        let formatter = DateFormatter()

        formatter.timeZone = referenceCalendar.timeZone
        formatter.dateFormat = "HH:mm:ss"

        return formatter.string(from: progressIndicatorDate)
    }

    /// Avoids minor precision loss for near-integer values.
    private func negateConversionLosses(_ value: Float64) -> Float64 {
        if abs(value.rounded() - value) < 0.00001 {
            return value.rounded()
        } else {
            return value
        }
    }

    /// Expands hit testing area for easier interaction.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let extendedBounds = CGRect(
            x: -15,
            y: 0,
            width: self.frame.size.width + 30,
            height: self.frame.size.height
        )

        return extendedBounds.contains(point)
    }

}

// swiftlint:enable all
