import Foundation
import AVFoundation
import CoreImage
import MetalPerformanceShaders
import Metal

/// Pure, native Apple Silicon (Metal & AVFoundation) Video/Image Upscaling Engine.
/// Runs 100% on local M-series hardware without external or cloud dependencies.
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
            case .exportFailed(let reason): return "Local Metal upscale failed: \(reason)"
            }
        }
    }

    /// Upscales a video or image file locally on Apple Silicon GPU using Metal Performance Shaders / CoreImage.
    func upscale(
        inputURL: URL,
        outputURL: URL,
        scaleFactor: CGFloat = 2.0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw UpscaleError.fileNotFound
        }

        let isImage = ClipType(fileExtension: inputURL.pathExtension) == .image
        if isImage {
            return try await upscaleImage(inputURL: inputURL, outputURL: outputURL, scaleFactor: scaleFactor)
        } else {
            return try await upscaleVideo(inputURL: inputURL, outputURL: outputURL, scaleFactor: scaleFactor, progress: progress)
        }
    }

    // MARK: - Image Upscaling

    private func upscaleImage(
        inputURL: URL,
        outputURL: URL,
        scaleFactor: CGFloat
    ) async throws -> URL {
        guard let ciImage = CIImage(contentsOf: inputURL) else {
            throw UpscaleError.invalidTrack
        }

        let transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        let scaledImage = ciImage.transformed(by: transform)
        let colorSpace = ciImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let jpegData = ciContext.jpegRepresentation(of: scaledImage, colorSpace: colorSpace, options: [:]) {
            try jpegData.write(to: outputURL)
        }

        return outputURL
    }

    // MARK: - Video Frame-by-Frame Metal Upscaling

    private func upscaleVideo(
        inputURL: URL,
        outputURL: URL,
        scaleFactor: CGFloat,
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

        let processor = VideoProcessor(
            readerOutput: readerOutput,
            writerInput: writerInput,
            adaptor: adaptor,
            ciContext: ciContext
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

    init(
        readerOutput: AVAssetReaderTrackOutput,
        writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        ciContext: CIContext
    ) {
        self.readerOutput = readerOutput
        self.writerInput = writerInput
        self.adaptor = adaptor
        self.ciContext = ciContext
    }

    func process(scaleFactor: CGFloat, durationSeconds: Double, progress: (@Sendable (Double) -> Void)?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "io.palmier.metal.upscale", qos: .userInitiated)
            writerInput.requestMediaDataWhenReady(on: queue) {
                while self.writerInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = self.readerOutput.copyNextSampleBuffer() else {
                        self.writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }

                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    if durationSeconds > 0 {
                        let currentSecs = CMTimeGetSeconds(presentationTime)
                        progress?(min(1.0, currentSecs / durationSeconds))
                    }

                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        continue
                    }

                    let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                    let transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
                    let scaledCI = ciImage.transformed(by: transform)

                    var outPixelBuffer: CVPixelBuffer?
                    if let pool = self.adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPixelBuffer)
                    }

                    if let outPixelBuffer {
                        self.ciContext.render(scaledCI, to: outPixelBuffer)
                        self.adaptor.append(outPixelBuffer, withPresentationTime: presentationTime)
                    }
                }
            }
        }
    }
}
