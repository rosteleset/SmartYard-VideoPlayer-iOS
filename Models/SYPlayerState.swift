//
//  SYPlayerState.swift
//  SmartYard
//
//  Created by Александр Попов on 26.07.2024.
//  Copyright © 2024 LanTa. All rights reserved.
//

import Foundation

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
