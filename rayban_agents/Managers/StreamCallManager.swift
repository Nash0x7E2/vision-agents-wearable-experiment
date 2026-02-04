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
    private var framePumpTask: Task<Void, Never>?

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

        let customProvider = ExternalVideoCapturerProvider { [weak self] frameSink in
            Task { @MainActor in
                self?.onWearableFrameSinkReady(frameSink)
            }
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
            try await video.connect()
            await MainActor.run { [weak self] in
                self?.isConnected = true
            }
        } catch {
            await MainActor.run { [weak self] in
                self?.error = error
                self?.isConnected = false
            }
            print("Failed to connect to Stream: \(error)")
        }
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
            setPreferredInputToWearable(audioSession: audioSession)
            try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
        } catch {
            print("[Audio] Failed to configure audio session: \(error)")
            self.error = error
        }
    }
    
    private func setPreferredInputToWearable(audioSession: AVAudioSession) {
        guard let inputs = audioSession.availableInputs else { return }
        let wearable = inputs.first { $0.portType == .bluetoothHFP }
        guard let wearable else { return }
        do {
            try audioSession.setPreferredInput(wearable)
        } catch {
            print("Failed to set preferred input to wearable: \(error)")
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
            print("[Stream] Joining call: \(callId) (type: \(callType))")
            setPreferredInputToWearable(audioSession: AVAudioSession.sharedInstance())
            try await newCall.join(create: true, callSettings: callSettings)
            print("[Stream] Successfully joined call: \(callId)")
            print("[Stream] Participant count: \(newCall.state.participantCount ?? 0)")
            print("[Stream] Local participant ID: \(newCall.state.localParticipant?.id ?? "unknown")")
            try await newCall.speaker.enableSpeakerPhone()
            try? await newCall.speaker.enableAudioOutput()
            setPreferredInputToWearable(audioSession: AVAudioSession.sharedInstance())
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            await MainActor.run { [weak self] in
                guard let this = self else { return }
                this.isInCall = true
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

        if let baseURL = Secrets.backendBaseURL, !baseURL.isEmpty {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                let sessionId = try await startBackendSession(callId: callId, callType: callType, baseURL: baseURL)
                await MainActor.run { [weak self] in
                    self?.currentAgentSessionId = sessionId
                    self?.currentBackendCallId = callId
                }
            } catch {
                print("Backend start session failed (user is already in call): \(error)")
                await MainActor.run { [weak self] in
                    self?.currentAgentSessionId = nil
                    self?.currentBackendCallId = nil
                }
            }
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
            request.httpBody = try JSONEncoder().encode(AgentJoinRequest(callId: callId, userId: userId))
        } else {
            request.httpBody = try JSONEncoder().encode(StartSessionRequest(call_id: callId, call_type: callType))
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
            let decoded = try JSONDecoder().decode(AgentJoinResponse.self, from: data)
            guard decoded.success, let agentId = decoded.agentId else {
                throw BackendAPIError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
            }
            return agentId
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let withoutFractional = ISO8601DateFormatter()
            guard let date = withFractional.date(from: str) ?? withoutFractional.date(from: str) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601: \(str)")
            }
            return date
        }
        let decoded = try decoder.decode(StartSessionResponse.self, from: data)
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
        do {
            print("[Stream] Enabling camera for call: \(call.callId)")
            try await call.camera.enable()
            print("[Stream] Camera enabled successfully")
            print("[Stream] Audio track publishing: \(call.state.localParticipant?.hasAudio ?? false)")
            print("[Stream] Video track publishing: \(call.state.localParticipant?.hasVideo ?? false)")
            await MainActor.run { [weak self] in
                self?.isCameraEnabled = true
            }
        } catch {
            print("[Stream] Failed to enable camera: \(error)")
            self.error = error
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

    // MARK: - Wearable Frame Pump

    private func onWearableFrameSinkReady(_ frameSink: some ExternalFrameSink) {
        wearableFrameSink = frameSink
        startWearableFramePump()
    }

    private func startWearableFramePump() {
        guard wearableFrameSink != nil, let wm = wearablesManager else { return }
        framePumpTask?.cancel()
        framePumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let sink = self?.wearableFrameSink,
                      let ciImage = wm.latestFrameAsCIImage,
                      let pixelBuffer = WearableFramePump.makePixelBuffer(from: ciImage, resolution: wm.wearableVideoQuality)
                else {
                    try? await Task.sleep(nanoseconds: 33_000_000)
                    continue
                }
                sink.pushFrame(pixelBuffer: pixelBuffer, rotation: .none)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func stopWearableFramePump() {
        framePumpTask?.cancel()
        framePumpTask = nil
        wearableFrameSink = nil
    }

    // MARK: - Cleanup

    func disconnect() async {
        stopWearableFramePump()
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
