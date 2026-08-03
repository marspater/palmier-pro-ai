import Foundation
import CoreML
import CoreImage
import Metal
import AVFoundation

/// Core ML Apple Neural Engine (ANE) Super-Resolution Engine.
/// Configured with `.cpuAndNeuralEngine` for zero-latency ANE hardware execution.
final class CoreMLUpscaler: @unchecked Sendable {
    static let shared = CoreMLUpscaler()

    enum ModelArchitecture: String, CaseIterable, Sendable {
        case piperSR = "piper-sr-x2"
        case realESRGAN = "realesrgan-x4plus"

        var displayName: String {
            switch self {
            case .piperSR: return "PiperSR (ANE Native Real-time)"
            case .realESRGAN: return "Real-ESRGAN x4plus (Generative Detail)"
            }
        }

        var scaleFactor: CGFloat {
            switch self {
            case .piperSR: return 2.0
            case .realESRGAN: return 4.0
            }
        }

        var downloadURL: URL? {
            switch self {
            case .piperSR:
                return URL(string: "https://models.palmier.io/coreml/piper-sr-x2.mlmodelc.zip")
            case .realESRGAN:
                return URL(string: "https://models.palmier.io/coreml/realesrgan-x4plus.mlmodelc.zip")
            }
        }
    }

    private let tileSize: Int = 512
    private let tileOverlap: Int = 16
    private var activeModel: MLModel?
    private var activeArchitecture: ModelArchitecture?
    private var previousFrameHistory: CIImage?

    private init() {}

    /// Directory where compiled Core ML super-resolution models are cached.
    var modelsDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("PalmierPro/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Check if a model is downloaded and ready for ANE inference locally.
    func isModelAvailable(_ model: ModelArchitecture) -> Bool {
        let compiledURL = modelsDirectory.appendingPathComponent("\(model.rawValue).mlmodelc")
        return FileManager.default.fileExists(atPath: compiledURL.path)
    }

    /// Loads the specified Core ML model onto the Apple Neural Engine (`.cpuAndNeuralEngine`).
    func loadModel(_ architecture: ModelArchitecture) throws {
        if activeArchitecture == architecture, activeModel != nil {
            return
        }

        let compiledURL = modelsDirectory.appendingPathComponent("\(architecture.rawValue).mlmodelc")
        guard FileManager.default.fileExists(atPath: compiledURL.path) else {
            throw NSError(domain: "CoreMLUpscaler", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Core ML model \(architecture.rawValue) is not installed."
            ])
        }

        let config = MLModelConfiguration()
        // CRITICAL ANE TARGETING: Lock execution to CPU and Neural Engine.
        // Avoid setting .all to prevent Core ML from misrouting ANE ops to GPU and causing latency.
        config.computeUnits = .cpuAndNeuralEngine

        self.activeModel = try MLModel(contentsOf: compiledURL, configuration: config)
        self.activeArchitecture = architecture
    }

    /// Resets the temporal EMA frame history (called at start of video processing or scene boundary).
    func resetTemporalHistory() {
        previousFrameHistory = nil
    }

    // MARK: - Core ML Tile-Based Inference Engine

