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
    @State private var callId = ""
    @State private var showingCall = false
    
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
            await streamManager.setup(wearablesManager: wearablesManager)
            await wearablesManager.checkCameraPermission()
            
            if wearablesManager.cameraPermissionStatus != .granted {
                await wearablesManager.requestCameraPermission()
            }
        }
    }
    
    private func startCall() async {
        streamManager.setVideoFilter(nil)
        
        // Start wearable camera stream first
        await wearablesManager.startCameraStream()
        
        // Wait for wearable stream to actually start streaming
        // The stream state changes asynchronously via listeners
        var attempts = 0
        while !wearablesManager.isStreaming && attempts < 20 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            attempts += 1
        }
        
        if !wearablesManager.isStreaming {
            print("[ContentView] Warning: Wearable stream failed to start after 2 seconds")
        } else {
            print("[ContentView] Wearable stream confirmed active, proceeding with call join")
        }
        
        // Join the call with video enabled (wearable stream is already active)
        // Use hardcoded call ID if available, otherwise use user input or generate UUID
        let effectiveCallId: String
        if let fixedId = Secrets.fixedCallId, !fixedId.isEmpty {
            effectiveCallId = fixedId
            print("[ContentView] Using hardcoded call ID: \(fixedId)")
        } else {
            let trimmedCallId = callId.trimmingCharacters(in: .whitespacesAndNewlines)
            effectiveCallId = trimmedCallId.isEmpty ? UUID().uuidString : trimmedCallId
        }
        await streamManager.createAndJoinCall(callId: effectiveCallId)
        
        // Show the call view immediately after joining
        await MainActor.run {
            showingCall = true
        }
        
        // Start backend session after call is fully established
        // This allows the agent to join the existing call
        await streamManager.startBackendSessionIfNeeded()
    }

    private func leaveCall() async {
        await wearablesManager.stopCameraStream()
        await streamManager.leaveCall()
        await MainActor.run {
            showingCall = false
            callId = ""
        }
    }

    private func cleanup() {
        wearablesManager.cleanup()
        Task {
            await streamManager.disconnect()
        }
    }
}

#Preview {
    ContentView()
}
