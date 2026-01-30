import UIKit

public enum SYPlayerIcon {
    case fullscreenEnter
    case fullscreenExit
    case play
    case pause
    case soundOn
    case soundOff
    case rangeSliderStart
    case rangeSliderEnd
    case rangeSliderProgress
}

public struct SYPlayerIcons {
    public var fullscreenEnter: UIImage?
    public var fullscreenExit: UIImage?
    public var play: UIImage?
    public var pause: UIImage?
    public var soundOn: UIImage?
    public var soundOff: UIImage?
    public var rangeSliderStart: UIImage?
    public var rangeSliderEnd: UIImage?
    public var rangeSliderProgress: UIImage?

    public init(
        fullscreenEnter: UIImage? = nil,
        fullscreenExit: UIImage? = nil,
        play: UIImage? = nil,
        pause: UIImage? = nil,
        soundOn: UIImage? = nil,
        soundOff: UIImage? = nil,
        rangeSliderStart: UIImage? = nil,
        rangeSliderEnd: UIImage? = nil,
        rangeSliderProgress: UIImage? = nil
    ) {
        self.fullscreenEnter = fullscreenEnter
        self.fullscreenExit = fullscreenExit
        self.play = play
        self.pause = pause
        self.soundOn = soundOn
        self.soundOff = soundOff
        self.rangeSliderStart = rangeSliderStart
        self.rangeSliderEnd = rangeSliderEnd
        self.rangeSliderProgress = rangeSliderProgress
    }

    /// Returns the custom image for an icon, if provided.
    func image(for icon: SYPlayerIcon) -> UIImage? {
        switch icon {
        case .fullscreenEnter: return fullscreenEnter
        case .fullscreenExit: return fullscreenExit
        case .play: return play
        case .pause: return pause
        case .soundOn: return soundOn
        case .soundOff: return soundOff
        case .rangeSliderStart: return rangeSliderStart
        case .rangeSliderEnd: return rangeSliderEnd
        case .rangeSliderProgress: return rangeSliderProgress
        }
    }
}

enum SYPlayerDefaultIcons {
    /// Returns the bundled default image for an icon.
    static func image(for icon: SYPlayerIcon) -> UIImage? {
        switch icon {
        case .fullscreenEnter:
            return UIImage(named: "Fulscreen", in: .syPlayer, compatibleWith: nil)
        case .fullscreenExit:
            return UIImage(named: "Minimize", in: .syPlayer, compatibleWith: nil)
        case .play:
            return UIImage(named: "Play", in: .syPlayer, compatibleWith: nil)
        case .pause:
            return UIImage(named: "Pause", in: .syPlayer, compatibleWith: nil)
        case .soundOn:
            return UIImage(named: "SoundOn", in: .syPlayer, compatibleWith: nil)
        case .soundOff:
            return UIImage(named: "SoundOff", in: .syPlayer, compatibleWith: nil)
        case .rangeSliderStart:
            return UIImage(named: "RangeSliderStart", in: .syPlayer, compatibleWith: nil)
        case .rangeSliderEnd:
            return UIImage(named: "RangeSliderEnd", in: .syPlayer, compatibleWith: nil)
        case .rangeSliderProgress:
            return UIImage(named: "RangeSliderProgress", in: .syPlayer, compatibleWith: nil)
        }
    }
}

public extension SYPlayerConfig {
    /// Returns a custom icon if set, otherwise the bundled default.
    public func icon(_ icon: SYPlayerIcon) -> UIImage? {
        icons.image(for: icon) ?? SYPlayerDefaultIcons.image(for: icon)
    }
}
