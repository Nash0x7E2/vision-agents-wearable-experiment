//
//  StreamCallManager.swift
//  rayban_agents
//
//  Manages Stream Video SDK integration including client setup,
//  call lifecycle, audio session configuration, and video filters.
//

import Foundation
import AVFoundation
import StreamVideo
import StreamVideoSwiftUI
import MWDATCamera

private struct StartSessionRequest: Encodable {
    let call_id: String
    let call_type: String
}

private struct StartSessionResponse: Decodable {
    let session_id: String
    let call_id: String
    let session_started_at: Date
}

private struct AgentJoinRequest: Encodable {
    let callId: String
    let userId: String
}

private struct AgentJoinResponse: Decodable {
    let success: Bool
    let agentId: String?
    let message: String?
}

private enum BackendAPIError: Error, CustomStringConvertible {
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var description: String {
        switch self {
        case .invalidResponse:
            return "invalidResponse"
        case .httpError(let code, let body):
            let methodHint = code == 405 ? " (Method Not Allowed — ensure backend accepts POST /sessions)" : ""
            return "httpError(statusCode: \(code), body: \"\(body)\")\(methodHint)"
        }
    }
}

private enum ISO8601Parsers {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let withoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) throws -> Date {
        if let d = withFractional.date(from: s) ?? withoutFractional.date(from: s) {
            return d
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Invalid ISO8601: \(s)")
        )
    }
}

private enum JSONCoders {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            return try ISO8601Parsers.parse(str)
        }
        return d
    }()
}

@Observable
final class StreamCallManager {
    
    // MARK: - Published State
    
    private(set) var isConnected = false
    private(set) var isInCall = false
    private(set) var isMicrophoneEnabled = true
    private(set) var isCameraEnabled = true
    private(set) var callState: CallState?
    private(set) var error: Error?

    var participantCount: Int {
        if let c = call?.state.participantCount { return Int(c) }
        if let c = callState?.participantCount { return Int(c) }
        return 0
    }
    
    // MARK: - Stream Video Objects
    
    private(set) var streamVideo: StreamVideo?
    private(set) var call: Call?
    
    /// Session ID from backend (agent join). Used to close the agent on leave/end.
    private(set) var currentAgentSessionId: String?
    /// Call ID used when starting backend session; used for DELETE /agents/{callId} in demo-style API.
    private(set) var currentBackendCallId: String?

    // MARK: - Private Properties
    
    private var videoFilter: VideoFilter?
    private weak var wearablesManager: WearablesManager?
    private var wearableFrameSink: (any ExternalFrameSink)?
    private var frameCount = 0
    
    // MARK: - Initialization

    init() {}

    // MARK: - Setup

    func setup(wearablesManager: WearablesManager? = nil) async {
        self.wearablesManager = wearablesManager
        await setupAudioSession()
        await setupStreamVideo()
    }

    private func setupStreamVideo() async {
        let user = User(
            id: Secrets.streamUserId,
            name: "Wearables User",
            imageURL: nil
        )

        let token = UserToken(rawValue: Secrets.streamUserToken)

        let customProvider = ExternalVideoCapturerProvider { [weak weakSelf = self] frameSink in
            StreamCallManager.handleFrameSinkOnMain(weakSelf: weakSelf, frameSink: frameSink)
        }
        let videoConfig = VideoConfig(customVideoCapturerProvider: customProvider)

        let video = StreamVideo(
            apiKey: Secrets.streamApiKey,
            user: user,
            token: token,
            videoConfig: videoConfig,
            tokenProvider: { result in
                result(.success(token))
            }
        )
        streamVideo = video

        do {
            print("[Stream] Connecting to Stream Video...")
            try await video.connect()
            print("[Stream] Connected successfully")
            await MainActor.run { [weak self] in
                self?.isConnected = true
            }
            
            // Monitor connection state
            observeConnectionState()
        } catch {
            await MainActor.run { [weak self] in
                self?.error = error
                self?.isConnected = false
            }
            print("[Stream] Failed to connect to Stream: \(error)")
        }
    }
    
    private func observeConnectionState() {
        guard let video = streamVideo else { return }
        
        // Log initial connection status
        print("[Stream] Initial connection status: \(video.state.connection)")
        
        // Note: For production, you would want to observe connection state changes
        // using Combine or other observation mechanisms. For now, we'll rely on
        // the isConnected flag and error handling in individual operations.
    }
    
