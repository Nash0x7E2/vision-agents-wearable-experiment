//
//  WearableVideoFilter.swift
//  rayban_agents
//
//  Custom video filter that injects frames from Meta wearable
//  devices into the Stream Video WebRTC pipeline.
//

import Foundation
import CoreImage
import UIKit
import StreamVideo

final class WearableVideoFilter: @unchecked Sendable {
    
    // MARK: - Properties
    
    private var _latestFrame: CIImage?
    private let lock = NSLock()
    
    var latestFrame: CIImage? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _latestFrame
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _latestFrame = newValue
        }
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Frame Updates
    
    func updateFrame(_ image: UIImage?) {
        guard let uiImage = image, let cgImage = uiImage.cgImage else {
            latestFrame = nil
            return
        }
        latestFrame = CIImage(cgImage: cgImage)
    }
    
    func updateFrame(_ ciImage: CIImage?) {
        latestFrame = ciImage
    }
    
    // MARK: - VideoFilter Creation
    
    func makeVideoFilter() -> VideoFilter {
        VideoFilter(
            id: "wearable-camera",
            name: "Wearable Camera"
        ) { [weak self] input in
            guard let self else { return input.originalImage }
            
            if let wearableFrame = self.latestFrame {
                // Scale wearable frame to match expected output size if needed
                let scaledFrame = self.scaleToFit(
                    image: wearableFrame,
                    targetSize: input.originalImage.extent.size
                )
                return scaledFrame
            }
            
            // Fall back to original camera if no wearable frame available
            return input.originalImage
        }
    }
    
    // MARK: - Private Methods
    
    private func scaleToFit(image: CIImage, targetSize: CGSize) -> CIImage {
        let sourceSize = image.extent.size
        
        guard sourceSize.width > 0, sourceSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else {
            return image
        }
        
        let scaleX = targetSize.width / sourceSize.width
        let scaleY = targetSize.height / sourceSize.height
        let scale = min(scaleX, scaleY)
        
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // Center the scaled image in the target bounds
        let scaledSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let offsetX = (targetSize.width - scaledSize.width) / 2
        let offsetY = (targetSize.height - scaledSize.height) / 2
        
        return scaledImage.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
    }
}
