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

@Observable
final class StreamCallManager {
    
    // MARK: - Published State
    
    private(set) var isConnected = false
    private(set) var isInCall = false
    private(set) var isMicrophoneEnabled = true
    private(set) var isCameraEnabled = true
    private(set) var callState: CallState?
    private(set) var error: Error?
    
    // MARK: - Stream Video Objects
    
    private(set) var streamVideo: StreamVideo?
    private(set) var call: Call?
    
    // MARK: - Private Properties
    
    private var videoFilter: VideoFilter?
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Setup
    
    func setup() async {
        await setupAudioSession()
        setupStreamVideo()
    }
    
    private func setupStreamVideo() {
        let user = User(
            id: Secrets.streamUserId,
            name: "Wearables User",
            imageURL: nil
        )
        
        let token = UserToken(rawValue: Secrets.streamUserToken)
        
        streamVideo = StreamVideo(
            apiKey: Secrets.streamApiKey,
            user: user,
            token: token,
            tokenProvider: { result in
                result(.success(token))
            }
        )
        
        Task {
            do {
                try await streamVideo?.connect()
                await MainActor.run {
                    self.isConnected = true
                }
            } catch {
                await MainActor.run {
                    self.error = error
                    self.isConnected = false
                }
                print("Failed to connect to Stream: \(error)")
            }
        }
    }
    
    private func setupAudioSession() async {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            setPreferredInputToWearable(audioSession: audioSession)
            try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
        } catch {
            print("Failed to configure audio session: \(error)")
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
        
        let callSettings = CallSettings(
            audioOn: true,
            videoOn: false
        )
        let newCall = streamVideo.call(callType: callType, callId: callId, callSettings: callSettings)
        call = newCall

        if let filter = videoFilter {
            newCall.setVideoFilter(filter)
        }

        do {
            setPreferredInputToWearable(audioSession: AVAudioSession.sharedInstance())
            try await newCall.join(create: true, callSettings: callSettings)
            await MainActor.run {
                self.isInCall = true
                self.callState = newCall.state
            }
        } catch {
            await MainActor.run {
                self.error = error
                self.isInCall = false
            }
            print("Failed to join call: \(error)")
        }
    }

    func enableCameraWithWearableFilter() async {
        guard let call else { return }
        do {
            try await call.camera.enable()
            await MainActor.run {
                self.isCameraEnabled = true
            }
        } catch {
            print("Failed to enable camera with wearable filter: \(error)")
            self.error = error
        }
    }

    func leaveCall() async {
        guard let call else { return }
        
        call.leave()
        
        await MainActor.run {
            self.call = nil
            self.isInCall = false
            self.callState = nil
        }
    }
    
    func endCall() async {
        guard let call else { return }
        
        do {
            try await call.end()
            await MainActor.run {
                self.call = nil
                self.isInCall = false
                self.callState = nil
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
            await MainActor.run {
                self.isMicrophoneEnabled.toggle()
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
            await MainActor.run {
                self.isCameraEnabled.toggle()
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
    
    // MARK: - Cleanup
    
    func disconnect() async {
        if isInCall {
            await leaveCall()
        }
        
        await streamVideo?.disconnect()
        
        await MainActor.run {
            self.streamVideo = nil
            self.isConnected = false
        }
    }
}
