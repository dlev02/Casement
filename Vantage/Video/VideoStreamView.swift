import AVFoundation
import CoreMedia
import SwiftUI
import VantageCore
import os

/// Renders the remote video stream with `AVSampleBufferDisplayLayer` using latest-frame-wins
/// (`DisplayImmediately`). Rebuilds the format description whenever parameter sets change and
/// recovers from decode failures by flushing and requesting a keyframe from the host.
nonisolated final class VideoStreamController: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "video")
    private var formatDescription: CMFormatDescription?
    private var currentConfig: VideoConfig?
    private let queue = DispatchQueue(label: "vantage.decode", qos: .userInteractive)

    // Stats for the feedback channel.
    private var framesReceived: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private var lastDecodeMillis: Double = 0

    var onNeedsKeyframe: (() -> Void)?

    init() {
        displayLayer.videoGravity = .resizeAspect
        #if canImport(UIKit)
        displayLayer.backgroundColor = UIColor.black.cgColor
        #endif
        observeFailures()
    }

    func consume(_ message: Message) {
        switch message {
        case .videoConfig(let config):
            queue.async { self.applyConfig(config) }
        case .videoFrame(let frame):
            queue.async { self.enqueue(frame) }
        default:
            break
        }
    }

    func snapshotStats(windowSeconds: Double, rttMillis: Double) -> QualityFeedback {
        queue.sync {
            let feedback = QualityFeedback(
                rttMillis: rttMillis,
                decodeMillis: lastDecodeMillis,
                framesReceived: framesReceived,
                framesDropped: framesDropped,
                queueDepth: 0,
                bytesReceived: bytesReceived,
                windowSeconds: windowSeconds
            )
            framesReceived = 0
            framesDropped = 0
            bytesReceived = 0
            return feedback
        }
    }

    private func applyConfig(_ config: VideoConfig) {
        currentConfig = config
        formatDescription = Self.makeFormatDescription(config)
        if formatDescription == nil {
            log.error("failed to build format description")
        }
    }

    private func enqueue(_ frame: VideoFrame) {
        bytesReceived &+= UInt64(frame.data.count)
        guard let formatDescription else {
            // Can't decode without parameter sets; ask the host for a keyframe.
            onNeedsKeyframe?()
            return
        }
        guard let sampleBuffer = Self.makeSampleBuffer(data: frame.data, formatDescription: formatDescription) else {
            framesDropped &+= 1
            return
        }
        // Latest-frame-wins.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            onNeedsKeyframe?()
        }
        renderer.enqueue(sampleBuffer)
        lastDecodeMillis = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        framesReceived &+= 1
    }

    private func observeFailures() {
        NotificationCenter.default.addObserver(forName: Notification.Name("AVSampleBufferVideoRendererDidFailToDecodeNotification"), object: displayLayer.sampleBufferRenderer, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.displayLayer.sampleBufferRenderer.flush()
                self?.onNeedsKeyframe?()
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("AVSampleBufferVideoRendererRequiresFlushToResumeDecodingDidChangeNotification"), object: displayLayer.sampleBufferRenderer, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.displayLayer.sampleBufferRenderer.flush()
                self?.onNeedsKeyframe?()
            }
        }
    }

    static func makeFormatDescription(_ config: VideoConfig) -> CMFormatDescription? {
        guard !config.parameterSets.isEmpty else { return nil }
        var format: CMFormatDescription?
        return config.parameterSets.withContiguousParameterSets { ptrs, szs in
            let status: OSStatus
            if config.codec == .hevc {
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs, parameterSetSizes: szs, nalUnitHeaderLength: Int32(config.nalLengthSize), extensions: nil, formatDescriptionOut: &format)
            } else {
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs, parameterSetSizes: szs, nalUnitHeaderLength: Int32(config.nalLengthSize), formatDescriptionOut: &format)
            }
            return status == noErr ? format : nil
        }
    }

    static func makeSampleBuffer(data: Data, formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        let length = data.count
        // Allocate a block buffer that owns its memory, then copy the access unit into it. This
        // avoids any lifetime coupling to the source `Data`.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}

nonisolated private extension Array where Element == Data {
    /// Runs `body` with parallel arrays of base pointers and sizes valid for its duration.
    func withContiguousParameterSets<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        func recurse(_ index: Int, _ ptrs: [UnsafePointer<UInt8>], _ szs: [Int]) -> R {
            if index == count { return body(ptrs, szs) }
            return self[index].withUnsafeBytes { raw in
                recurse(index + 1, ptrs + [raw.bindMemory(to: UInt8.self).baseAddress!], szs + [self[index].count])
            }
        }
        return recurse(0, [], [])
    }
}

#if canImport(UIKit)
import UIKit

/// SwiftUI wrapper hosting the display layer.
struct VideoStreamView: UIViewRepresentable {
    let controller: VideoStreamController

    func makeUIView(context: Context) -> VideoHostingView {
        let view = VideoHostingView()
        view.attach(controller.displayLayer)
        return view
    }

    func updateUIView(_ uiView: VideoHostingView, context: Context) {}
}

final class VideoHostingView: UIView {
    private var displayLayer: AVSampleBufferDisplayLayer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer?.removeFromSuperlayer()
        layer.frame = bounds
        self.layer.addSublayer(layer)
        displayLayer = layer
        backgroundColor = .black
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
#endif
