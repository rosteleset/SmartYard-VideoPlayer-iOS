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

private final class SYVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        var codecs = base.supportedCodecs()
        let additionalH264Profiles = [
            "42001f", // Baseline, Level 3.1
            "4d001f", // Main, Level 3.1
            "64001f"  // High, Level 3.1
        ]

        for profile in additionalH264Profiles {
            let isAlreadyPresent = codecs.contains { codec in
                codec.name.caseInsensitiveCompare(kRTCVideoCodecH264Name) == .orderedSame
                    && codec.parameters["profile-level-id"]?.lowercased() == profile
                    && codec.parameters["packetization-mode"] == "1"
            }
            guard !isAlreadyPresent else { continue }

            codecs.append(
                RTCVideoCodecInfo(
                    name: kRTCVideoCodecH264Name,
                    parameters: [
                        "profile-level-id": profile,
                        "packetization-mode": "1",
                        "level-asymmetry-allowed": "1"
                    ]
                )
            )
        }

        return codecs
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        base.createDecoder(info)
    }
}

/// Invalidated synchronously by the UI; checked by queued work and delegate deliveries.
private final class SYWebRTCPlaybackToken {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

private final class SYWebRTCVideoFrameRenderer: NSObject, RTCVideoRenderer {
    private let rendererView: RTCMTLVideoView
    private let onVideoDidStart: () -> Void
    private let playbackToken: SYWebRTCPlaybackToken
    private let lock = NSLock()
    private var isActive = true
    private var didReportVideoStart = false

    init(
        rendererView: RTCMTLVideoView,
        playbackToken: SYWebRTCPlaybackToken,
        onVideoDidStart: @escaping () -> Void
    ) {
        self.rendererView = rendererView
        self.playbackToken = playbackToken
        self.onVideoDidStart = onVideoDidStart
        super.init()
    }

    func invalidate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func setSize(_ size: CGSize) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, playbackToken.isActive else { return }
        rendererView.setSize(size)
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        lock.lock()
        guard isActive, playbackToken.isActive else {
            lock.unlock()
            return
        }
        rendererView.renderFrame(frame)
        let shouldReportStart = frame != nil && !didReportVideoStart
        if shouldReportStart { didReportVideoStart = true }
        lock.unlock()
        if shouldReportStart { onVideoDidStart() }
    }
}

