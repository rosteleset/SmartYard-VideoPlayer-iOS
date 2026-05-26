//
//  SYPlayerResource.swift
//  SmartYard
//
//  Created by Александр Попов on 07.08.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import Foundation
import AVFoundation

public enum SYPlayerResourceSource {
    case hls(URL)
    case whep(endpointURL: URL, iceServers: [String])
}

public struct SYPlayerResource {
    public let videos: [SYPlayerResourceVideo]
    public let previewImage: URL?
    public let name: String
    public let videoType: SYPlayedVideoType
    public let hasSound: Bool

    /// Creates a resource with multiple video variants.
    public init(
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
    public init(
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

public final class SYPlayerResourceVideo {
    public let url: URL
    public let source: SYPlayerResourceSource
    public var options: [String: Any]?

    /// Builds an AVURLAsset using the current player configuration.
    public var avURLAsset: AVURLAsset {
        SYPlayerConfig.shared.makeAsset(url: url, options: options)
    }

    /// Creates a video wrapper with the given URL and optional AVURLAsset options.
    public init(url: URL, options: [String: Any]? = nil) {
        self.url = url
        self.source = .hls(url)
        self.options = options
    }

    public init(whepEndpointURL: URL, iceServers: [String] = []) {
        self.url = whepEndpointURL
        self.source = .whep(endpointURL: whepEndpointURL, iceServers: iceServers)
        self.options = nil
    }
}
