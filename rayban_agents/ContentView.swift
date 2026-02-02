//
//  ContentView.swift
//  rayban_agents
//
//  Main view orchestrating wearables connection and video calls.
//

import SwiftUI
import MWDATCore
import MWDATCamera

struct ContentView: View {
    @State private var wearablesManager = WearablesManager()
    @State private var streamManager = StreamCallManager()
    @State private var videoFilter = WearableVideoFilter()
    
    @State private var callId = ""
    @State private var showingCall = false
    @State private var frameUpdateTask: Task<Void, Never>?
    
    var body: some View {
        NavigationStack {
            if showingCall {
                CallView(
                    wearablesManager: wearablesManager,
                    streamManager: streamManager,
                    onLeaveCall: leaveCall
                )
            } else {
                mainContent
            }
        }
        .onAppear {
            setupManagers()
        }
        .onDisappear {
            cleanup()
        }
        .onOpenURL { url in
            Task {
                await wearablesManager.handleCallback(url: url)
            }
        }
    }
    
    // MARK: - Main Content
    
    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                headerSection
                
                // Connection Status
                ConnectionStatusView(
                    wearablesManager: wearablesManager,
                    streamManager: streamManager,
                    onRegister: {
                        wearablesManager.startRegistration()
                    }
                )
                
                // Call Section
                if canStartCall {
                    callSection
                }
            }
            .padding()
        }
        .navigationTitle("Wearables Call")
        .navigationBarTitleDisplayMode(.large)
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 50))
                .foregroundStyle(.blue)
            
            Text("Stream from your Ray-Ban Meta glasses")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }
    
    // MARK: - Call Section
    
    private var callSection: some View {
        VStack(spacing: 16) {
            Text("Start a Call")
                .font(.headline)
            
            TextField("Enter Call ID", text: $callId)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            
            Button {
                Task {
                    await startCall()
                }
            } label: {
                HStack {
                    Image(systemName: "video.fill")
                    Text("Join Call")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(callId.isEmpty)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Computed Properties
    
    private var canStartCall: Bool {
        wearablesManager.isRegistered && streamManager.isConnected
    }
    
    // MARK: - Methods
    
    private func setupManagers() {
        wearablesManager.configure()
        
        Task {
            await streamManager.setup()
            await wearablesManager.checkCameraPermission()
            
            if wearablesManager.cameraPermissionStatus != .granted {
                await wearablesManager.requestCameraPermission()
            }
        }
    }
    
    private func startCall() async {
        streamManager.setVideoFilter(videoFilter.makeVideoFilter())
        startFrameForwarding()

        await wearablesManager.startCameraStream()
        await streamManager.createAndJoinCall(callId: callId)
        await streamManager.enableCameraWithWearableFilter()

        await MainActor.run {
            showingCall = true
        }
    }
    
    private func leaveCall() async {
        await wearablesManager.stopCameraStream()
        await streamManager.leaveCall()
        
        stopFrameForwarding()
        
        await MainActor.run {
            showingCall = false
            callId = ""
        }
    }
    
    private func startFrameForwarding() {
        frameUpdateTask = Task {
            while !Task.isCancelled {
                if let frame = wearablesManager.latestFrameAsCIImage {
                    videoFilter.updateFrame(frame)
                }
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 FPS
            }
        }
    }
    
    private func stopFrameForwarding() {
        frameUpdateTask?.cancel()
        frameUpdateTask = nil
        videoFilter.updateFrame(nil as CIImage?)
    }
    
    private func cleanup() {
        stopFrameForwarding()
        wearablesManager.cleanup()
        Task {
            await streamManager.disconnect()
        }
    }
}

#Preview {
    ContentView()
}
