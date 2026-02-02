import UIKit

public struct SYPlayerFonts {
    public var titleFont: UIFont
    public var speedButtonFont: UIFont
    public var timeLabelFont: UIFont
    public var periodPickerFont: UIFont
    public var periodPickerSelectedFont: UIFont

    public init() {
        self.titleFont = UIFont.SourceSansPro.semibold(size: 24)
        self.speedButtonFont = UIFont.SourceSansPro.regular(size: 20)
        self.timeLabelFont = UIFont.SourceSansPro.semibold(size: 12)
        self.periodPickerFont = UIFont.SourceSansPro.regular(size: 14)
        self.periodPickerSelectedFont = UIFont.SourceSansPro.bold(size: 14)
    }

    public init(
        titleFont: UIFont,
        speedButtonFont: UIFont,
        timeLabelFont: UIFont,
        periodPickerFont: UIFont,
        periodPickerSelectedFont: UIFont
    ) {
        self.titleFont = titleFont
        self.speedButtonFont = speedButtonFont
        self.timeLabelFont = timeLabelFont
        self.periodPickerFont = periodPickerFont
        self.periodPickerSelectedFont = periodPickerSelectedFont
    }
}
