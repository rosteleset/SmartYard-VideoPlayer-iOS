# SmartYardVideoPlayer

UIKit-based video player UI and playback components for iOS.

## Features
- Archive and online playback
- HLS prefetching
- Caching
- Customizable controls

## Requirements
- iOS 13.0+
- Swift 6.0

## Installation
CocoaPods:

```ruby
pod 'SmartYardVideoPlayer',
  :git => 'https://github.com/rosteleset/SmartYard-VideoPlayer-iOS.git',
  :tag => '0.1.2'
```

## Usage
```swift
import SmartYardVideoPlayer
```

## Customization
You can override colors and fonts via `SYPlayerConfig.shared` before using the player.

### Colors
```swift
var colors = SYPlayerColors()
colors.borderColor = UIColor(red: 1.0, green: 227.0/255.0, blue: 142.0/255.0, alpha: 1.0)
colors.accentColor = UIColor(white: 0.95, alpha: 1.0)
colors.textColor = UIColor(white: 0.1, alpha: 0.85)
colors.playerBackgroundColor = .black
colors.controlsTextColor = .white
colors.controlsTintColor = .white
colors.controlsMaskVisibleColor = UIColor.black.withAlphaComponent(0.4)
colors.thumbnailsBackgroundColor = UIColor.black.withAlphaComponent(0.5)
colors.periodPickerBorderColor = UIColor(white: 0.7, alpha: 1.0)
SYPlayerConfig.shared.colors = colors
```

### Fonts
```swift
var fonts = SYPlayerFonts()
fonts.titleFont = .systemFont(ofSize: 22, weight: .semibold)
fonts.speedButtonFont = .systemFont(ofSize: 20, weight: .regular)
fonts.timeLabelFont = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
fonts.periodPickerFont = .systemFont(ofSize: 14, weight: .regular)
fonts.periodPickerSelectedFont = .systemFont(ofSize: 14, weight: .bold)
SYPlayerConfig.shared.fonts = fonts
```

See the project documentation and source for integration details.

## License
GPL-3.0