final class SYWebRTCPlayerEngine: NSObject {
    // Peer connection calls and RTCAudioSession locks may block. Serialize them away
    // from UIKit, including across engine instances sharing the process audio session.
    private static let connectionQueue = DispatchQueue(
        label: "SmartYardVideoPlayer.WebRTC.connection",
        qos: .userInitiated
    )
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: SYVideoDecoderFactory()
        )
    }()

    weak var delegate: SYWebRTCPlayerEngineDelegate?

    let rendererView = RTCMTLVideoView()
    // Main-thread state exposed to SYPlayer. All connection fields below are queue-confined.
    private(set) var isPlaying = false
    private var playbackToken = SYWebRTCPlaybackToken()

    private var connectionToken = SYWebRTCPlaybackToken()
    private var connectionID = UUID()
    private var videoFrameRenderer: SYWebRTCVideoFrameRenderer?

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
    private var shouldEnforceFirstFrameTimeout = true
    private var isMuted = true
    private var hasCompletedHandshake = false

    private var state: SYPlayerState = .idle {
        didSet {
            guard oldValue != state else { return }
            SYPlayerConfig.shared.log(
                "WebRTC engine state changed from \(oldValue) to \(state)",
                level: stateLogLevel
            )
            let state = state
            notifyDelegate { engine, delegate in
                delegate.webRTCPlayerEngine(engine, stateDidChange: state)
            }
        }
    }

    private var isConnectionPlaying = false {
        didSet {
            guard oldValue != isConnectionPlaying else { return }
            let playing = isConnectionPlaying
            notifyDelegate { engine, delegate in
                engine.isPlaying = playing
                delegate.webRTCPlayerEngine(engine, isPlayingDidChange: playing)
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
        playbackToken.invalidate()
        offerTask?.cancel()
        iceGatheringTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem?.cancel()
        audioStatsWorkItem?.cancel()
        // Do not capture a deinitializing engine or synchronously wait for RTC threads.
        let connection = peerConnection
        let track = remoteVideoTrack
        let renderer = videoFrameRenderer
        let rendererView = rendererView
        let audioSession = rtcAudioSession
        let audioSessionWasActive = isAudioSessionActive
        Self.connectionQueue.async {
            renderer?.invalidate()
            if let renderer { track?.remove(renderer) }
            connection?.delegate = nil
            connection?.close()
            if audioSessionWasActive {
                Self.deactivateAudioSession(audioSession)
            }
            // Queued commands can release the last engine reference off-main.
            // Keep UIKit objects alive until they can be released on the UI thread.
            DispatchQueue.main.async {
                withExtendedLifetime(renderer) {}
                withExtendedLifetime(rendererView) {}
            }
        }
    }

    func set(
        endpointURL: URL,
        iceServers: [String],
        autoPlay: Bool,
        enforceFirstFrameTimeout: Bool = true
    ) {
        SYPlayerConfig.shared.log(
            "WebRTC engine set endpoint: \(endpointURL.absoluteString), autoPlay: \(autoPlay)",
            level: .info
        )
        let token = replacePlaybackToken()
        Self.connectionQueue.async { [self] in
            connectionToken = token
            cleanupConnection()
            // Preserve the selected endpoint even if a rapid pause superseded setup;
            // a following play must resume this camera, not the previous one.
            currentEndpointURL = endpointURL
            currentIceServers = iceServers
            shouldEnforceFirstFrameTimeout = enforceFirstFrameTimeout
            guard token.isActive else { return }
            state = .preparing
            if autoPlay {
                startConnection()
            } else {
                state = .ready(duration: 0)
            }
        }
    }

    func play() {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = playbackToken
        Self.connectionQueue.async { [self] in
            guard token.isActive, currentEndpointURL != nil else { return }
            if peerConnection == nil { startConnection() }
        }
    }

    func setMuted(_ muted: Bool) {
        Self.connectionQueue.async { [self] in
            isMuted = muted
            remoteAudioTrack?.isEnabled = !muted
            SYPlayerConfig.shared.log(
                "WebRTC engine setMuted: \(muted), hasAudioTrack: \(remoteAudioTrack != nil)",
                level: .debug
            )
        }
    }

    func pause() {
        SYPlayerConfig.shared.log("WebRTC engine pause", level: .debug)
        stopConnection(state: .paused)
    }

    func stop() {
        SYPlayerConfig.shared.log("WebRTC engine stop", level: .info)
        stopConnection(state: .idle)
    }

    func cleanup() {
        stop()
    }
}

private extension SYWebRTCPlayerEngine {
    func replacePlaybackToken() -> SYWebRTCPlaybackToken {
        dispatchPrecondition(condition: .onQueue(.main))
        playbackToken.invalidate()
        playbackToken = SYWebRTCPlaybackToken()
        isPlaying = false
        return playbackToken
    }

    func stopConnection(state: SYPlayerState) {
        let token = replacePlaybackToken()
        Self.connectionQueue.async { [self] in
            connectionToken = token
            cleanupConnection()
            isConnectionPlaying = false
            self.state = state
        }
    }

    func startConnection() {
        dispatchPrecondition(condition: .onQueue(Self.connectionQueue))
        guard connectionToken.isActive, let endpointURL = currentEndpointURL else { return }

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
        configureAudioSession()

        let connectionID = connectionID
        let videoFrameRenderer = SYWebRTCVideoFrameRenderer(
            rendererView: rendererView,
            playbackToken: connectionToken,
            onVideoDidStart: { [weak self] in
                Self.connectionQueue.async { [weak self] in
                    guard let self, self.connectionID == connectionID,
                          self.connectionToken.isActive else { return }
                    self.handleVideoDidStart()
                }
            }
        )
        self.videoFrameRenderer = videoFrameRenderer

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
            self?.perform(for: peerConnection) { engine in
                if let error {
                    engine.fail(error.localizedDescription)
                    return
                }
                guard let sdp else {
                    engine.fail("Local SDP offer is empty")
                    return
                }
                SYPlayerConfig.shared.log(
                    "WebRTC offer audio SDP: \(engine.audioMediaSummary(from: sdp.sdp))",
                    level: .debug
                )
                peerConnection.setLocalDescription(sdp) { [weak engine] error in
                    engine?.perform(for: peerConnection) { engine in
                        if let error {
                            engine.fail(error.localizedDescription)
                            return
                        }
                        engine.scheduleOfferAfterIceGathering(
                            fallbackOffer: sdp,
                            endpointURL: endpointURL
                        )
                    }
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

        let timeout = max(0, SYPlayerConfig.shared.whepIceGatheringTimeout)
        guard timeout > 0 else {
            sendPendingOffer()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.sendPendingOffer()
        }
        iceGatheringTimeoutWorkItem = workItem
        Self.connectionQueue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func sendPendingOffer() {
        guard connectionToken.isActive, let fallbackOffer = pendingOffer,
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
        scheduleHandshakeTimeout()
        sendOffer(offer, endpointURL: endpointURL)
    }

    func sendOffer(_ sdp: RTCSessionDescription, endpointURL: URL) {
        guard let peerConnection else { return }
        var request = URLRequest(url: endpointURL)
        let requestTimeout = SYPlayerConfig.shared.whepRequestTimeout
        if requestTimeout > 0 {
            request.timeoutInterval = requestTimeout
        }
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = sdp.sdp.data(using: .utf8)

        offerTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.perform(for: peerConnection) { engine in
                engine.handleOfferResponse(data: data, response: response, error: error, connection: peerConnection)
            }
        }
        offerTask?.resume()
    }

    func handleOfferResponse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        connection: RTCPeerConnection
    ) {
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            fail(error.localizedDescription)
            return
        }

        guard let response = response as? HTTPURLResponse else {
            fail("Invalid WHEP response")
            return
        }

        guard 200..<300 ~= response.statusCode else {
            let responseBody = data.flatMap {
                String(bytes: $0, encoding: .utf8)
            }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = responseBody
                .flatMap { $0.isEmpty ? nil : $0 }
                .map { ": \($0.prefix(512))" } ?? ""
            fail("WHEP HTTP status \(response.statusCode)\(details)")
            return
        }

        guard let data, !data.isEmpty else {
            fail("WHEP answer is empty")
            return
        }

        let answer = String(decoding: data, as: UTF8.self)
        SYPlayerConfig.shared.log(
            "WebRTC answer audio SDP: \(audioMediaSummary(from: answer))",
            level: .debug
        )
        let remoteSdp = RTCSessionDescription(type: .answer, sdp: answer)

        connection.setRemoteDescription(remoteSdp) { [weak self] error in
            self?.perform(for: connection) { engine in
                if let error {
                    engine.fail(error.localizedDescription)
                }
            }
        }
    }

    func cleanupConnection() {
        dispatchPrecondition(condition: .onQueue(Self.connectionQueue))
        connectionID = UUID()
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
        videoFrameRenderer?.invalidate()
        if let videoFrameRenderer { remoteVideoTrack?.remove(videoFrameRenderer) }
        videoFrameRenderer = nil
        remoteVideoTrack = nil
        remoteAudioTrack = nil
        let connection = peerConnection
        peerConnection = nil
        connection?.delegate = nil
        connection?.close()
        if isAudioSessionActive {
            isAudioSessionActive = !Self.deactivateAudioSession(rtcAudioSession)
        }
        isConnectionPlaying = false
    }

    func configureAudioSession() {
        rtcAudioSession.lockForConfiguration()
        defer { rtcAudioSession.unlockForConfiguration() }

        do {
            try rtcAudioSession.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
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

    @discardableResult
    static func deactivateAudioSession(_ rtcAudioSession: RTCAudioSession) -> Bool {
        rtcAudioSession.lockForConfiguration()
        defer { rtcAudioSession.unlockForConfiguration() }

        do {
            try rtcAudioSession.setActive(false)
            SYPlayerConfig.shared.log("WebRTC audio session deactivated", level: .debug)
            return true
        } catch {
            SYPlayerConfig.shared.log(
                "WebRTC audio session deactivation failed: \(error.localizedDescription)",
                level: .error
            )
            return false
        }
    }

    func fail(_ message: String) {
        SYPlayerConfig.shared.log("WebRTC engine failed: \(message)", level: .error)
        cleanupConnection()
        isConnectionPlaying = false
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
            guard let self, self.connectionToken.isActive,
                  !self.hasCompletedHandshake, !self.isConnectionPlaying else { return }
            self.fail("WHEP handshake timeout")
        }
        handshakeTimeoutWorkItem = workItem
        Self.connectionQueue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func completeHandshakeIfNeeded() {
        guard !hasCompletedHandshake else { return }

        hasCompletedHandshake = true
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil

        SYPlayerConfig.shared.log("WebRTC handshake completed", level: .debug)

        guard !isConnectionPlaying else { return }
        state = .buffering
        scheduleFirstFrameTimeout()
    }

    func scheduleFirstFrameTimeout() {
        firstFrameTimeoutWorkItem?.cancel()

        guard shouldEnforceFirstFrameTimeout else {
            SYPlayerConfig.shared.log(
                "WebRTC first-frame timeout is controlled by the transport race",
                level: .debug
            )
            return
        }

        let timeout = SYPlayerConfig.shared.whepFirstFrameTimeout
        guard timeout > 0 else { return }

        SYPlayerConfig.shared.log(
            "WebRTC first frame timeout scheduled: \(timeout)s",
            level: .debug
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.connectionToken.isActive, !self.isConnectionPlaying else { return }
            self.fail("WHEP first frame timeout")
        }
        firstFrameTimeoutWorkItem = workItem
        Self.connectionQueue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func scheduleAudioStatsLogging() {
        audioStatsWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let peerConnection else { return }
            let token = self.connectionToken
            peerConnection.statistics { report in
                guard token.isActive else { return }

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
        Self.connectionQueue.asyncAfter(deadline: .now() + 3, execute: workItem)
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
        let token = connectionToken
        DispatchQueue.main.async { [weak self] in
            guard token.isActive, let self, let delegate = self.delegate else { return }
            action(self, delegate)
        }
    }

    func perform(
        for connection: RTCPeerConnection,
        _ action: @escaping (SYWebRTCPlayerEngine) -> Void
    ) {
        Self.connectionQueue.async { [weak self] in
            guard let self, self.connectionToken.isActive,
                  self.peerConnection === connection else { return }
            action(self)
        }
    }

    func handleVideoDidStart() {
        guard peerConnection != nil else { return }

        hasCompletedHandshake = true
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        firstFrameTimeoutWorkItem?.cancel()
        firstFrameTimeoutWorkItem = nil

        guard !isConnectionPlaying else { return }
        SYPlayerConfig.shared.log("WebRTC video frames started", level: .debug)
        state = .playing
        isConnectionPlaying = true
        scheduleAudioStatsLogging()
    }
}

extension SYWebRTCPlayerEngine: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        SYPlayerConfig.shared.log("WebRTC signaling state: \(stateChanged)", level: .debug)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        perform(for: peerConnection) { engine in
            if let renderer = engine.videoFrameRenderer, let track = stream.videoTracks.first {
                if engine.remoteVideoTrack !== track {
                    engine.remoteVideoTrack?.remove(renderer)
                    engine.remoteVideoTrack = track
                    track.add(renderer)
                }
            }
            if let audioTrack = stream.audioTracks.first {
                engine.remoteAudioTrack = audioTrack
                audioTrack.isEnabled = !engine.isMuted
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        perform(for: peerConnection) { engine in
            if let renderer = engine.videoFrameRenderer {
                stream.videoTracks.first?.remove(renderer)
            }
            if stream.audioTracks.contains(where: { $0 === engine.remoteAudioTrack }) {
                engine.remoteAudioTrack = nil
            }
        }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        SYPlayerConfig.shared.log("WebRTC ICE state: \(newState)", level: .debug)
        perform(for: peerConnection) { engine in
            switch newState {
            case .connected, .completed:
                engine.completeHandshakeIfNeeded()
                engine.configureAudioSession()
            case .failed:
                engine.fail("WebRTC connection failed")
            case .disconnected:
                engine.fail("WebRTC connection disconnected")
            case .closed:
                engine.isConnectionPlaying = false
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        SYPlayerConfig.shared.log("WebRTC ICE gathering state: \(newState)", level: .debug)
        guard newState == .complete else { return }

        perform(for: peerConnection) { engine in
            engine.sendPendingOffer()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