    /// Upscales a frame using tile-based division, ANE Core ML inference, overlap cropping, and unsharp masking.
    func upscale(
        image inputImage: CIImage,
        architecture: ModelArchitecture = .piperSR,
        ciContext: CIContext,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> CIImage {
        try loadModel(architecture)
        guard let model = activeModel else {
            return inputImage
        }

        let scale = architecture.scaleFactor
        let extent = inputImage.extent
        guard extent.width > 0, extent.height > 0 else { return inputImage }

        let width = Int(extent.width)
        let height = Int(extent.height)

        // Calculate grid counts for 512x512 tiling with 16px overlap padding
        let cols = Int(ceil(Double(width) / Double(tileSize)))
        let rows = Int(ceil(Double(height) / Double(tileSize)))
        let totalTiles = max(1, cols * rows)

        var tileImages: [CIImage] = []
        var tileIndex = 0

        let cropKernel = CIKernelLoader.kernel("SuperResolutionTiling", "tileCropOverlap")
        let unsharpKernel = CIKernelLoader.kernel("SuperResolutionTiling", "unsharpMask")

        for row in 0..<rows {
            for col in 0..<cols {
                // Calculate padded tile bounds in source image coordinates
                let x0 = max(0, col * tileSize - tileOverlap)
                let y0 = max(0, row * tileSize - tileOverlap)
                let x1 = min(width, (col + 1) * tileSize + tileOverlap)
                let y1 = min(height, (row + 1) * tileSize + tileOverlap)

                let tileW = x1 - x0
                let tileH = y1 - y0

                let padLeft = CGFloat(col * tileSize - x0)
                let padBottom = CGFloat(row * tileSize - y0)

                let tileCropRect = CGRect(x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(tileW), height: CGFloat(tileH))
                let croppedTileInput = inputImage.cropped(to: tileCropRect)

                // Render tile into CVPixelBuffer for zero-copy Core ML transfer
                var pixelBuffer: CVPixelBuffer?
                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: tileW,
                    kCVPixelBufferHeightKey as String: tileH,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                ]
                CVPixelBufferCreate(kCFAllocatorDefault, tileW, tileH, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)

                if let pixelBuffer {
                    ciContext.render(croppedTileInput, to: pixelBuffer)

                    // Execute Core ML model inference on ANE
                    let inputFeature = try MLDictionaryFeatureProvider(dictionary: ["image": pixelBuffer])
                    let outputFeature = try await model.prediction(from: inputFeature)

                    if let outputPixelBuffer = outputFeature.featureValue(for: "output")?.imageBufferValue {
                        var tileCI = CIImage(cvPixelBuffer: outputPixelBuffer)

                        // Crop overlap border if tile was padded
                        if padLeft > 0 || padBottom > 0, let cropKernel {
                            let outPadLeft = padLeft * scale
                            let outPadBottom = padBottom * scale
                            let targetW = CGFloat(tileSize) * scale
                            let targetH = CGFloat(tileSize) * scale

                            let cropArgs: [Any] = [tileCI, outPadLeft, outPadBottom]
                            tileCI = cropKernel.apply(
                                extent: CGRect(x: 0, y: 0, width: targetW, height: targetH),
                                roiCallback: { _, rect in rect },
                                arguments: cropArgs
                            ) ?? tileCI
                        }

                        // Position stitched tile into output high-res canvas space
                        let destX = CGFloat(col * tileSize) * scale
                        let destY = CGFloat(row * tileSize) * scale
                        let placedTile = tileCI.transformed(by: CGAffineTransform(translationX: destX, y: destY))
                        tileImages.append(placedTile)
                    } else {
                        // Fallback: scale tile directly if output buffer is unavailable
                        let scaledTile = croppedTileInput.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        tileImages.append(scaledTile)
                    }
                }

                tileIndex += 1
                progress?(Double(tileIndex) / Double(totalTiles))
            }
        }

        // Composite all upscaled tiles together
        var compositeImage = tileImages.first ?? inputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        for i in 1..<tileImages.count {
            compositeImage = tileImages[i].composited(over: compositeImage)
        }

        // Apply unsharp mask edge contrast sharpening
        if let unsharpKernel {
            let unsharpArgs: [Any] = [compositeImage, Float(0.35)] // 35% edge contrast boost
            compositeImage = unsharpKernel.apply(
                extent: compositeImage.extent,
                roiCallback: { _, rect in rect },
                arguments: unsharpArgs
            ) ?? compositeImage
        }

        return compositeImage
    }

    // MARK: - Temporal EMA Anti-Flicker Filter Pass

    /// Applies exponential moving average temporal smoothing to eliminate frame flicker in video sequences.
    func applyTemporalEMA(_ currentFrame: CIImage, alpha: CGFloat = 0.85) -> CIImage {
        guard let prev = previousFrameHistory,
              let emaKernel = CIKernelLoader.kernel("TemporalEMA", "temporalEMAFilter") else {
            previousFrameHistory = currentFrame
            return currentFrame
        }

        let args: [Any] = [currentFrame, prev, Float(alpha)]
        let blendedFrame = emaKernel.apply(
            extent: currentFrame.extent,
            roiCallback: { _, rect in rect },
            arguments: args
        ) ?? currentFrame

        previousFrameHistory = blendedFrame
        return blendedFrame
    }
}
