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
        didReportVideoStart = false
    }

    func setSize(_ size: CGSize) {
        rendererView.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        rendererView.renderFrame(frame)

        guard frame != nil, !didReportVideoStart else { return }

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
    private var remoteAudioTrack: RTCAudioTrack?
    private let rtcAudioSession = RTCAudioSession.sharedInstance()
    private var isAudioSessionActive = false
    private var offerTask: URLSessionDataTask?
    private var iceGatheringTimeoutWorkItem: DispatchWorkItem?
    private var pendingOffer: RTCSessionDescription?
    private var pendingOfferEndpointURL: URL?
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var firstFrameTimeoutWorkItem: DispatchWorkItem?
    private var audioStatsWorkItem: DispatchWorkItem?
    private var currentEndpointURL: URL?
    private var currentIceServers: [String] = []
    private var shouldPlayAfterSetup = false
    private var isMuted = true
    private var hasCompletedHandshake = false

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

    func setMuted(_ muted: Bool) {
        isMuted = muted
        remoteAudioTrack?.isEnabled = !muted
        SYPlayerConfig.shared.log(
            "WebRTC engine setMuted: \(muted), hasAudioTrack: \(remoteAudioTrack != nil)",
            level: .debug
        )
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
        scheduleHandshakeTimeout()

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
        configureAudioSession()

        let videoInitOptions = RTCRtpTransceiverInit()
        videoInitOptions.direction = .recvOnly
        let videoTransceiver = peerConnection.addTransceiver(of: .video, init: videoInitOptions)
        remoteVideoTrack = videoTransceiver?.receiver.track as? RTCVideoTrack
        remoteVideoTrack?.add(videoFrameRenderer)

        let audioInitOptions = RTCRtpTransceiverInit()
        audioInitOptions.direction = .recvOnly
        let audioTransceiver = peerConnection.addTransceiver(of: .audio, init: audioInitOptions)
        remoteAudioTrack = audioTransceiver?.receiver.track as? RTCAudioTrack
        remoteAudioTrack?.isEnabled = !isMuted
        let isAudioTrackEnabled = remoteAudioTrack?.isEnabled ?? false
        SYPlayerConfig.shared.log(
            "WebRTC audio transceiver created, muted: \(isMuted), enabled: \(isAudioTrackEnabled)",
            level: .debug
        )

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true"
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

            SYPlayerConfig.shared.log(
                "WebRTC offer contains audio: \(sdp.sdp.contains("m=audio"))",
                level: .debug
            )
            SYPlayerConfig.shared.log(
                "WebRTC offer audio SDP: \(self.audioMediaSummary(from: sdp.sdp))",
                level: .debug
            )

            peerConnection.setLocalDescription(sdp) { [weak self] error in
                guard let self else { return }

                if let error {
                    self.fail(error.localizedDescription)
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    self?.scheduleOfferAfterIceGathering(
                        fallbackOffer: sdp,
                        endpointURL: endpointURL
                    )
                }
            }
        }
    }

    func scheduleOfferAfterIceGathering(
        fallbackOffer: RTCSessionDescription,
        endpointURL: URL
    ) {
        pendingOffer = fallbackOffer
        pendingOfferEndpointURL = endpointURL
        iceGatheringTimeoutWorkItem?.cancel()

        if peerConnection?.iceGatheringState == .complete {
            sendPendingOffer()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.sendPendingOffer()
        }
        iceGatheringTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func sendPendingOffer() {
        guard let fallbackOffer = pendingOffer,
              let endpointURL = pendingOfferEndpointURL else { return }

        iceGatheringTimeoutWorkItem?.cancel()
        iceGatheringTimeoutWorkItem = nil
        pendingOffer = nil
        pendingOfferEndpointURL = nil

        let offer = peerConnection?.localDescription ?? fallbackOffer
        let candidateCount = offer.sdp.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("a=candidate:") }
            .count
        SYPlayerConfig.shared.log(
            "WebRTC sending gathered offer, candidates: \(candidateCount)",
            level: .debug
        )
        SYPlayerConfig.shared.log(
            "WebRTC gathered offer audio SDP: \(audioMediaSummary(from: offer.sdp))",
            level: .debug
        )
        sendOffer(offer, endpointURL: endpointURL)
    }

    func sendOffer(_ sdp: RTCSessionDescription, endpointURL: URL) {
        var request = URLRequest(url: endpointURL)
        let handshakeTimeout = SYPlayerConfig.shared.whepHandshakeTimeout
        if handshakeTimeout > 0 {
            request.timeoutInterval = handshakeTimeout
        }
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = sdp.sdp.data(using: .utf8)

        offerTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    SYPlayerConfig.shared.log(
                        "WebRTC offer request cancelled",
                        level: .debug
                    )
                    return
                }
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
            SYPlayerConfig.shared.log(
                "WebRTC answer contains audio: \(answer.contains("m=audio"))",
                level: .debug
            )
            SYPlayerConfig.shared.log(
                "WebRTC answer audio SDP: \(self.audioMediaSummary(from: answer))",
                level: .debug
            )
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
        iceGatheringTimeoutWorkItem?.cancel()
        iceGatheringTimeoutWorkItem = nil
        pendingOffer = nil
        pendingOfferEndpointURL = nil
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil
        hasCompletedHandshake = false
        audioStatsWorkItem?.cancel()
        audioStatsWorkItem = nil
        remoteVideoTrack?.remove(videoFrameRenderer)
        videoFrameRenderer.reset()
        remoteVideoTrack = nil
        remoteAudioTrack = nil
        peerConnection?.close()
        peerConnection = nil
        deactivateAudioSession()
    }

    func configureAudioSession() {
        rtcAudioSession.lockForConfiguration()
        defer { rtcAudioSession.unlockForConfiguration() }

        do {
            try rtcAudioSession.setCategory(.playAndRecord)
            try rtcAudioSession.setMode(.videoChat)
            try rtcAudioSession.overrideOutputAudioPort(.speaker)
            if !isAudioSessionActive {
                try rtcAudioSession.setActive(true)
                isAudioSessionActive = true
            }

            let outputs = rtcAudioSession.currentRoute.outputs
                .map { $0.portType.rawValue }
                .joined(separator: ", ")
            SYPlayerConfig.shared.log(
                "WebRTC audio session active, outputs: \(outputs)",
                level: .debug
            )
        } catch {
            SYPlayerConfig.shared.log(
                "WebRTC audio session configuration failed: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func deactivateAudioSession() {
        guard isAudioSessionActive else { return }

        rtcAudioSession.lockForConfiguration()
        defer { rtcAudioSession.unlockForConfiguration() }

        do {
            try rtcAudioSession.setActive(false)
            isAudioSessionActive = false
            SYPlayerConfig.shared.log("WebRTC audio session deactivated", level: .debug)
        } catch {
            SYPlayerConfig.shared.log(
                "WebRTC audio session deactivation failed: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func fail(_ message: String) {
        SYPlayerConfig.shared.log("WebRTC engine failed: \(message)", level: .error)
        cleanupConnection()
        isPlaying = false
        state = .error(message)
    }

    func scheduleHandshakeTimeout() {
        handshakeTimeoutWorkItem?.cancel()

        let timeout = SYPlayerConfig.shared.whepHandshakeTimeout
        guard timeout > 0 else { return }

        SYPlayerConfig.shared.log(
            "WebRTC handshake timeout scheduled: \(timeout)s",
            level: .debug
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.hasCompletedHandshake, !self.isPlaying else { return }
            self.fail("WHEP handshake timeout")
        }
        handshakeTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func completeHandshakeIfNeeded() {
        guard !hasCompletedHandshake else { return }

        hasCompletedHandshake = true
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil

        SYPlayerConfig.shared.log("WebRTC handshake completed", level: .debug)

        guard !isPlaying else { return }
        state = .buffering
        scheduleFirstFrameTimeout()
    }

    func scheduleFirstFrameTimeout() {
        firstFrameTimeoutWorkItem?.cancel()

        let timeout = SYPlayerConfig.shared.whepFirstFrameTimeout
        guard timeout > 0 else { return }

        SYPlayerConfig.shared.log(
            "WebRTC first frame timeout scheduled: \(timeout)s",
            level: .debug
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.fail("WHEP first frame timeout")
        }
        firstFrameTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func scheduleAudioStatsLogging() {
        audioStatsWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let peerConnection else { return }
            peerConnection.statistics { [weak self] report in
                guard let self else { return }

                let audioStats = report.statistics.values.filter { statistic in
                    guard statistic.type == "inbound-rtp" else { return false }
                    let kind = statistic.values["kind"] as? String
                    let mediaType = statistic.values["mediaType"] as? String
                    return kind == "audio" || mediaType == "audio"
                }

                guard !audioStats.isEmpty else {
                    SYPlayerConfig.shared.log(
                        "WebRTC inbound audio RTP stats: missing",
                        level: .warning
                    )
                    return
                }

                let keys = [
                    "packetsReceived",
                    "bytesReceived",
                    "packetsLost",
                    "audioLevel",
                    "totalAudioEnergy",
                    "concealedSamples"
                ]
                let summary = audioStats.map { statistic in
                    keys.compactMap { key in
                        statistic.values[key].map { "\(key)=\($0)" }
                    }
                    .joined(separator: ", ")
                }
                .joined(separator: " | ")

                SYPlayerConfig.shared.log(
                    "WebRTC inbound audio RTP stats: \(summary)",
                    level: .debug
                )
            }
        }
        audioStatsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    func audioMediaSummary(from sdp: String) -> String {
        let lines = sdp.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let startIndex = lines.firstIndex(where: { $0.hasPrefix("m=audio") }) else {
            return "missing"
        }

        let followingLines = lines.index(after: startIndex)..<lines.endIndex
        let endIndex = followingLines.first(where: { lines[$0].hasPrefix("m=") })
            ?? lines.endIndex
        let audioSection = lines[startIndex..<endIndex]
        let directions = ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"]
        let details = audioSection.filter { line in
            line.hasPrefix("m=audio")
                || line.hasPrefix("a=mid:")
                || line.hasPrefix("a=rtpmap:")
                || directions.contains(line)
        }

        return details.joined(separator: " | ")
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
        guard peerConnection != nil else { return }

        hasCompletedHandshake = true
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil

        guard !isPlaying else { return }
        SYPlayerConfig.shared.log("WebRTC video frames started", level: .debug)
        state = .playing
        isPlaying = true
        scheduleAudioStatsLogging()
    }
}

extension SYWebRTCPlayerEngine: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        SYPlayerConfig.shared.log("WebRTC signaling state: \(stateChanged)", level: .debug)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        stream.videoTracks.first?.add(videoFrameRenderer)
        if let audioTrack = stream.audioTracks.first {
            remoteAudioTrack = audioTrack
            audioTrack.isEnabled = !isMuted
            SYPlayerConfig.shared.log(
                "WebRTC remote audio track added, enabled: \(audioTrack.isEnabled)",
                level: .debug
            )
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        stream.videoTracks.first?.remove(videoFrameRenderer)
        if stream.audioTracks.contains(where: { $0 === remoteAudioTrack }) {
            remoteAudioTrack = nil
        }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        SYPlayerConfig.shared.log("WebRTC ICE state: \(newState)", level: .debug)
        guard peerConnection === self.peerConnection else {
            SYPlayerConfig.shared.log(
                "WebRTC ignore ICE state from stale connection",
                level: .debug
            )
            return
        }

        switch newState {
        case .connected, .completed:
            completeHandshakeIfNeeded()
            configureAudioSession()
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
        guard newState == .complete else { return }

        DispatchQueue.main.async { [weak self] in
            self?.sendPendingOffer()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
