//
//  SYWebRTCPlayerEngine.swift
//  SmartYardVideoPlayer
//
//  Created by Александр Попов on 26.05.2026.
//

import Foundation
import UIKit
import WebRTC

protocol SYWebRTCPlayerEngineDelegate: AnyObject {
    func webRTCPlayerEngine(
        _ engine: SYWebRTCPlayerEngine,
        stateDidChange state: SYPlayerState
    )

    func webRTCPlayerEngine(
        _ engine: SYWebRTCPlayerEngine,
        isPlayingDidChange isPlaying: Bool
    )
}

private final class SYWebRTCVideoFrameRenderer: NSObject, RTCVideoRenderer {
    private let rendererView: RTCMTLVideoView
    private let onVideoDidStart: () -> Void

    private var previousTimestampNs: Int64?
    private var didReportVideoStart = false

    init(
        rendererView: RTCMTLVideoView,
        onVideoDidStart: @escaping () -> Void
    ) {
        self.rendererView = rendererView
        self.onVideoDidStart = onVideoDidStart
        super.init()
    }

    func reset() {
        previousTimestampNs = nil
        didReportVideoStart = false
    }

    func setSize(_ size: CGSize) {
        rendererView.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        rendererView.renderFrame(frame)

        guard let frame else { return }
        let timestampNs = frame.timeStampNs
        defer { previousTimestampNs = timestampNs }

        guard let previousTimestampNs,
              previousTimestampNs != timestampNs,
              !didReportVideoStart else { return }

        didReportVideoStart = true
        DispatchQueue.main.async { [onVideoDidStart] in
            onVideoDidStart()
        }
    }
}

final class SYWebRTCPlayerEngine: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    weak var delegate: SYWebRTCPlayerEngineDelegate?

    let rendererView = RTCMTLVideoView()
    private lazy var videoFrameRenderer = SYWebRTCVideoFrameRenderer(
        rendererView: rendererView,
        onVideoDidStart: { [weak self] in
            self?.handleVideoDidStart()
        }
    )

    private var peerConnection: RTCPeerConnection?
    private var remoteVideoTrack: RTCVideoTrack?
    private var offerTask: URLSessionDataTask?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var currentEndpointURL: URL?
    private var currentIceServers: [String] = []
    private var shouldPlayAfterSetup = false

    private(set) var state: SYPlayerState = .idle {
        didSet {
            guard oldValue != state else { return }
            SYPlayerConfig.shared.log(
                "WebRTC engine state changed from \(oldValue) to \(state)",
                level: stateLogLevel
            )
            notifyDelegate { engine, delegate in
                delegate.webRTCPlayerEngine(engine, stateDidChange: engine.state)
            }
        }
    }

    private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            notifyDelegate { engine, delegate in
                delegate.webRTCPlayerEngine(engine, isPlayingDidChange: engine.isPlaying)
            }
        }
    }

    private var stateLogLevel: SYPlayerLogLevel {
        if case .error = state { return .error }
        return .debug
    }

    override init() {
        super.init()
        rendererView.videoContentMode = .scaleAspectFit
        rendererView.backgroundColor = .black
    }

    deinit {
        cleanup()
    }

    func set(endpointURL: URL, iceServers: [String], autoPlay: Bool) {
        SYPlayerConfig.shared.log(
            "WebRTC engine set endpoint: \(endpointURL.absoluteString), autoPlay: \(autoPlay)",
            level: .info
        )
        currentEndpointURL = endpointURL
        currentIceServers = iceServers
        shouldPlayAfterSetup = autoPlay

        cleanupConnection()
        state = .preparing
        scheduleConnectionTimeout()

        guard autoPlay else {
            state = .ready(duration: 0)
            return
        }

        startConnection()
    }

    func play() {
        guard currentEndpointURL != nil else { return }
        shouldPlayAfterSetup = true

        if case .paused = state {
            startConnection()
            return
        }

        if case .idle = state {
            startConnection()
            return
        }

        if peerConnection == nil {
            startConnection()
        }
    }

    func pause() {
        SYPlayerConfig.shared.log("WebRTC engine pause", level: .debug)
        shouldPlayAfterSetup = false
        cleanupConnection()
        isPlaying = false
        state = .paused
    }

    func stop() {
        SYPlayerConfig.shared.log("WebRTC engine stop", level: .info)
        shouldPlayAfterSetup = false
        cleanupConnection()
        isPlaying = false
        state = .idle
    }

    func cleanup() {
        stop()
    }
}

