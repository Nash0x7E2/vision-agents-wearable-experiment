//
//  WearablesManager.swift
//  rayban_agents
//
//  Manages Meta Wearables SDK integration including device registration,
//  camera streaming, and frame buffering for video calls.
//

import Foundation
import CoreImage
import SwiftUI
import Photos
import MWDATCore
import MWDATCamera

@Observable
final class WearablesManager {
    
    // MARK: - Published State
    
    private(set) var registrationState: RegistrationState = .available
    private(set) var deviceIdentifiers: [DeviceIdentifier] = []
    private(set) var streamState: StreamSessionState = .stopped
    private(set) var cameraPermissionStatus: PermissionStatus = .denied
    private(set) var latestFrame: UIImage?
    private(set) var isStreaming = false
    private(set) var wearableVideoQuality: StreamingResolution = .low
    private(set) var lastCaptureSaveResult: Bool?
    private(set) var streamStartError: Error?

    // Non-UI frame delivery for encoder/sink path
    var onFrameForSink: ((CIImage) -> Void)?

    // Throttling for UI preview to reduce churn
    private var previewFrameCounter = 0
    private let previewFrameStride = 3 // update UI preview every 3 frames (~8 fps at 24 fps source)
    
    // MARK: - Private Properties
    
    private var streamSession: StreamSession?
    private var stateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var photoDataToken: AnyListenerToken?
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    
    // MARK: - Computed Properties
    
    var isRegistered: Bool {
        registrationState == .registered
    }
    
    var hasConnectedDevice: Bool {
        !deviceIdentifiers.isEmpty
    }
    
    var latestFrameAsCIImage: CIImage? {
        guard let uiImage = latestFrame, let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Configuration
    
    func configure() {
        Task(priority: .utility) {
            do {
                try Wearables.configure()
                await MainActor.run {
                    observeRegistrationState()
                    observeDevices()
                }
            } catch {
                print("Failed to configure Wearables SDK: \(error)")
            }
        }
    }

    // MARK: - Registration

    func startRegistration() {
        Task(priority: .utility) {
            do {
                try await Wearables.shared.startRegistration()
            } catch {
                print("Failed to start registration: \(error)")
            }
        }
    }

    func startUnregistration() {
        Task(priority: .utility) {
            do {
                try await Wearables.shared.startUnregistration()
            } catch {
                print("Failed to start unregistration: \(error)")
            }
        }
    }
    
    func handleCallback(url: URL) async {
        do {
            _ = try await Wearables.shared.handleUrl(url)
        } catch {
            print("Failed to handle callback URL: \(error)")
        }
    }
    
    // MARK: - Permissions
    
    func checkCameraPermission() async {
        do {
            cameraPermissionStatus = try await Wearables.shared.checkPermissionStatus(.camera)
        } catch {
            print("Failed to check camera permission: \(error)")
            cameraPermissionStatus = .denied
        }
    }
    
    func requestCameraPermission() async {
        do {
            cameraPermissionStatus = try await Wearables.shared.requestPermission(.camera)
        } catch {
            print("Failed to request camera permission: \(error)")
            cameraPermissionStatus = .denied
        }
    }
    
    // MARK: - Camera Streaming
    
    func startCameraStream() async {
        await Task(priority: .utility) {
            await startCameraStreamOnBackground()
        }.value
    }

    private func startCameraStreamOnBackground() async {
        guard streamSession == nil else {
            print("Stream session already exists")
            return
        }
        await MainActor.run { streamStartError = nil }

        let deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: wearableVideoQuality,
            frameRate: 8
        )

        let session = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
        streamSession = session

        stateToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                let previousState = self?.streamState
                self?.streamState = state
                self?.isStreaming = (state == .streaming)
                
                // Log state transitions
                if let prev = previousState, prev != state {
                    print("[Wearable] Stream state changed: \(prev) → \(state)")
                }
                
                // Alert if stream stops unexpectedly
                if state == .stopped || state == .paused {
                    print("[Wearable] ⚠️ Stream stopped/paused unexpectedly - state: \(state)")
                }
            }
        }

        frameToken = session.videoFramePublisher.listen { [weak self] frame in
            // Prefer a direct CIImage path if available; fallback via UIImage -> CGImage -> CIImage
            guard let uiImage = frame.makeUIImage(), let cg = uiImage.cgImage else { return }
            let ci = CIImage(cgImage: cg)

            // Push to sink path immediately (non-UI)
            self?.onFrameForSink?(ci)

            // Throttle UI preview updates to reduce observable churn
            guard let self = self else { return }
            self.previewFrameCounter &+= 1
            if self.previewFrameCounter.isMultiple(of: self.previewFrameStride) {
                Task { @MainActor in
                    self.latestFrame = uiImage
                }
            }
        }

        photoDataToken = session.photoDataPublisher.listen { [weak self] photoData in
            Task {
                let success = await self?.savePhotoDataToPhotos(photoData) ?? false
                await MainActor.run {
                    self?.lastCaptureSaveResult = success
                }
            }
        }

        do {
            try await session.start()
        } catch {
            print("Failed to start wearable stream: \(error)")
            await MainActor.run {
                stateToken = nil
                frameToken = nil
                photoDataToken = nil
                streamSession = nil
                isStreaming = false
                latestFrame = nil
                streamStartError = error
            }
        }
    }

    func clearStreamStartError() {
        streamStartError = nil
    }

    func stopCameraStream() async {
        await Task(priority: .utility) {
            await stopCameraStreamOnBackground()
        }.value
    }

    private func stopCameraStreamOnBackground() async {
        guard let session = streamSession else { return }

        await session.stop()

        await MainActor.run {
            stateToken = nil
            frameToken = nil
            photoDataToken = nil
            streamSession = nil
            isStreaming = false
            latestFrame = nil
            previewFrameCounter = 0
        }
    }

    func capturePhoto() -> Bool {
        guard let session = streamSession else { return false }
        let accepted = session.capturePhoto(format: .jpeg)
        if !accepted {
            lastCaptureSaveResult = false
        }
        return accepted
    }

    func clearLastCaptureSaveResult() {
        lastCaptureSaveResult = nil
    }

    private func savePhotoDataToPhotos(_ photoData: PhotoData) async -> Bool {
        guard let image = UIImage(data: photoData.data) else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    continuation.resume(returning: false)
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { success, _ in
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func saveCurrentFrameToPhotos() async -> Bool {
        guard let image = latestFrame else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    continuation.resume(returning: false)
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { success, _ in
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func updateVideoQuality(_ resolution: StreamingResolution) async {
        await MainActor.run {
            wearableVideoQuality = resolution
        }
        guard isStreaming else { return }
        await stopCameraStream()
        await startCameraStream()
    }

    // MARK: - Private Methods
    
    private func observeRegistrationState() {
        registrationTask?.cancel()
        registrationTask = Task {
            for await state in Wearables.shared.registrationStateStream() {
                await MainActor.run {
                    self.registrationState = state
                }
            }
        }
    }
    
    private func observeDevices() {
        devicesTask?.cancel()
        devicesTask = Task {
            for await deviceList in Wearables.shared.devicesStream() {
                await MainActor.run {
                    self.deviceIdentifiers = deviceList
                }
            }
        }
    }
    
    // MARK: - Cleanup
    
    func cleanup() {
        registrationTask?.cancel()
        devicesTask?.cancel()
        stateToken = nil
        frameToken = nil
        photoDataToken = nil
        streamSession = nil
    }
}

