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
            guard let self else {
                return CIImage(color: CIColor.black).cropped(to: input.originalImage.extent)
            }
            
            if let wearableFrame = self.latestFrame {
                let scaledFrame = self.scaleToFill(
                    image: wearableFrame,
                    targetExtent: input.originalImage.extent
                )
                return scaledFrame
            }
            
            return self.blackFrame(extent: input.originalImage.extent)
        }
    }
    
    // MARK: - Private Methods
    
    private func scaleToFill(image: CIImage, targetExtent: CGRect) -> CIImage {
        let sourceSize = image.extent.size
        let targetSize = targetExtent.size
        
        guard sourceSize.width > 0, sourceSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else {
            return blackFrame(extent: targetExtent)
        }
        
        let scaleX = targetSize.width / sourceSize.width
        let scaleY = targetSize.height / sourceSize.height
        let scale = max(scaleX, scaleY)
        
        let normalizedImage = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        )
        let scaledImage = normalizedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        let scaledSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let offsetX = targetExtent.minX + (targetSize.width - scaledSize.width) / 2
        let offsetY = targetExtent.minY + (targetSize.height - scaledSize.height) / 2
        
        return scaledImage
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: targetExtent)
    }
    
    private func blackFrame(extent: CGRect) -> CIImage {
        CIImage(color: CIColor.black).cropped(to: extent)
    }
}