private extension SYWebRTCPlayerEngine {
    func startConnection() {
        guard let endpointURL = currentEndpointURL else { return }

        cleanupConnection()
        state = .preparing

        let config = RTCConfiguration()
        let filteredIceServers = currentIceServers.filter { !$0.isEmpty && $0 != "none:" }
        config.iceServers = filteredIceServers.isEmpty ? [] : [RTCIceServer(urlStrings: filteredIceServers)]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )

        guard let peerConnection = Self.factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        ) else {
            fail("Could not create RTCPeerConnection")
            return
        }

        self.peerConnection = peerConnection
        let initOptions = RTCRtpTransceiverInit()
        initOptions.direction = .recvOnly
        let videoTransceiver = peerConnection.addTransceiver(of: .video, init: initOptions)
        remoteVideoTrack = videoTransceiver?.receiver.track as? RTCVideoTrack
        remoteVideoTrack?.add(videoFrameRenderer)

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "false"
            ],
            optionalConstraints: nil
        )

        peerConnection.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self else { return }

            if let error {
                self.fail(error.localizedDescription)
                return
            }

            guard let sdp else {
                self.fail("Local SDP offer is empty")
                return
            }

            peerConnection.setLocalDescription(sdp) { [weak self] error in
                guard let self else { return }

                if let error {
                    self.fail(error.localizedDescription)
                    return
                }

                self.sendOffer(sdp, endpointURL: endpointURL)
            }
        }
    }

    func sendOffer(_ sdp: RTCSessionDescription, endpointURL: URL) {
        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 5
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = sdp.sdp.data(using: .utf8)

        offerTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                self.fail(error.localizedDescription)
                return
            }

            guard let response = response as? HTTPURLResponse else {
                self.fail("Invalid WHEP response")
                return
            }

            guard 200..<300 ~= response.statusCode else {
                self.fail("WHEP HTTP status \(response.statusCode)")
                return
            }

            guard let data, !data.isEmpty else {
                self.fail("WHEP answer is empty")
                return
            }

            let answer = String(decoding: data, as: UTF8.self)
            let remoteSdp = RTCSessionDescription(type: .answer, sdp: answer)

            self.peerConnection?.setRemoteDescription(remoteSdp) { [weak self] error in
                guard let self else { return }

                if let error {
                    self.fail(error.localizedDescription)
                }
            }
        }
        offerTask?.resume()
    }

    func cleanupConnection() {
        offerTask?.cancel()
        offerTask = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        remoteVideoTrack?.remove(videoFrameRenderer)
        videoFrameRenderer.reset()
        remoteVideoTrack = nil
        peerConnection?.close()
        peerConnection = nil
    }

    func fail(_ message: String) {
        SYPlayerConfig.shared.log("WebRTC engine failed: \(message)", level: .error)
        cleanupConnection()
        isPlaying = false
        state = .error(message)
    }

    func scheduleConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.fail("WHEP connection timeout")
        }
        connectionTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    func notifyDelegate(
        _ action: @escaping (SYWebRTCPlayerEngine, SYWebRTCPlayerEngineDelegate) -> Void
    ) {
        if Thread.isMainThread {
            guard let delegate else { return }
            action(self, delegate)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            action(self, delegate)
        }
    }

    func handleVideoDidStart() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil

        guard !isPlaying else { return }
        SYPlayerConfig.shared.log("WebRTC video frames started", level: .debug)
        state = .playing
        isPlaying = true
    }
}

extension SYWebRTCPlayerEngine: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        SYPlayerConfig.shared.log("WebRTC signaling state: \(stateChanged)", level: .debug)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        stream.videoTracks.first?.add(videoFrameRenderer)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        stream.videoTracks.first?.remove(videoFrameRenderer)
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        SYPlayerConfig.shared.log("WebRTC ICE state: \(newState)", level: .debug)

        switch newState {
        case .connected, .completed:
            if !isPlaying { state = .buffering }
        case .failed:
            fail("WebRTC connection failed")
        case .disconnected:
            fail("WebRTC connection disconnected")
        case .closed:
            isPlaying = false
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        SYPlayerConfig.shared.log("WebRTC ICE gathering state: \(newState)", level: .debug)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
