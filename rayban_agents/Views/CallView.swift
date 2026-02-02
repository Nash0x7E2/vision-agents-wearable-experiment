//
//  CallView.swift
//  rayban_agents
//
//  Active call view with video preview and controls.
//

import SwiftUI
import StreamVideo
import StreamVideoSwiftUI

struct CallView: View {
    let wearablesManager: WearablesManager
    let streamManager: StreamCallManager
    let onLeaveCall: () async -> Void
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black.ignoresSafeArea()
                
                // Video Preview
                VStack {
                    if wearablesManager.isStreaming, let frame = wearablesManager.latestFrame {
                        // Wearable Camera Preview
                        WearablePreviewView(image: frame)
                    } else {
                        // Placeholder when no wearable stream
                        PlaceholderView()
                    }
                }
                
                // Overlay UI
                VStack {
                    // Top Bar
                    CallTopBar(
                        isStreaming: wearablesManager.isStreaming,
                        streamState: wearablesManager.streamState
                    )
                    
                    Spacer()
                    
                    // Controls
                    CallControlsView(
                        isMicrophoneEnabled: streamManager.isMicrophoneEnabled,
                        isCameraEnabled: streamManager.isCameraEnabled,
                        isStreaming: wearablesManager.isStreaming,
                        onToggleMic: {
                            Task { await streamManager.toggleMicrophone() }
                        },
                        onToggleCamera: {
                            Task { await streamManager.toggleCamera() }
                        },
                        onToggleWearableStream: {
                            Task { await toggleWearableStream() }
                        },
                        onEndCall: {
                            Task { await onLeaveCall() }
                        },
                        onCapturePhoto: {
                            wearablesManager.capturePhoto()
                        }
                    )
                    .padding(.bottom, geometry.safeAreaInsets.bottom + 20)
                }
            }
        }
        .ignoresSafeArea()
    }
    
    private func toggleWearableStream() async {
        if wearablesManager.isStreaming {
            await wearablesManager.stopCameraStream()
        } else {
            await wearablesManager.startCameraStream()
        }
    }
}

// MARK: - Wearable Preview

private struct WearablePreviewView: View {
    let image: UIImage
    
    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Placeholder

private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            Text("Wearable Camera Off")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("Tap the glasses button to start streaming")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Top Bar

private struct CallTopBar: View {
    let isStreaming: Bool
    let streamState: MWDATCamera.StreamSessionState
    
    var body: some View {
        HStack {
            // Stream indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(isStreaming ? .green : .secondary)
                    .frame(width: 10, height: 10)
                
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            
            Spacer()
        }
        .padding()
    }
    
    private var statusText: String {
        switch streamState {
        case .stopped:
            return "Stopped"
        case .waitingForDevice:
            return "Waiting for device..."
        case .starting:
            return "Starting..."
        case .streaming:
            return "Live"
        case .paused:
            return "Paused"
        case .stopping:
            return "Stopping..."
        @unknown default:
            return "Unknown"
        }
    }
}

import MWDATCamera
