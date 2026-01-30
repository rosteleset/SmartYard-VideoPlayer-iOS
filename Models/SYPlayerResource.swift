//
//  SYPlayerResource.swift
//  SmartYard
//
//  Created by Александр Попов on 07.08.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import Foundation
import AVFoundation

struct SYPlayerResource {
    let videos: [SYPlayerResourceVideo]
    let previewImage: URL?
    let name: String
    let videoType: SYPlayedVideoType
    let hasSound: Bool

    /// Creates a resource with multiple video variants.
    init(
        videos: [SYPlayerResourceVideo],
        previewImage: URL? = nil,
        name: String = "",
        videoType: SYPlayedVideoType = SYPlayerConfig.shared.videoType,
        hasSound: Bool = true
    ) {
        self.videos = videos
        self.previewImage = previewImage
        self.name = name
        self.videoType = videoType
        self.hasSound = hasSound
    }

    /// Creates a resource with a single video URL.
    init(
        url: URL,
        previewImage: URL? = nil,
        name: String = "",
        videoType: SYPlayedVideoType = SYPlayerConfig.shared.videoType,
        hasSound: Bool = true
    ) {
        self.init(
            videos: [SYPlayerResourceVideo(url: url)],
            previewImage: previewImage,
            name: name,
            videoType: videoType,
            hasSound: hasSound
        )
    }

    /// Returns the video at the given index if it exists.
    func video(at index: Int) -> SYPlayerResourceVideo? {
        guard videos.indices.contains(index) else { return nil }
        return videos[index]
    }
}

final class SYPlayerResourceVideo {
    let url: URL
    var options: [String: Any]?

    /// Builds an AVURLAsset using the current player configuration.
    var avURLAsset: AVURLAsset {
        SYPlayerConfig.shared.makeAsset(url: url, options: options)
    }

    /// Creates a video wrapper with the given URL and optional AVURLAsset options.
    init(url: URL, options: [String: Any]? = nil) {
        self.url = url
        self.options = options
    }
}
