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

private enum WearablesManagerError: Error, CustomStringConvertible {
    case streamCreationFailed
    case cameraPermissionNotGranted
    case noConnectedDevice

    var description: String {
        switch self {
        case .streamCreationFailed:
            return "Unable to create wearable camera stream"
        case .cameraPermissionNotGranted:
            return "Camera permission not granted for the glasses"
        case .noConnectedDevice:
            return "No link-connected glasses camera device"
        }
    }
}

@Observable
final class WearablesManager {
    
    // MARK: - Published State
    
    private(set) var registrationState: RegistrationState = .available
    private(set) var deviceIdentifiers: [DeviceIdentifier] = []
    private(set) var streamState: StreamState = .stopped
    private(set) var cameraPermissionStatus: PermissionStatus = .denied
    private(set) var latestFrame: UIImage?
    private(set) var isStreaming = false
    private(set) var wearableVideoQuality: StreamingResolution = .low
    private(set) var lastCaptureSaveResult: Bool?
    private(set) var streamStartError: Error?
    /// Set when the glasses report their on-device DAT app is out of date
    /// (DeviceSessionError.datAppOnTheGlassesUpdateRequired). Drives the update prompt.
    private(set) var needsDATGlassesAppUpdate = false

    // Non-UI frame delivery for the Stream video filter path.
    var onFrame: ((CIImage) -> Void)?

    // Throttling for UI preview to reduce churn
    private var previewFrameCounter = 0
    private let previewFrameStride = 3 // update UI preview every 3 frames (~8 fps at 24 fps source)
    
    // MARK: - Private Properties
    
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var stateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var photoDataToken: AnyListenerToken?
    private var streamErrorToken: AnyListenerToken?
    private var sessionErrorTask: Task<Void, Never>?
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

