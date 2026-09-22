import CoreMedia
import Foundation
import VantageCore
import VideoToolbox
import os

/// Hardware H.264/HEVC encoder tuned for low-latency screen streaming.
///
/// Feeds `CVPixelBuffer`s from ScreenCaptureKit straight into a `VTCompressionSession` configured
/// with low-latency rate control, no frame reordering, and event-driven keyframes. Emits AVCC/HVCC
/// length-prefixed access units plus the parameter sets needed to build a client format description.
nonisolated final class VideoEncoder: @unchecked Sendable {
    struct Output: Sendable {
        var frame: VideoFrame
        /// Present only on the first frame and whenever the parameter sets change.
        var config: VideoConfig?
    }

    struct Configuration {
        var codec: VideoCodec
        var width: Int
        var height: Int
        var fps: Int
        var bitrateKbps: Int
        var maxQP: Int?
    }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "encoder")
    private let queue = DispatchQueue(label: "vantage.encoder", qos: .userInteractive)
    private var session: VTCompressionSession?
    private var config: Configuration
    private var sequence: UInt64 = 0
    private var lastParameterSets: [Data] = []
    private var onOutput: (@Sendable (Output) -> Void)?

    init(configuration: Configuration) {
        self.config = configuration
    }

    var currentCodec: VideoCodec { config.codec }

    func start(onOutput: @escaping @Sendable (Output) -> Void) throws {
        try queue.sync {
            self.onOutput = onOutput
            try createSession()
        }
    }

    func stop() {
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            onOutput = nil
        }
    }

    /// Encodes one frame. `forceKeyframe` requests an IDR (session start, loss, format change).
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNanos: UInt64, forceKeyframe: Bool) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            let pts = CMTime(value: CMTimeValue(ptsNanos), timescale: 1_000_000_000)
            var properties: [CFString: Any]?
            if forceKeyframe {
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!]
            }
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                duration: .invalid, frameProperties: properties as CFDictionary?,
                infoFlagsOut: nil
            ) { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer,
                      CMSampleBufferGetDataBuffer(sampleBuffer) != nil else { return }
                self?.handleEncoded(sampleBuffer, keyframe: Self.isKeyframe(sampleBuffer))
            }
            if status != noErr {
                self.log.error("encode frame failed: \(status)")
            }
        }
    }

    /// Applies a new average bitrate mid-session (adaptive control loop).
    func setBitrate(kbps: Int) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            self.config.bitrateKbps = kbps
            let bps = kbps * 1000
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps))
            let limit: [Any] = [NSNumber(value: bps / 8 * 2), NSNumber(value: 1)]
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit as CFArray)
        }
    }

    func setExpectedFrameRate(_ fps: Int) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            self.config.fps = fps
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        }
    }

    private func createSession() throws {
        let codecType: CMVideoCodecType = config.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width), height: Int32(config.height),
            codecType: codecType,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw EncoderError.sessionCreateFailed(status)
        }
        self.session = session

        func set(_ key: CFString, _ value: Any) {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: config.fps))
        // Rely on event-driven IDRs, never periodic ones (avoids the 2.4K keyframe spike).
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int.max))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: config.bitrateKbps * 1000))
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: config.bitrateKbps * 1000 / 8 * 2), NSNumber(value: 1)] as CFArray)
        if let maxQP = config.maxQP {
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, NSNumber(value: maxQP))
        }
        // Colour: pin BT.709 primaries/matrix + sRGB transfer so the client never guesses.
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if config.codec == .h264 {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        } else {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        // Absence of "NotSync" means this is a sync (key) sample.
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
        return true
    }

    // Called from the compression output handler block.
    private func handleEncoded(_ sampleBuffer: CMSampleBuffer, keyframe: Bool) {
        guard let onOutput else { return }
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr, let dataPointer else { return }
        let payload = Data(bytes: dataPointer, count: totalLength)

        var videoConfig: VideoConfig?
        if keyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let sets = Self.parameterSets(from: formatDesc, codec: config.codec)
            if !sets.isEmpty, sets != lastParameterSets {
                lastParameterSets = sets
                videoConfig = VideoConfig(codec: config.codec, width: config.width, height: config.height, parameterSets: sets, nalLengthSize: 4, fps: config.fps)
            } else if sequence == 0 {
                videoConfig = VideoConfig(codec: config.codec, width: config.width, height: config.height, parameterSets: sets, nalLengthSize: 4, fps: config.fps)
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureNanos = pts.isValid ? UInt64(max(0, pts.value)) : MonotonicClock.nanos()
        let frame = VideoFrame(sequence: sequence, captureNanos: captureNanos, isKeyframe: keyframe, width: UInt32(config.width), height: UInt32(config.height), data: payload)
        sequence &+= 1
        onOutput(Output(frame: frame, config: videoConfig))
    }

    static func parameterSets(from formatDesc: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var count = 0
        let firstStatus: OSStatus
        if codec == .hevc {
            firstStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            firstStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        guard firstStatus == noErr else { return [] }
        var sets: [Data] = []
        for index in 0 ..< count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if codec == .hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDesc, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if status == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }
}

enum EncoderError: Error {
    case sessionCreateFailed(OSStatus)
}
