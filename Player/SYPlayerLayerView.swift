//
//  SYPlayerLayerView.swift
//  SmartYard
//
//  Created by Александр Попов on 08.08.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import UIKit
import AVFoundation

final class SYPlayerLayerView: UIView {

    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet { playerLayer.videoGravity = videoGravity }
    }

    var aspectRatio: SYPlayerAspectRatio = .default {
        didSet { setNeedsLayout() }
    }

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    /// Creates the layer view with a frame.
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    /// Creates the layer view from a storyboard or xib.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// Configures the underlying AVPlayerLayer.
    private func setup() {
        // Используем layerClass => self.layer уже AVPlayerLayer
        playerLayer.videoGravity = videoGravity
    }

    /// Attaches an AVPlayer to the layer.
    func attach(player: AVPlayer?) {
        SYPlayerConfig.shared.log("LayerView attach player", level: .debug)
        playerLayer.player = player
    }

    /// Detaches any currently attached player.
    func detachPlayer() {
        SYPlayerConfig.shared.log("LayerView detach player", level: .debug)
        playerLayer.player = nil
    }

    /// Lays out the player layer based on the configured aspect ratio.
    override func layoutSubviews() {
        super.layoutSubviews()
        // layerClass stretches itself, but if we want a custom frame, we do it through a mask/container.
        // Here, we will leave simple, safe logic: default — bounds.
        // If you need 16:9/4:3 "force cropping", it is better to use a container/clip.

        switch aspectRatio {
        case .default:
            layer.frame = bounds

        case .sixteen2nine:
            let h = bounds.width * 9.0 / 16.0
            layer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)

        case .four2three:
            let w = bounds.height * 4.0 / 3.0
            layer.frame = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        }
    }
}