    /// Human-readable guidance for the most recent stream-start failure.
    /// The underlying MWDAT errors ("noEligibleDevice", "streamCreationFailed", …)
    /// are about the glasses connection, not video quality.
    var streamStartErrorMessage: String {
        guard let error = streamStartError else { return "" }
        // Match on typed SDK errors rather than sniffing String(describing:).
        // `needsDATGlassesAppUpdate` is the sticky signal set from the typed
        // DeviceSessionError.datAppOnTheGlassesUpdateRequired comparison.
        if needsDATGlassesAppUpdate {
            return "Your glasses' Device Access app is out of date. Tap “Update glasses app” to open the Meta AI update screen, install it (keep Meta AI open ~10s), then tap Join again."
        }
        switch error {
        case WearablesManagerError.cameraPermissionNotGranted:
            return "Camera access to the glasses isn't granted yet. Approve the camera prompt (on your phone or in the Meta AI app), then tap Join again."
        case PermissionError.metaAINotInstalled:
            return "The Meta AI app is required. Install it, connect your Ray-Ban glasses there, then tap Join again."
        case WearablesManagerError.noConnectedDevice,
             DeviceSessionError.noEligibleDevice,
             DeviceSessionError.dwaUnavailable:
            return "Glasses camera isn't connected yet. In the Meta AI app make sure the glasses show a live connection, keep them awake and on the same Wi-Fi, then tap Join again. (Bluetooth audio alone isn't enough — the camera uses a separate Wi-Fi link.)"
        case WearablesManagerError.streamCreationFailed:
            return "Couldn't start the camera stream. Wake/wear the glasses, confirm they're connected in the Meta AI app, and keep the phone on Wi-Fi, then try again."
        default:
            return "Glasses camera error: \(error)"
        }
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

    /// Races an async `operation` against a timeout, returning whichever finishes
    /// first — the operation's value, or `timeoutValue` after `seconds`.
    private func withTimeout<T: Sendable>(
        _ seconds: Double,
        timeoutValue: T,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return timeoutValue
            }
            let first = await group.next() ?? timeoutValue
            group.cancelAll()
            return first
        }
    }

    /// Waits for the device selector to report a link-connected device, up to a
    /// timeout. Iterating `activeDeviceStream()` also keeps the selector observed
    /// (a throwaway, unobserved selector's `activeDevice` may never resolve).
    /// Returns the active `DeviceIdentifier`, or `nil` if none connects in time.
    private func firstConnectedDevice(selector: DeviceSelector, timeoutSeconds: Double) async -> DeviceIdentifier? {
        if let existing = selector.activeDevice { return existing }
        return await withTimeout(timeoutSeconds, timeoutValue: nil as DeviceIdentifier?) {
            for await id in selector.activeDeviceStream() {
                if let id { return id }
            }
            return nil
        }
    }

    /// Waits for a device session to reach `.started`, up to a timeout.
    /// Returns true if it started, false on timeout or if it stopped.
    private func waitForSessionStarted(session: DeviceSession, timeoutSeconds: Double) async -> Bool {
        if session.state == .started { return true }
        return await withTimeout(timeoutSeconds, timeoutValue: false) {
            for await state in session.stateStream() {
                print("[Wearable] Device session state: \(state)")
                if state == .started { return true }
                if state == .stopped || state == .stopping { return false }
            }
            return false
        }
    }

    func startCameraStream() async {
        await Task(priority: .utility) {
            await startCameraStreamOnBackground()
        }.value
    }

    private func startCameraStreamOnBackground() async {
        guard stream == nil, deviceSession == nil else {
            print("Stream already exists")
            return
        }
        await MainActor.run { streamStartError = nil }

        // The camera stream rides a Wi-Fi/DAT transport that is SEPARATE from the
        // Bluetooth-HFP audio link. Being registered and having glasses audio does
        // NOT mean a camera-capable device is link-connected. Wait for the selector
        // to report an active (connected) device before doing anything else —
        // otherwise requestPermission throws noDeviceWithConnection and
        // createSession throws noEligibleDevice.
        let deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
        guard let connectedDeviceId = await firstConnectedDevice(selector: deviceSelector, timeoutSeconds: 12) else {
            print("[Wearable] No link-connected camera device within timeout")
            await MainActor.run { streamStartError = WearablesManagerError.noConnectedDevice }
            return
        }
        print("[Wearable] Camera device connected: \(connectedDeviceId)")

        // Now that a device is connected, request camera permission. Requesting at
        // launch fails with noDeviceWithConnection (nothing connected yet), so the
        // grant prompt never appears there.
        do {
            let status = try await Wearables.shared.requestPermission(.camera)
            await MainActor.run { cameraPermissionStatus = status }
            guard status == .granted else {
                print("[Wearable] Camera permission not granted: \(status)")
                await MainActor.run { streamStartError = WearablesManagerError.cameraPermissionNotGranted }
                return
            }
            print("[Wearable] Camera permission granted")
        } catch {
            print("[Wearable] Camera permission request failed: \(error)")
            await MainActor.run { streamStartError = error }
            return
        }

        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: wearableVideoQuality,
            frameRate: 8
        )
        print("[Wearable] Creating stream (codec=raw, resolution=\(wearableVideoQuality), frameRate=8)")

        // Track the session so it is released on any failure, and observe the session
        // error stream so otherwise-silent failures (addStream returning nil, or the
        // session stopping — e.g. datAppOnTheGlassesUpdateRequired) surface a reason.
        var createdSession: DeviceSession?
        let session: DeviceSession
        let newStream: MWDATCamera.Stream

        do {
            let s = try Wearables.shared.createSession(deviceSelector: deviceSelector)
            createdSession = s

            sessionErrorTask?.cancel()
            sessionErrorTask = Task { [weak self] in
                var didPromptUpdate = false
                for await sessionError in s.errorStream() {
                    print("[Wearable] ⚠️ DeviceSession error: \(sessionError)")
                    await MainActor.run { self?.streamStartError = sessionError }
                    // The glasses' on-device DAT app is out of date. Deep-link the
                    // user straight to the Meta AI update screen (and flag the UI).
                    if sessionError == .datAppOnTheGlassesUpdateRequired, !didPromptUpdate {
                        didPromptUpdate = true
                        await MainActor.run { self?.needsDATGlassesAppUpdate = true }
                        await self?.openDATGlassesAppUpdate()
                    }
                }
            }

            // Start the session and wait until .started BEFORE adding the stream.
            // addStream on an .idle session returns nil silently; on 0.7 (compatible
            // with V126) the session should reach .started and addStream then works.
            print("[Wearable] Starting device session (state=\(s.state))…")
            try s.start()
            let started = await waitForSessionStarted(session: s, timeoutSeconds: 10)
            print("[Wearable] Device session state after start: \(s.state)")
            guard started else {
                throw WearablesManagerError.streamCreationFailed
            }

            guard let stream = try s.addStream(config: config) else {
                print("[Wearable] ⚠️ addStream returned nil — no Stream created")
                throw WearablesManagerError.streamCreationFailed
            }
            session = s
            newStream = stream
        } catch {
            // Let the session error stream surface the underlying reason (addStream
            // can fail silently) before tearing the session down.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            createdSession?.stop()
            sessionErrorTask?.cancel()
            sessionErrorTask = nil
            print("Failed to create wearable stream: \(error)")
            await MainActor.run {
                isStreaming = false
                latestFrame = nil
                streamStartError = error
            }
            return
        }

        deviceSession = session
        stream = newStream

        streamErrorToken = newStream.errorPublisher.listen { [weak self] streamError in
            print("[Wearable] ⚠️ Stream error: \(streamError)")
            Task { @MainActor [weak self] in self?.streamStartError = streamError }
        }

        stateToken = newStream.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousState = self.streamState
                self.streamState = state
                self.isStreaming = (state == .streaming)
                
                // Log state transitions
                if previousState != state {
                    print("[Wearable] Stream state changed: \(previousState) → \(state)")
                }
                
                // Alert if stream stops unexpectedly
                if state == .stopped || state == .paused {
                    print("[Wearable] ⚠️ Stream stopped/paused unexpectedly - state: \(state)")
                }
            }
        }

        frameToken = newStream.videoFramePublisher.listen { [weak self] frame in
            // Prefer a direct CIImage path if available; fallback via UIImage -> CGImage -> CIImage
            guard let uiImage = frame.makeUIImage(), let cg = uiImage.cgImage else { return }
            let ci = CIImage(cgImage: cg)

            // Deliver to the video filter synchronously off the main actor — the
            // filter's frame store is lock-guarded, so a per-frame main hop is wasteful.
            self?.onFrame?(ci)

            // Only the throttled UI preview assignment needs the main actor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.previewFrameCounter &+= 1
                if self.previewFrameCounter.isMultiple(of: self.previewFrameStride) {
                    self.latestFrame = uiImage
                }
            }
        }

        photoDataToken = newStream.photoDataPublisher.listen { [weak self] photoData in
            Task {
                let success = await self?.savePhotoDataToPhotos(photoData) ?? false
                await MainActor.run { [weak self] in
                    self?.lastCaptureSaveResult = success
                }
            }
        }

        // Session already started above; just start the stream.
        await newStream.start()
        print("[Wearable] Stream started; awaiting frames…")
    }

    func clearStreamStartError() {
        streamStartError = nil
        needsDATGlassesAppUpdate = false
    }

    /// Opens the Meta AI app's DAT-glasses-app update screen. This is the SDK's
    /// remediation for DeviceSessionError.datAppOnTheGlassesUpdateRequired — the
    /// on-glasses Device Access app (separate from glasses firmware) is out of date.
    func openDATGlassesAppUpdate() async {
        do {
            try await Wearables.shared.openDATGlassesAppUpdate()
            print("[Wearable] Opened Meta AI DAT glasses-app update screen")
        } catch {
            print("[Wearable] Failed to open DAT glasses-app update: \(error)")
        }
    }

    func stopCameraStream() async {
        await Task(priority: .utility) {
            await stopCameraStreamOnBackground()
        }.value
    }

    private func stopCameraStreamOnBackground() async {
        guard stream != nil || deviceSession != nil else { return }

        await stream?.stop()
        deviceSession?.stop()

        await MainActor.run { resetStreamState() }
    }

    /// Cancels the stream/session listeners and clears the associated observable
    /// state. Must be called on the main actor.
    private func resetStreamState() {
        stateToken = nil
        frameToken = nil
        photoDataToken = nil
        streamErrorToken = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        stream = nil
        deviceSession = nil
        isStreaming = false
        latestFrame = nil
        previewFrameCounter = 0
    }

    func capturePhoto() -> Bool {
        guard let stream else { return false }
        let accepted = stream.capturePhoto(format: .jpeg)
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
        return await saveImageToPhotos(image)
    }

    func saveCurrentFrameToPhotos() async -> Bool {
        guard let image = latestFrame else { return false }
        return await saveImageToPhotos(image)
    }

    private func saveImageToPhotos(_ image: UIImage) async -> Bool {
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

        // Stream.stop() is async in SDK 0.7; stop it fire-and-forget from a sync context.
        let streamToStop = stream
        Task { await streamToStop?.stop() }
        deviceSession?.stop()

        resetStreamState()
        onFrame = nil
    }
}
