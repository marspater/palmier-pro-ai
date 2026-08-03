import Foundation
import AVFoundation
import CoreImage
import MetalPerformanceShaders
import Metal

/// Pure, native Apple Silicon (Core ML ANE & Metal) Video/Image Super-Resolution Upscaling Engine.
/// Runs 100% locally on M-series hardware targeting the Apple Neural Engine (`.cpuAndNeuralEngine`).
final class LocalUpscaleEngine: @unchecked Sendable {
    static let shared = LocalUpscaleEngine()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext

    private init() {
        self.device = MTLCreateSystemDefaultDevice()
        if let device {
            self.commandQueue = device.makeCommandQueue()
            self.ciContext = CIContext(mtlDevice: device, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
        } else {
            self.commandQueue = nil
            self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    enum UpscaleError: LocalizedError {
        case fileNotFound
        case invalidTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "Input media file not found."
            case .invalidTrack: return "No valid video or image track found in source asset."
            case .exportFailed(let reason): return "Local Metal/CoreML upscale failed: \(reason)"
            }
        }
    }

    /// Upscales a video or image file locally on Apple Silicon GPU/ANE using Core ML & Metal Performance Shaders.
    func upscale(
        inputURL: URL,
        outputURL: URL,
        scaleFactor: CGFloat = 2.0,
        architecture: CoreMLUpscaler.ModelArchitecture = .piperSR,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw UpscaleError.fileNotFound
        }

        let isImage = ClipType(fileExtension: inputURL.pathExtension) == .image
        if isImage {
            return try await upscaleImage(inputURL: inputURL, outputURL: outputURL, scaleFactor: scaleFactor, architecture: architecture)
        } else {
            return try await upscaleVideo(inputURL: inputURL, outputURL: outputURL, scaleFactor: scaleFactor, architecture: architecture, progress: progress)
        }
    }

    // MARK: - Image Upscaling

    private func upscaleImage(
        inputURL: URL,
        outputURL: URL,
        scaleFactor: CGFloat,
        architecture: CoreMLUpscaler.ModelArchitecture
    ) async throws -> URL {
        guard let ciImage = CIImage(contentsOf: inputURL) else {
            throw UpscaleError.invalidTrack
        }

        let scaledImage: CIImage
        if CoreMLUpscaler.shared.isModelAvailable(architecture) {
            scaledImage = try await CoreMLUpscaler.shared.upscale(
                image: ciImage,
                architecture: architecture,
                ciContext: ciContext
            )
        } else {
            // High-speed Metal hardware fallback if Core ML model is downloading/unavailable
            let transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
            scaledImage = ciImage.transformed(by: transform)
        }

        let colorSpace = ciImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let jpegData = ciContext.jpegRepresentation(of: scaledImage, colorSpace: colorSpace, options: [:]) {
            try jpegData.write(to: outputURL)
        }

        return outputURL
    }

    // MARK: - Video Frame-by-Frame Core ML ANE & Metal Upscaling

    private func upscaleVideo(
        inputURL: URL,
        outputURL: URL,
        scaleFactor: CGFloat,
        architecture: CoreMLUpscaler.ModelArchitecture,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw UpscaleError.invalidTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)

        let targetWidth = Int(naturalSize.width * scaleFactor)
        let targetHeight = Int(naturalSize.height * scaleFactor)

        let reader = try AVAssetReader(asset: asset)
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false
        if reader.canAdd(readerOutput) {
            reader.add(readerOutput)
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(targetWidth * targetHeight) * 8.0),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerOutputSettings)
        writerInput.transform = preferredTransform
        writerInput.expectsMediaDataInRealTime = false

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: bufferAttributes
        )

        if writer.canAdd(writerInput) {
            writer.add(writerInput)
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Reset temporal EMA anti-flicker frame history for new video stream
        CoreMLUpscaler.shared.resetTemporalHistory()

        let processor = VideoProcessor(
            readerOutput: readerOutput,
            writerInput: writerInput,
            adaptor: adaptor,
            ciContext: ciContext,
            architecture: architecture
        )
        await processor.process(scaleFactor: scaleFactor, durationSeconds: CMTimeGetSeconds(duration), progress: progress)

        if reader.status == .failed {
            throw UpscaleError.exportFailed(reader.error?.localizedDescription ?? "Reader failed")
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw UpscaleError.exportFailed(writer.error?.localizedDescription ?? "Writer failed")
        }

        progress?(1.0)
        return outputURL
    }
}

private final class VideoProcessor: @unchecked Sendable {
    let readerOutput: AVAssetReaderTrackOutput
    let writerInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let ciContext: CIContext
    let architecture: CoreMLUpscaler.ModelArchitecture

    init(
        readerOutput: AVAssetReaderTrackOutput,
        writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        ciContext: CIContext,
        architecture: CoreMLUpscaler.ModelArchitecture
    ) {
        self.readerOutput = readerOutput
        self.writerInput = writerInput
        self.adaptor = adaptor
        self.ciContext = ciContext
        self.architecture = architecture
    }

    func process(scaleFactor: CGFloat, durationSeconds: Double, progress: (@Sendable (Double) -> Void)?) async {
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if durationSeconds > 0 {
                let currentSecs = CMTimeGetSeconds(presentationTime)
                progress?(min(1.0, currentSecs / durationSeconds))
            }

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let processedFrame = await processFrame(imageBuffer, scaleFactor: scaleFactor)

            while !writerInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            var outPixelBuffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPixelBuffer)
            }

            if let outPixelBuffer {
                ciContext.render(processedFrame, to: outPixelBuffer)
                adaptor.append(outPixelBuffer, withPresentationTime: presentationTime)
            }
        }
        writerInput.markAsFinished()
    }

    private func processFrame(_ imageBuffer: CVImageBuffer, scaleFactor: CGFloat) async -> CIImage {
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        if CoreMLUpscaler.shared.isModelAvailable(architecture) {
            if let tileOutput = try? await CoreMLUpscaler.shared.upscale(
                image: ciImage,
                architecture: architecture,
                ciContext: ciContext
            ) {
                return CoreMLUpscaler.shared.applyTemporalEMA(tileOutput, alpha: 0.85)
            }
        }
        let transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        return ciImage.transformed(by: transform)
    }
}
