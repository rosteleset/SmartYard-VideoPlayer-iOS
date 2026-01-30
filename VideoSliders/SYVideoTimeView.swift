import UIKit

final class SYVideoTimeView: UIView {
    let timeLabel = UILabel()
    let backgroundView = UIView()
    
    /// Returns the size needed to display the time label.
    override var intrinsicContentSize: CGSize {
        let height: CGFloat = 16
        let labelWidth = timeLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: height)).width
        let width: CGFloat = 4 * 2 + labelWidth
        
        return CGSize(width: width, height: height)
    }
    
    /// Creates a time view with a preferred size.
    init(size: CGSize) {
        let frame = CGRect(
            x: 0,
            y: -size.height - 7,
            width: size.width,
            height: size.height
        )
        
        super.init(frame: frame)
        // TODO: - посмотреть почему тут цвет меняется два раза
        // Add Background View
        backgroundView.frame = bounds
        backgroundView.backgroundColor = .yellow
        addSubview(backgroundView)
        
        backgroundView.backgroundColor = UIColor.SmartYard.secondBackgroundColor
        backgroundView.layerCornerRadius = 3
        
        // Add time label
        timeLabel.textAlignment = .center
        timeLabel.textColor = UIColor.SmartYard.semiBlack
        timeLabel.font = UIFont.SourceSansPro.semibold(size: 12)
        addSubview(timeLabel)
    }
    
    /// Lays out background and label frames.
    override func layoutSubviews() {
        super.layoutSubviews()

        backgroundView.frame = bounds
        
        timeLabel.frame = CGRect(
            x: 4,
            y: 0,
            width: frame.width - 4 * 2,
            height: frame.height
        )
    }
    
    @available(*, unavailable)
    /// Storyboard initializer is unavailable.
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}
