import UIKit

final class SYVideoEndIndicator: UIView {

    let imageView = UIImageView()

    /// Creates the end indicator with a frame.
    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = true

        imageView.frame = bounds
        imageView.image = SYPlayerConfig.shared.icon(.rangeSliderEnd)
        imageView.contentMode = .scaleToFill

        addSubview(imageView)
    }

    @available(*, unavailable)
    /// Storyboard initializer is unavailable.
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays out the indicator image to fill bounds.
    override func layoutSubviews() {
        super.layoutSubviews()

        imageView.frame = bounds
    }

    /// Expands hit testing area for easier dragging.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let extendedBounds = CGRect(
            x: 0,
            y: 0,
            width: frame.size.width + 15,
            height: frame.size.height
        )

        return extendedBounds.contains(point)
    }

}
