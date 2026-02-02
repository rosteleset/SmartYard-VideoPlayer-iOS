import UIKit

public struct SYPlayerColors {
    public var borderColor: UIColor
    public var accentColor: UIColor
    public var textColor: UIColor
    public var playerBackgroundColor: UIColor
    public var controlsTextColor: UIColor
    public var controlsTintColor: UIColor
    public var controlsMaskVisibleColor: UIColor
    public var thumbnailsBackgroundColor: UIColor

    public init(
        borderColor: UIColor = UIColor(red: 1.0, green: 227.0 / 255.0, blue: 142.0 / 255.0, alpha: 1.0),
        accentColor: UIColor = UIColor(white: 0.95, alpha: 1.0),
        textColor: UIColor = UIColor(white: 0.1, alpha: 0.85),
        playerBackgroundColor: UIColor = .black,
        controlsTextColor: UIColor = .white,
        controlsTintColor: UIColor = .white,
        controlsMaskVisibleColor: UIColor = UIColor.black.withAlphaComponent(0.4),
        thumbnailsBackgroundColor: UIColor = UIColor.black.withAlphaComponent(0.5)
    ) {
        self.borderColor = borderColor
        self.accentColor = accentColor
        self.textColor = textColor
        self.playerBackgroundColor = playerBackgroundColor
        self.controlsTextColor = controlsTextColor
        self.controlsTintColor = controlsTintColor
        self.controlsMaskVisibleColor = controlsMaskVisibleColor
        self.thumbnailsBackgroundColor = thumbnailsBackgroundColor
    }
}
