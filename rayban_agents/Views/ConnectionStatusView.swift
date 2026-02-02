//
//  ConnectionStatusView.swift
//  rayban_agents
//
//  Displays connection status for both Meta Wearables and Stream Video.
//

import SwiftUI
import MWDATCore

struct ConnectionStatusView: View {
    let wearablesManager: WearablesManager
    let streamManager: StreamCallManager
    let onRegister: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // Wearables Status
            StatusCard(
                title: "Meta Wearables",
                icon: "eyeglasses",
                status: wearablesStatusText,
                statusColor: wearablesStatusColor,
                action: wearablesAction
            )
            
            // Stream Video Status
            StatusCard(
                title: "Stream Video",
                icon: "video.fill",
                status: streamStatusText,
                statusColor: streamStatusColor,
                action: nil
            )
            
            // Device List
            if !wearablesManager.devices.isEmpty {
                DeviceListSection(devices: wearablesManager.devices)
            }
        }
        .padding()
    }
    
    // MARK: - Wearables Status
    
    private var wearablesStatusText: String {
        switch wearablesManager.registrationState {
        case .notRegistered:
            return "Not Registered"
        case .registrationPending:
            return "Registering..."
        case .registered:
            if wearablesManager.hasConnectedDevice {
                return "Connected"
            }
            return "Registered (No Device)"
        case .unregistrationPending:
            return "Unregistering..."
        @unknown default:
            return "Unknown"
        }
    }
    
    private var wearablesStatusColor: Color {
        switch wearablesManager.registrationState {
        case .notRegistered:
            return .secondary
        case .registrationPending, .unregistrationPending:
            return .orange
        case .registered:
            return wearablesManager.hasConnectedDevice ? .green : .yellow
        @unknown default:
            return .secondary
        }
    }
    
    private var wearablesAction: (() -> Void)? {
        switch wearablesManager.registrationState {
        case .notRegistered:
            return onRegister
        case .registered:
            return { wearablesManager.startUnregistration() }
        default:
            return nil
        }
    }
    
    // MARK: - Stream Status
    
    private var streamStatusText: String {
        if streamManager.isConnected {
            return "Connected"
        } else if streamManager.error != nil {
            return "Error"
        }
        return "Connecting..."
    }
    
    private var streamStatusColor: Color {
        if streamManager.isConnected {
            return .green
        } else if streamManager.error != nil {
            return .red
        }
        return .orange
    }
}

// MARK: - Status Card

private struct StatusCard: View {
    let title: String
    let icon: String
    let status: String
    let statusColor: Color
    let action: (() -> Void)?
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if let action {
                Button(action: action) {
                    Text(actionButtonText)
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var actionButtonText: String {
        if title == "Meta Wearables" {
            return status == "Not Registered" ? "Register" : "Unregister"
        }
        return "Action"
    }
}

// MARK: - Device List

private struct DeviceListSection: View {
    let devices: [Device]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connected Devices")
                .font(.headline)
            
            ForEach(devices, id: \.id) { device in
                HStack {
                    Image(systemName: "eyeglasses")
                        .foregroundStyle(.blue)
                    
                    Text(device.name)
                        .font(.subheadline)
                    
                    Spacer()
                    
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
