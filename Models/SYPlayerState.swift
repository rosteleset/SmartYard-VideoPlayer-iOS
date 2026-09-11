//
//  SYPlayerState.swift
//  SmartYard
//
//  Created by Александр Попов on 26.07.2024.
//  Copyright © 2024 Sesameware. All rights reserved.
//

import Foundation

enum SYPlayerTransport: Equatable {
    case webRTC
    case hls
    case lowLatencyHLS

    var title: String {
        switch self {
        case .webRTC: return "WebRTC"
        case .hls: return "HLS"
        case .lowLatencyHLS: return "LL-HLS"
        }
    }
}

enum SYPlayerTransportState: Equatable {
    case hidden
    case connecting(SYPlayerTransport)
    case playing(SYPlayerTransport, announceConnection: Bool)
    case switching(from: SYPlayerTransport, to: SYPlayerTransport)
    case failed(SYPlayerTransport)

    var transport: SYPlayerTransport? {
        switch self {
        case .hidden:
            return nil
        case .connecting(let transport), .playing(let transport, _), .failed(let transport):
            return transport
        case .switching(_, let destination):
            return destination
        }
    }
}

public enum SYPlayerState: Equatable {
    case idle
    case preparing
    case buffering
    case ready(duration: TimeInterval)
    case playing
    case paused
    case ended
    case error(String)
}

extension SYPlayerState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .buffering: return "buffering"
        case .ready(let duration): return "ready(duration: \(duration))"
        case .playing: return "playing"
        case .paused: return "paused"
        case .ended: return "ended"
        case .error(let message): return "error(\(message))"
        }
    }
}
