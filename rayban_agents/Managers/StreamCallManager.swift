//
//  StreamCallManager.swift
//  rayban_agents
//
//  Manages Stream Video SDK integration including client setup,
//  call lifecycle, audio session configuration, and video filters.
//

import Foundation
import AVFoundation
import CoreImage
import StreamVideo
import MWDATCamera

private struct StartSessionRequest: Encodable {
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
        // ISO8601DateFormatter only supports millisecond fractional seconds, but the
        // backend (pydantic + datetime.now(timezone.utc)) emits microseconds, e.g.
        // "2026-07-08T09:32:10.123456Z". Drop the fractional component and retry.
        if let dotRange = s.range(of: #"\.\d+"#, options: .regularExpression) {
            var stripped = s
            stripped.removeSubrange(dotRange)
            if let d = withoutFractional.date(from: stripped) {
                return d
            }
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
    
    private weak var wearablesManager: WearablesManager?
    @ObservationIgnored private let wearableVideoFilter: WearableVideoFilter
    @ObservationIgnored private let streamWearableVideoFilter: VideoFilter
    private var audioRouteChangeObserver: NSObjectProtocol?
    
    // MARK: - Initialization

    init() {
        let wearableVideoFilter = WearableVideoFilter()
        self.wearableVideoFilter = wearableVideoFilter
        self.streamWearableVideoFilter = wearableVideoFilter.makeVideoFilter()
    }

    // MARK: - Setup

    func setup(wearablesManager: WearablesManager? = nil) async {
        self.wearablesManager = wearablesManager
        attachWearableFrameForwarding()
        guard !isConnected || streamVideo == nil else { return }
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

        let videoConfig = VideoConfig(videoFilters: [streamWearableVideoFilter])

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
        guard audioRouteChangeObserver == nil else { return }

        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification: notification)
        }
    }

    private func removeAudioRouteChangeObserver() {
        guard let observer = audioRouteChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        audioRouteChangeObserver = nil
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
    
    @discardableResult
    func createAndJoinCall(callId: String, callType: String = "default") async -> Bool {
        guard let streamVideo else {
            print("StreamVideo not initialized")
            return false
        }
        guard isConnected else {
            print("Cannot join call: Stream client not connected")
            return false
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
        attachWearableFrameForwarding()
        newCall.setVideoFilter(streamWearableVideoFilter)

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
            print("[Stream] Participant count: \(newCall.state.participantCount)")
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
            print("[Video] Wearable frame filter active")
            print("[Video] Wearable streaming: \(wearablesManager?.isStreaming ?? false)")
            
            // Give the capture pipeline a moment to start applying wearable frames.
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
            return false
        }

        return true
    }

    private static var backendSessionsPath: String {
        Secrets.backendSessionsPath ?? "/sessions"
    }

    private static var backendUsesAgentJoinFormat: Bool {
        let path = backendSessionsPath
        return path.contains("agent") && path.contains("join")
    }

    /// Percent-encodes a call ID for use as a URL path segment.
    private static func encodedPathCallId(_ callId: String) -> String {
        callId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? callId
    }

    private func startBackendSession(callId: String, callType: String, baseURL: String) async throws -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url: URL?
        let bodyData: Data

        if Self.backendUsesAgentJoinFormat {
            let path = Self.backendSessionsPath
            let pathTrimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            url = URL(string: "\(base)/\(pathTrimmed)")
            let userId = Secrets.backendUserId ?? Secrets.streamUserId
            bodyData = try JSONCoders.encoder.encode(AgentJoinRequest(callId: callId, userId: userId))
        } else {
            // Vision Agents runner REST API: POST /calls/{call_id}/sessions
            // (call_id lives in the path; the body carries only the call type).
            url = URL(string: "\(base)/calls/\(Self.encodedPathCallId(callId))/sessions")
            bodyData = try JSONCoders.encoder.encode(StartSessionRequest(call_type: callType))
        }

        guard let url else { throw BackendAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        request.httpBody = bodyData

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
            // Vision Agents runner REST API: DELETE /calls/{call_id}/sessions/{session_id}
            guard let sessionId = currentAgentSessionId else { return }
            let callId = currentBackendCallId ?? call?.callId ?? ""
            guard !callId.isEmpty else { return }
            url = URL(string: "\(base)/calls/\(Self.encodedPathCallId(callId))/sessions/\(sessionId)")
        }
        guard let url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        _ = try? await URLSession.shared.data(for: request)
        await MainActor.run { [weak self] in
            self?.currentAgentSessionId = nil
            self?.currentBackendCallId = nil
        }
    }

    func startBackendSessionIfNeeded() async {
        guard let baseURL = Secrets.backendBaseURL, !baseURL.isEmpty else { return }
        guard let call else { return }
        
        print("[Backend] Waiting for WebRTC connection to stabilize before starting agent...")
        
        // Wait for WebRTC connection and video track to fully stabilize.
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
        detachWearableFrameForwarding()
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
        detachWearableFrameForwarding()
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
    
    // MARK: - Wearable Frame Forwarding

    private func attachWearableFrameForwarding() {
        let wearableVideoFilter = wearableVideoFilter
        wearablesManager?.onFrame = { ciImage in
            wearableVideoFilter.updateFrame(ciImage)
        }
    }

    private func detachWearableFrameForwarding() {
        wearablesManager?.onFrame = nil
        wearableVideoFilter.updateFrame(nil as CIImage?)
    }

    // MARK: - Cleanup

    func disconnect() async {
        detachWearableFrameForwarding()
        removeAudioRouteChangeObserver()
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
