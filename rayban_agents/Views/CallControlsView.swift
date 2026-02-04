//
//  CallControlsView.swift
//  rayban_agents
//
//  Call control buttons for mute, camera toggle, and ending calls.
//

import SwiftUI

struct CallControlsView: View {
    let isMicrophoneEnabled: Bool
    let isCameraEnabled: Bool
    let isStreaming: Bool
    let onToggleMic: () -> Void
    let onToggleCamera: () -> Void
    let onToggleWearableStream: () -> Void
    let onEndCall: () -> Void
    let onCapturePhoto: () -> Void
    
    var body: some View {
        HStack(spacing: 20) {
            // Microphone Toggle
            ControlButton(
                icon: isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                label: isMicrophoneEnabled ? "Mute" : "Unmute",
                isActive: isMicrophoneEnabled,
                action: onToggleMic
            )
            
            // Camera Toggle
            ControlButton(
                icon: isCameraEnabled ? "video.fill" : "video.slash.fill",
                label: isCameraEnabled ? "Camera" : "Camera Off",
                isActive: isCameraEnabled,
                action: onToggleCamera
            )
            
            // Wearable Stream Toggle
            ControlButton(
                icon: isStreaming ? "eyeglasses" : "eyeglasses",
                label: isStreaming ? "Glasses On" : "Glasses Off",
                isActive: isStreaming,
                activeColor: .blue,
                action: onToggleWearableStream
            )
            
            // Capture Photo
            ControlButton(
                icon: "camera.fill",
                label: "Photo",
                isActive: true,
                activeColor: .orange,
                action: onCapturePhoto
            )
            
            // End Call
            ControlButton(
                icon: "phone.down.fill",
                label: "End",
                isActive: true,
                activeColor: .red,
                inactiveColor: .red,
                action: onEndCall
            )
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Control Button

private struct ControlButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    var activeColor: Color = .primary
    var inactiveColor: Color = .secondary
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 50, height: 50)
                    .background(
                        Circle()
                            .fill(backgroundColor)
                    )
                
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isActive ? activeColor : inactiveColor)
    }
    
    private var backgroundColor: Color {
        if activeColor == .red {
            return .red.opacity(0.2)
        }
        return isActive ? activeColor.opacity(0.15) : Color.secondary.opacity(0.1)
    }
}

#Preview {
    CallControlsView(
        isMicrophoneEnabled: true,
        isCameraEnabled: true,
        isStreaming: false,
        onToggleMic: {},
        onToggleCamera: {},
        onToggleWearableStream: {},
        onEndCall: {},
        onCapturePhoto: {}
    )
    .padding()
}
