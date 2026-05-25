//
//  SYPlayerControlAccessoryItem.swift
//  SmartYardVideoPlayer
//
//  Created by Александр Попов on 25.05.2026.
//

import UIKit

public struct SYPlayerControlAccessoryAppearance {
    public var tintColor: UIColor?
    public var selectedTintColor: UIColor?
    public var disabledTintColor: UIColor?
    public var backgroundColor: UIColor?
    public var selectedBackgroundColor: UIColor?
    public var disabledBackgroundColor: UIColor?
    public var borderColor: UIColor?
    public var selectedBorderColor: UIColor?
    public var disabledBorderColor: UIColor?
    public var borderWidth: CGFloat
    public var cornerRadius: CGFloat

    public init(
        tintColor: UIColor? = nil,
        selectedTintColor: UIColor? = nil,
        disabledTintColor: UIColor? = nil,
        backgroundColor: UIColor? = nil,
        selectedBackgroundColor: UIColor? = nil,
        disabledBackgroundColor: UIColor? = nil,
        borderColor: UIColor? = nil,
        selectedBorderColor: UIColor? = nil,
        disabledBorderColor: UIColor? = nil,
        borderWidth: CGFloat = 0,
        cornerRadius: CGFloat = 8
    ) {
        self.tintColor = tintColor
        self.selectedTintColor = selectedTintColor
        self.disabledTintColor = disabledTintColor
        self.backgroundColor = backgroundColor
        self.selectedBackgroundColor = selectedBackgroundColor
        self.disabledBackgroundColor = disabledBackgroundColor
        self.borderColor = borderColor
        self.selectedBorderColor = selectedBorderColor
        self.disabledBorderColor = disabledBorderColor
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
    }
}

public struct SYPlayerControlAccessoryItem {
    public let id: String
    public var image: UIImage?
    public var selectedImage: UIImage?
    public var disabledImage: UIImage?
    public var isEnabled: Bool
    public var isSelected: Bool
    public var accessibilityLabel: String?
    public var appearance: SYPlayerControlAccessoryAppearance
    public var action: (() -> Void)?

    public init(
        id: String,
        image: UIImage?,
        selectedImage: UIImage? = nil,
        disabledImage: UIImage? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        accessibilityLabel: String? = nil,
        appearance: SYPlayerControlAccessoryAppearance = SYPlayerControlAccessoryAppearance(),
        action: (() -> Void)? = nil
    ) {
        self.id = id
        self.image = image
        self.selectedImage = selectedImage
        self.disabledImage = disabledImage
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.accessibilityLabel = accessibilityLabel
        self.appearance = appearance
        self.action = action
    }
}
