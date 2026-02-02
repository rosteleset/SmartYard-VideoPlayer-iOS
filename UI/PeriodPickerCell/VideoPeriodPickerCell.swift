//
//  VideoPeriodPickerCell.swift
//  SmartYard
//
//  Created by admin on 02.06.2020.
//  Copyright © 2021 LanTa. All rights reserved.
//

import UIKit

final class VideoPeriodPickerCell: UICollectionViewCell {
    
    @IBOutlet private weak var titleLabel: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()
        
        titleLabel.text = nil
        layerBorderColor = SYPlayerConfig.shared.colors.periodPickerBorderColor
        layerCornerRadius = 3
        
        updateSelectedState(false)
    }
    
    override var isSelected: Bool {
        didSet {
            updateSelectedState(isSelected)
        }
    }
    
    func setTitle(_ title: String) {
        titleLabel.text = title
    }
    
    private func updateSelectedState(_ newState: Bool) {
        let fonts = SYPlayerConfig.shared.fonts
        titleLabel.font = newState ? fonts.periodPickerSelectedFont : fonts.periodPickerFont
        
        layerBorderWidth = newState ? 1 : 0
    }

}