    private func setupAudioSession() async {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("[Audio] Session configured: category=\(audioSession.category.rawValue), mode=\(audioSession.mode.rawValue)")
            logAvailableAudioInputs(audioSession: audioSession)
            setPreferredInputToWearable(audioSession: audioSession)
            observeAudioRouteChanges()
        } catch {
            print("[Audio] Failed to configure audio session: \(error)")
            self.error = error
        }
    }
    
    private func logAvailableAudioInputs(audioSession: AVAudioSession) {
        guard let inputs = audioSession.availableInputs else {
            print("[Audio] No available inputs")
            return
        }
        print("[Audio] Available inputs (\(inputs.count)):")
        for input in inputs {
            print("[Audio]   - \(input.portName) (type: \(input.portType.rawValue), uid: \(input.uid))")
            if let dataSources = input.dataSources, !dataSources.isEmpty {
                for source in dataSources {
                    print("[Audio]       data source: \(source.dataSourceName)")
                }
            }
        }
        if let currentRoute = audioSession.currentRoute.inputs.first {
            print("[Audio] Current input route: \(currentRoute.portName) (type: \(currentRoute.portType.rawValue))")
        }
        if let currentOutput = audioSession.currentRoute.outputs.first {
            print("[Audio] Current output route: \(currentOutput.portName) (type: \(currentOutput.portType.rawValue))")
        }
    }
    
    private func setPreferredInputToWearable(audioSession: AVAudioSession) {
        guard let inputs = audioSession.availableInputs else {
            print("[Audio] setPreferredInput: no available inputs")
            return
        }
        
        let bluetoothPortTypes: Set<AVAudioSession.Port> = [
            .bluetoothHFP,
            .bluetoothA2DP,
            .bluetoothLE
        ]
        
        let wearableKeywords = ["meta", "rayban", "ray-ban", "glasses"]
        
        var selectedInput: AVAudioSessionPortDescription?
        
        for input in inputs {
            let portNameLower = input.portName.lowercased()
            if wearableKeywords.contains(where: { portNameLower.contains($0) }) {
                selectedInput = input
                print("[Audio] Found wearable by name: \(input.portName)")
                break
            }
        }
        
        if selectedInput == nil {
            selectedInput = inputs.first { bluetoothPortTypes.contains($0.portType) }
            if let sel = selectedInput {
                print("[Audio] Found Bluetooth input: \(sel.portName) (type: \(sel.portType.rawValue))")
            }
        }
        
        guard let wearable = selectedInput else {
            print("[Audio] No wearable/Bluetooth input found")
            return
        }
        
        do {
            try audioSession.setPreferredInput(wearable)
            print("[Audio] Set preferred input to: \(wearable.portName)")
            
            if let currentInput = audioSession.currentRoute.inputs.first {
                print("[Audio] Verified current input: \(currentInput.portName) (type: \(currentInput.portType.rawValue))")
            }
        } catch {
            print("[Audio] Failed to set preferred input to wearable: \(error)")
        }
    }
    
    private func observeAudioRouteChanges() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification: notification)
        }
    }
    
    private func handleAudioRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        
        print("[Audio] Route changed - reason: \(routeChangeReasonString(reason))")
        logAvailableAudioInputs(audioSession: audioSession)
        
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .categoryChange:
            setPreferredInputToWearable(audioSession: audioSession)
        default:
            break
        }
    }
    
    private func routeChangeReasonString(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unknown(\(reason.rawValue))"
        }
    }
    
    // MARK: - Call Management
    
    func createAndJoinCall(callId: String, callType: String = "default") async {
        guard let streamVideo else {
            print("StreamVideo not initialized")
            return
        }
        guard isConnected else {
            print("Cannot join call: Stream client not connected")
            return
        }

        // Start with video ON since wearable stream is already active
        // This prevents WebRTC renegotiation issues when enabling video later
        let callSettings = CallSettings(
            audioOn: true,
            videoOn: true,
            speakerOn: true,
            audioOutputOn: true
        )
        let newCall = streamVideo.call(callType: callType, callId: callId, callSettings: callSettings)
        call = newCall

        if let filter = videoFilter {
            newCall.setVideoFilter(filter)
        }

        do {
            print("[Stream] ========================================")
            print("[Stream] 🎬 JOINING CALL")
            print("[Stream] Call ID: \(callId)")
            print("[Stream] Call Type: \(callType)")
            print("[Stream] ========================================")
            let audioSession = AVAudioSession.sharedInstance()
            setPreferredInputToWearable(audioSession: audioSession)
            
            try await newCall.join(create: true, callSettings: callSettings)
            print("[Stream] Successfully joined call: \(callId)")
            print("[Stream] Participant count: \(newCall.state.participantCount ?? 0)")
            print("[Stream] Local participant ID: \(newCall.state.localParticipant?.id ?? "unknown")")
            
            do {
                try await newCall.microphone.enable()
                print("[Audio] Microphone enabled successfully")
            } catch {
                print("[Audio] Failed to enable microphone: \(error)")
            }
            
            do {
                try await newCall.speaker.enableSpeakerPhone()
            } catch {
                print("[Audio] Failed to enable speaker phone: \(error)")
            }
            try? await newCall.speaker.enableAudioOutput()
            try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            logAvailableAudioInputs(audioSession: audioSession)
            print("[Audio] After call join - hasAudio: \(newCall.state.localParticipant?.hasAudio ?? false)")
            print("[Audio] Microphone status - isEnabled: \(newCall.microphone.status.rawValue)")
            print("[Video] After call join - hasVideo: \(newCall.state.localParticipant?.hasVideo ?? false)")
            print("[Video] Camera status - isEnabled: \(newCall.camera.status.rawValue)")
            print("[Video] Frame sink ready: \(wearableFrameSink != nil)")
            print("[Video] Wearable streaming: \(wearablesManager?.isStreaming ?? false)")
            
            // Give frame sink a moment to initialize and start pushing frames
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            
            await MainActor.run { [weak self] in
                guard let this = self else { return }
                this.isInCall = true
                this.isCameraEnabled = true
                this.callState = newCall.state
            }
        } catch {
            await MainActor.run { [weak self] in
                guard let this = self else { return }
                this.error = error
                this.isInCall = false
            }
            print("[Stream] Failed to join call \(callId): \(error)")
            return
        }
    }

    private static var backendSessionsPath: String {
        Secrets.backendSessionsPath ?? "/sessions"
    }

    private static var backendUsesAgentJoinFormat: Bool {
        let path = backendSessionsPath
        return path.contains("agent") && path.contains("join")
    }

    private func startBackendSession(callId: String, callType: String, baseURL: String) async throws -> String {
        let path = Self.backendSessionsPath
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathTrimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: "\(base)/\(pathTrimmed)") else { throw BackendAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if Self.backendUsesAgentJoinFormat {
            let userId = Secrets.backendUserId ?? Secrets.streamUserId
            request.httpBody = try JSONCoders.encoder.encode(AgentJoinRequest(callId: callId, userId: userId))
        } else {
            request.httpBody = try JSONCoders.encoder.encode(StartSessionRequest(call_id: callId, call_type: callType))
        }

        print("[Backend API] POST \(url.absoluteString)")
        if let body = request.httpBody, let bodyStr = String(data: body, encoding: .utf8) {
            print("[Backend API] Request body: \(bodyStr)")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendAPIError.invalidResponse }
        
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        print("[Backend API] Response status: \(http.statusCode)")
        print("[Backend API] Response body: \(responseBody)")
        
        guard (Self.backendUsesAgentJoinFormat ? (200...299).contains(http.statusCode) : http.statusCode == 201) else {
            throw BackendAPIError.httpError(statusCode: http.statusCode, body: responseBody)
        }

        if Self.backendUsesAgentJoinFormat {
            let decoded = try JSONCoders.decoder.decode(AgentJoinResponse.self, from: data)
            guard decoded.success, let agentId = decoded.agentId else {
                throw BackendAPIError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
            }
            return agentId
        }

        let decoded = try JSONCoders.decoder.decode(StartSessionResponse.self, from: data)
        return decoded.session_id
    }

    private func closeBackendSessionIfNeeded() async {
        guard let baseURL = Secrets.backendBaseURL, !baseURL.isEmpty else { return }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url: URL?
        if Self.backendUsesAgentJoinFormat {
            let callId = currentBackendCallId ?? call?.callId ?? ""
            guard !callId.isEmpty else { return }
            url = URL(string: "\(base)/agents/\(callId)")
        } else {
            guard let sessionId = currentAgentSessionId else { return }
            url = URL(string: "\(base)/sessions/\(sessionId)")
        }
        guard let url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
        await MainActor.run { [weak self] in
            self?.currentAgentSessionId = nil
            self?.currentBackendCallId = nil
        }
    }

    func enableCameraWithWearableFilter() async {
        guard let call else {
            print("[Stream] enableCameraWithWearableFilter: no active call")
            return
        }
        
        // Verify wearable stream is ready before enabling camera
        if let wearables = wearablesManager {
            if !wearables.isStreaming {
                print("[Stream] Warning: Wearable stream not active yet (state: \(wearables.streamState)), waiting up to 3 seconds...")
                
                // Wait up to 3 seconds for stream to become active
                var waitAttempts = 0
                while !wearables.isStreaming && waitAttempts < 30 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    waitAttempts += 1
                }
                
                guard wearables.isStreaming else {
                    print("[Stream] Error: Wearable stream failed to start after 3 seconds (final state: \(wearables.streamState))")
                    print("[Stream] Stream session exists: \(wearables.streamState != .stopped)")
                    return
                }
                print("[Stream] Wearable stream became active after \(waitAttempts * 100)ms")
            }
        } else {
            print("[Stream] Error: WearablesManager not available")
            return
        }
        
        print("[Stream] Wearable stream confirmed active, enabling camera")
        print("[Stream] Frame sink ready: \(wearableFrameSink != nil)")
        print("[Stream] onFrameForSink callback set: \(wearablesManager?.onFrameForSink != nil)")
        
        do {
            print("[Stream] Enabling camera for call: \(call.callId)")
            let startTime = Date()
            try await call.camera.enable()
            let elapsed = Date().timeIntervalSince(startTime)
            print("[Stream] Camera enabled successfully (took \(String(format: "%.2f", elapsed))s)")
            print("[Stream] Audio track publishing: \(call.state.localParticipant?.hasAudio ?? false)")
            print("[Stream] Video track publishing: \(call.state.localParticipant?.hasVideo ?? false)")
            
            // Give a moment for video track to fully negotiate
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            print("[Stream] Video track negotiation stabilization complete")
            
            await MainActor.run { [weak self] in
                self?.isCameraEnabled = true
            }
        } catch {
            print("[Stream] Failed to enable camera: \(error)")
            self.error = error
        }
    }

    func startBackendSessionIfNeeded() async {
        guard let baseURL = Secrets.backendBaseURL, !baseURL.isEmpty else { return }
        guard let call else { return }
        
        print("[Backend] Waiting for WebRTC connection to stabilize before starting agent...")
        
        // Wait for WebRTC connection and video track to fully stabilize
        // Need to ensure frame sink is pumping frames before agent joins
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        
        // Verify we're still in the call and connection is good
        guard isInCall else {
            print("[Backend] Call ended before backend session could start")
            return
        }
        
        // Log connection state before starting agent
        print("[Backend] Connection state before agent start:")
        print("[Backend]   - isInCall: \(isInCall)")
        print("[Backend]   - isConnected: \(isConnected)")
        print("[Backend]   - participant count: \(participantCount)")
        print("[Backend]   - local audio publishing: \(call.state.localParticipant?.hasAudio ?? false)")
        print("[Backend]   - local video publishing: \(call.state.localParticipant?.hasVideo ?? false)")
        
        print("[Backend] Starting backend session for call: \(call.callId)")
        
        do {
            let sessionId = try await startBackendSession(
                callId: call.callId,
                callType: call.callType,
                baseURL: baseURL
            )
            await MainActor.run { [weak self] in
                self?.currentAgentSessionId = sessionId
                self?.currentBackendCallId = call.callId
            }
            print("[Backend] Session started successfully: \(sessionId)")
        } catch {
            print("[Backend] Start session failed (may already be in call): \(error)")
            await MainActor.run { [weak self] in
                self?.currentAgentSessionId = nil
                self?.currentBackendCallId = nil
            }
        }
    }

    func leaveCall() async {
        guard let call else { return }
        stopWearableFramePump()
        call.leave()
        await closeBackendSessionIfNeeded()
        await MainActor.run { [weak self] in
            self?.call = nil
            self?.isInCall = false
            self?.callState = nil
        }
    }
    
    func endCall() async {
        guard let call else { return }
        stopWearableFramePump()
        do {
            try await call.end()
            await closeBackendSessionIfNeeded()
            await MainActor.run { [weak self] in
                self?.call = nil
                self?.isInCall = false
                self?.callState = nil
            }
        } catch {
            print("Failed to end call: \(error)")
            self.error = error
        }
    }
    
    // MARK: - Media Controls
    
    func toggleMicrophone() async {
        guard let call else { return }
        
        do {
            if isMicrophoneEnabled {
                try await call.microphone.disable()
            } else {
                try await call.microphone.enable()
            }
            await MainActor.run { [weak self] in
                self?.isMicrophoneEnabled.toggle()
            }
        } catch {
            print("Failed to toggle microphone: \(error)")
            self.error = error
        }
    }
    
    func toggleCamera() async {
        guard let call else { return }
        
        do {
            if isCameraEnabled {
                try await call.camera.disable()
            } else {
                try await call.camera.enable()
            }
            await MainActor.run { [weak self] in
                self?.isCameraEnabled.toggle()
            }
        } catch {
            print("Failed to toggle camera: \(error)")
            self.error = error
        }
    }
    
    func enableSpeakerPhone() async {
        guard let call else { return }
        
        do {
            try await call.speaker.enableSpeakerPhone()
        } catch {
            print("Failed to enable speaker phone: \(error)")
        }
    }
    
    // MARK: - Video Filter

    func setVideoFilter(_ filter: VideoFilter?) {
        videoFilter = filter
        call?.setVideoFilter(filter)
    }


    nonisolated private static func handleFrameSinkOnMain(weakSelf: StreamCallManager?, frameSink: some ExternalFrameSink) {
        Task { @MainActor in
            weakSelf?.onWearableFrameSinkReady(frameSink)
        }
    }

    // MARK: - Wearable Frame Pump

    private func onWearableFrameSinkReady(_ frameSink: some ExternalFrameSink) {
        wearableFrameSink = frameSink
        print("[Stream] ✅ Frame sink ready, wiring up wearable frame forwarding")
        print("[Stream] Frame sink type: \(type(of: frameSink))")
        
        // Attach push-based frame forwarding from WearablesManager to the ExternalFrameSink
        wearablesManager?.onFrameForSink = { [weak self] ciImage in
            guard let self = self else { return }
            guard let sink = self.wearableFrameSink else {
                print("[Stream] Warning: Received frame but frame sink is nil")
                return
            }
            guard self.wearablesManager?.isStreaming == true else {
                print("[Stream] Warning: Received frame but wearable stream is not active")
                return
            }
            
            let quality = self.wearablesManager?.wearableVideoQuality ?? .low
            if let pixelBuffer = WearableFramePump.makePixelBuffer(from: ciImage, resolution: quality) {
                sink.pushFrame(pixelBuffer: pixelBuffer, rotation: .none)
                // Log first few frames to confirm pushing is working
                self.frameCount += 1
                if self.frameCount <= 5 || self.frameCount % 30 == 0 {
                    print("[Stream] Pushed frame #\(self.frameCount) to video track")
                }
            }
        }
        
        // Log current state for debugging
        if let wearables = wearablesManager {
            print("[Stream] Wearable stream active: \(wearables.isStreaming)")
            print("[Stream] Wearable stream state: \(wearables.streamState)")
        }
    }

    private func stopWearableFramePump() {
        // Detach push-based frame forwarding
        wearablesManager?.onFrameForSink = nil
        wearableFrameSink = nil
    }

    // MARK: - Cleanup

    func disconnect() async {
        stopWearableFramePump()
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        if isInCall {
            await leaveCall()
        }
        await streamVideo?.disconnect()
        await MainActor.run { [weak self] in
            self?.streamVideo = nil
            self?.isConnected = false
        }
    }
}

