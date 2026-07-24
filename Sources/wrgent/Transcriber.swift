import Foundation
import AVFoundation
import WhisperKit

struct SegmentInfo {
    let start: Double
    let end: Double
    let text: String
}

final class TranscriptionProgressMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgressNanos = DispatchTime.now().uptimeNanoseconds
    private var lastSignature: String?
    private var cancelled = false

    func markProgress(signature: String? = nil) {
        lock.lock()
        if let signature, signature == lastSignature {
            lock.unlock()
            return
        }
        lastSignature = signature
        lastProgressNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func shouldContinue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled
    }

    func secondsSinceProgress() -> TimeInterval {
        lock.lock()
        let previous = lastProgressNanos
        lock.unlock()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= previous else { return 0 }
        return Double(now - previous) / 1_000_000_000
    }
}

actor Transcriber {
    private var whisper: WhisperKit?
    private let modelsDir: URL
    private let modelName: String

    private static let silenceRMSThreshold: Float = 0.004

    init(modelsDir: URL, modelName: String) {
        self.modelsDir = modelsDir
        self.modelName = modelName
    }

    private static func markerURL(modelsDir: URL, modelName: String) -> URL {
        modelsDir.appendingPathComponent(".ready_\(modelName)")
    }

    nonisolated static func isModelReady(modelsDir: URL, modelName: String) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(modelsDir: modelsDir, modelName: modelName).path)
    }

    func ensureLoaded(progressMonitor: TranscriptionProgressMonitor? = nil) async throws {
        if whisper != nil { return }
        progressMonitor?.markProgress()
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        RecLog.shared.log("whisper: loading model=\(modelName) into \(modelsDir.path)")

        let wk = try await WhisperKit(
            model: modelName,
            downloadBase: modelsDir,
            download: true
        )
        try Task.checkCancellation()
        guard progressMonitor?.shouldContinue() ?? true else { throw CancellationError() }
        whisper = wk

        let marker = Self.markerURL(modelsDir: modelsDir, modelName: modelName)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        progressMonitor?.markProgress()
        RecLog.shared.log("whisper: model ready")
    }

    func transcribe(
        _ audioURL: URL,
        progressMonitor: TranscriptionProgressMonitor? = nil
    ) async throws -> (text: String, segments: [SegmentInfo]) {
        try await ensureLoaded(progressMonitor: progressMonitor)
        guard let wk = whisper else {
            throw NSError(domain: "wrgent", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "モデルが読み込まれていません"])
        }
        RecLog.shared.log("whisper: transcribe \(audioURL.lastPathComponent)")

        let range = try speechRange(url: audioURL, progressMonitor: progressMonitor)
        RecLog.shared.log("whisper: speech range \(range.map { String(format: "%.1f-%.1fs", $0.start, $0.end) } ?? "unknown")")

        let options = DecodingOptions(language: "ja", skipSpecialTokens: true)
        let results = try await wk.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        ) { progress in
            progressMonitor?.markProgress(
                signature: "\(progress.windowId):\(progress.tokens.count):\(progress.text.count):\(progress.temperature ?? -1)"
            )
            return progressMonitor?.shouldContinue() ?? true
        }
        try Task.checkCancellation()
        guard progressMonitor?.shouldContinue() ?? true else { throw CancellationError() }
        let allSegments = results.flatMap { $0.segments }

        for seg in allSegments {
            RecLog.shared.log("whisper: raw [\(String(format:"%.1f",seg.start))-\(String(format:"%.1f",seg.end))s] \"\(seg.text.prefix(40))\"")
        }

        let validSegments = allSegments.filter { seg in
            let segStart  = Double(seg.start)
            let segEnd    = Double(seg.end)
            let duration  = segEnd - segStart
            let midpoint  = (segStart + segEnd) / 2.0
            let chars     = Double(seg.text.trimmingCharacters(in: .whitespaces).count)
            let fmt       = { (t: Double) in String(format: "%.1f", t) }
            let label     = "[\(fmt(segStart))-\(fmt(segEnd))s]"

            if duration > 10.0 && chars / duration < 1.0 {
                RecLog.shared.log("whisper: drop low-density \(label) \(String(format:"%.2f",chars/duration))c/s \"\(seg.text.prefix(30))\"")
                return false
            }

            if let r = range, midpoint < r.start || midpoint > r.end {
                RecLog.shared.log("whisper: drop out-of-range \(label) mid=\(fmt(midpoint)) \"\(seg.text.prefix(30))\"")
                return false
            }

            return true
        }

        let text = validSegments.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = validSegments.map {
            SegmentInfo(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
        RecLog.shared.log("whisper: done (\(text.count) chars, \(validSegments.count)/\(allSegments.count) segments kept)")
        return (text: text, segments: segments)
    }

    private func speechRange(
        url: URL,
        progressMonitor: TranscriptionProgressMonitor?
    ) throws -> (start: Double, end: Double)? {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        let totalSec = Double(file.length) / sr
        let chunkFrames = AVAudioFrameCount(max(1, Int(sr)))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: chunkFrames
        ) else { return nil }
        var speechStart: Double? = nil
        var speechEnd: Double? = nil
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard progressMonitor?.shouldContinue() ?? true else { throw CancellationError() }
            let startFrame = file.framePosition
            let remaining = file.length - startFrame
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: count)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            let framesRead = Int(buffer.frameLength)
            let channelCount = max(1, Int(buffer.format.channelCount))
            var sum: Float = 0
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for index in 0..<framesRead { sum += samples[index] * samples[index] }
            }
            let rms = sqrt(sum / Float(framesRead * channelCount))
            let chunkStart = Double(startFrame) / sr
            let chunkEnd = Double(startFrame + AVAudioFramePosition(framesRead)) / sr
            if rms >= Self.silenceRMSThreshold {
                if speechStart == nil { speechStart = chunkStart }
                speechEnd = chunkEnd
            }
            progressMonitor?.markProgress()
        }
        guard let s = speechStart, let e = speechEnd else { return nil }
        return (start: max(0, s - 0.5), end: min(totalSec, e + 0.5))
    }
}
