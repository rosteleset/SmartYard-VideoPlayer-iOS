import UIKit

public struct SYPlayerFonts {
    public var titleFont: UIFont
    public var speedButtonFont: UIFont
    public var timeLabelFont: UIFont
    public var periodPickerFont: UIFont
    public var periodPickerSelectedFont: UIFont

    public init() {
        self.titleFont = UIFont.systemFont(ofSize: 24, weight: .semibold)
        self.speedButtonFont = UIFont.systemFont(ofSize: 20, weight: .regular)
        self.timeLabelFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
        self.periodPickerFont = UIFont.systemFont(ofSize: 14, weight: .regular)
        self.periodPickerSelectedFont = UIFont.systemFont(ofSize: 14, weight: .bold)
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
