import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine
import AppKit
import CoreGraphics
import UserNotifications

// MARK: - Meeting record (used by ContentView)

struct MeetingRecord: Identifiable, Sendable {
    let id: String           // recording folder name
    let weekFolder: String   // e.g. "2026_W26"
    let date: Date
    let displayName: String
    let hasTranscript: Bool
    let includeInInsight: Bool
    let useExternalTranscriptForSummary: Bool

    var relativePath: String { "\(weekFolder)/\(id)" }
}

private struct SavedFileStat: @unchecked Sendable {
    let url: URL
    let size: Int
}

private struct RecordingFinalizationResult: @unchecked Sendable {
    let finalFolder: URL?
    let savedURLs: [URL]
    let fileStats: [SavedFileStat]
    let moveError: String?
    let finalizationError: String?
}

private struct PreparedRecordingFolder: @unchecked Sendable {
    let weekName: String
    let folder: URL
}

private struct TranscriptionPart: @unchecked Sendable {
    let url: URL
    let duration: Double
}

private struct TranscriptionInputs: @unchecked Sendable {
    let mic: [TranscriptionPart]
    let system: [TranscriptionPart]
    let unreadableFileName: String?
}

private struct TranscriptOutput: @unchecked Sendable {
    let fileName: String
    let text: String
}

// MARK: - AudioPump

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let input: AVAudioPCMBuffer
    private var wasFed = false

    init(_ input: AVAudioPCMBuffer) { self.input = input }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard !wasFed else {
            status.pointee = .noDataNow
            return nil
        }
        wasFed = true
        status.pointee = .haveData
        return input
    }
}

final class AudioPump: @unchecked Sendable {
    let procFormat: AVAudioFormat
    let ring: RingBuffer
    let name: String
    private var converters: [String: AVAudioConverter] = [:]
    private let converterLock = NSLock()
    private let counterLock = NSLock()
    private(set) var pushCount = 0
    private var loggedFirst = false

    init(name: String, sampleRate: Double, channels: AVAudioChannelCount) {
        self.name = name
        self.procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate,
                                        channels: channels,
                                        interleaved: false)!
        self.ring = RingBuffer(capacityFrames: Int(sampleRate) * 10, channels: Int(channels))
    }

    func resetCounters() {
        counterLock.lock()
        pushCount = 0
        loggedFirst = false
        counterLock.unlock()
    }

    func countSnapshot() -> Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return pushCount
    }

    func push(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = sampleBuffer.toPCMBuffer() else {
            RecLog.shared.log("\(name).push: toPCMBuffer failed"); return
        }
        store(pcm)
    }

    func pushPCM(_ buffer: AVAudioPCMBuffer) { store(buffer) }

    private func store(_ pcm: AVAudioPCMBuffer) {
        guard let converted = convert(pcm) else {
            RecLog.shared.log("\(name): convert failed (in=\(pcm.format))"); return
        }
        guard let chans = converted.floatChannelData else { return }
        let n = Int(converted.frameLength)
        guard n > 0 else { return }
        var arrays: [[Float]] = []
        let chCount = Int(converted.format.channelCount)
        arrays.reserveCapacity(chCount)
        for c in 0..<chCount {
            arrays.append(Array(UnsafeBufferPointer(start: chans[c], count: n)))
        }
        ring.write(arrays, frames: n)

        counterLock.lock()
        pushCount += 1
        let first = !loggedFirst
        if first { loggedFirst = true }
        counterLock.unlock()
        if first { RecLog.shared.log("\(name): FIRST buffer ok (in=\(pcm.format), frames=\(n))") }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == procFormat { return input }
        converterLock.lock(); defer { converterLock.unlock() }
        let key = input.format.description
        let conv: AVAudioConverter
        if let c = converters[key] { conv = c }
        else if let c = AVAudioConverter(from: input.format, to: procFormat) {
            converters[key] = c; conv = c
        } else { return nil }
        let ratio = procFormat.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: cap) else { return nil }
        let inputBox = ConverterInputBox(input)
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
            inputBox.next(inStatus)
        }
        if status == .error { RecLog.shared.log("\(name).convert error: \(err?.localizedDescription ?? "?")"); return nil }
        return outBuf
    }
}

// MARK: - Mic capture controller

/// Owns AVAudioEngine on a dedicated serial queue.
///
/// `AVAudioEngine.start()` can block while Zoom is switching audio devices.  It
/// must never run on the main actor: a blocked main actor prevents the startup
/// guard from firing and makes the whole menu-bar app look hung.
private final class ThrowingContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}

private final class MicOutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let pump: AudioPump

    init(pump: AudioPump) { self.pump = pump }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let shouldPush = active
        lock.unlock()
        if shouldPush { pump.pushPCM(buffer) }
    }
}

private final class MicCaptureController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wrgent.microphone-control", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var outputGate: MicOutputGate?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?

    func start(pump: AudioPump, onConfigurationChange: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completion = ThrowingContinuationGate<Void>(continuation)
            let outputGate = MicOutputGate(pump: pump)
            stateLock.lock()
            self.outputGate?.deactivate()
            self.outputGate = outputGate
            stateLock.unlock()

            // The timeout runs independently of the AVAudioEngine queue. If the
            // framework is blocked, recording continues with system audio rather
            // than freezing the UI or abandoning the complete recording.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                let timeout = NSError(
                    domain: "wrgent", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "マイク開始が8秒以内に完了しませんでした"]
                )
                if completion.resolve(.failure(timeout)) {
                    outputGate.deactivate()
                }
            }

            queue.async { [weak self] in
                guard let self else {
                    completion.resolve(.failure(NSError(
                        domain: "wrgent", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "マイク制御を初期化できませんでした"]
                    )))
                    return
                }
                do {
                    self.stopSynchronously()
                    let input = self.engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        throw NSError(domain: "wrgent", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "マイク入力フォーマットが無効です"])
                    }
                    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                        outputGate.push(buffer)
                    }
                    self.tapInstalled = true
                    self.engine.prepare()
                    try self.engine.start()
                    self.configurationObserver = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange,
                        object: self.engine,
                        queue: nil
                    ) { _ in onConfigurationChange() }
                    if !completion.resolve(.success(())) {
                        // A timeout already won. Do not leave a late-starting
                        // microphone engine attached to an abandoned attempt.
                        self.stopSynchronously()
                    }
                } catch {
                    outputGate.deactivate()
                    self.stopSynchronously()
                    completion.resolve(.failure(error))
                }
            }
        }
    }

    func stop() {
        stateLock.lock()
        outputGate?.deactivate()
        outputGate = nil
        stateLock.unlock()
        queue.async { [weak self] in self?.stopSynchronously() }
    }

    private func stopSynchronously() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        engine.reset()
    }
}

// MARK: - Mixer

final class Mixer: @unchecked Sendable {
    private let format: AVAudioFormat
    private let sysRing: RingBuffer?
    private let micRing: RingBuffer?
    private let writer: SegmentWriter
    private let sampleRate: Double
    private let maxChunk = 8192

    private let queue = DispatchQueue(label: "wrgent.mix")
    private var timer: DispatchSourceTimer?
    private var lastTick: UInt64 = 0
    private var remainder: Double = 0

    private let sysBuf: AVAudioPCMBuffer
    private let micBuf: AVAudioPCMBuffer
    private let outBuf: AVAudioPCMBuffer

    private let micWriter: SegmentWriter?
    private let sysWriter: SegmentWriter?

    init(format: AVAudioFormat, sysRing: RingBuffer?, micRing: RingBuffer?,
         mixWriter: SegmentWriter, micWriter: SegmentWriter?, sysWriter: SegmentWriter?) {
        self.format = format
        self.sysRing = sysRing
        self.micRing = micRing
        self.writer = mixWriter
        self.micWriter = micWriter
        self.sysWriter = sysWriter
        self.sampleRate = format.sampleRate
        self.sysBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxChunk))!
        self.micBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxChunk))!
        self.outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxChunk))!
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            self.lastTick = DispatchTime.now().uptimeNanoseconds
            t.resume()
            RecLog.shared.log("mixer: started")
        }
    }

    /// Drains every already-enqueued tick, then closes all writers on the mixer
    /// queue. The caller awaits asynchronously, so even a framework-level stall
    /// cannot block the main actor. A new session remains gated until completion
    /// to prevent an old mixer from consuming the new session's shared rings.
    func stopAndFinish(timeoutSeconds: Double = 12) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            let completion = ThrowingContinuationGate<[URL]>(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                completion.resolve(.failure(NSError(
                    domain: "wrgent", code: 40,
                    userInfo: [NSLocalizedDescriptionKey: "録音ファイルの終了処理が\(Int(timeoutSeconds))秒以内に完了しませんでした"]
                )))
            }
            queue.async { [weak self] in
                guard let self else {
                    completion.resolve(.success([]))
                    return
                }
                self.timer?.setEventHandler {}
                self.timer?.cancel()
                self.timer = nil
                var saved: [URL] = []
                saved += self.micWriter?.finish() ?? []
                saved += self.sysWriter?.finish() ?? []
                saved += self.writer.finish()
                RecLog.shared.log("mixer: stopped and writers finalized")
                if !completion.resolve(.success(saved)) {
                    RecLog.shared.log("mixer: writer finalization completed after timeout")
                }
            }
        }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- lastTick) / 1_000_000_000.0
        lastTick = now
        let framesD = dt * sampleRate + remainder
        var frames = Int(framesD)
        remainder = framesD - Double(frames)
        if frames <= 0 { return }
        if frames > maxChunk { frames = maxChunk; remainder = 0 }
        mixAndWrite(frames)
    }

    private func mixAndWrite(_ frames: Int) {
        let ch = Int(format.channelCount)
        outBuf.frameLength = AVAudioFrameCount(frames)
        guard let out = outBuf.floatChannelData else { return }
        for c in 0..<ch { memset(out[c], 0, frames * MemoryLayout<Float>.size) }

        if let r = sysRing {
            readInto(r, scratch: sysBuf, frames: frames, ch: ch)
            sysWriter?.write(sysBuf)
            addBuffer(sysBuf, into: out, frames: frames, ch: ch)
        }
        if let r = micRing {
            readInto(r, scratch: micBuf, frames: frames, ch: ch)
            micWriter?.write(micBuf)
            addBuffer(micBuf, into: out, frames: frames, ch: ch)
        }

        for c in 0..<ch {
            let p = out[c]
            for i in 0..<frames {
                if p[i] > 1 { p[i] = 1 } else if p[i] < -1 { p[i] = -1 }
            }
        }
        writer.write(outBuf)
    }

    private func readInto(_ ring: RingBuffer, scratch: AVAudioPCMBuffer, frames: Int, ch: Int) {
        scratch.frameLength = AVAudioFrameCount(frames)
        guard let s = scratch.floatChannelData else { return }
        for c in 0..<ch { memset(s[c], 0, frames * MemoryLayout<Float>.size) }
        _ = ring.read(into: scratch, maxFrames: frames)
    }

    private func addBuffer(_ scratch: AVAudioPCMBuffer,
                           into out: UnsafePointer<UnsafeMutablePointer<Float>>,
                           frames: Int, ch: Int) {
        guard let s = scratch.floatChannelData else { return }
        for c in 0..<ch {
            let dst = out[c]; let src = s[c]
            for i in 0..<frames { dst[i] += src[i] }
        }
    }
}

// MARK: - SegmentWriter

final class SegmentWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let counterLock = NSLock()
    private let folder: URL
    private let baseName: String
    private let settings: [String: Any]
    private let sampleRate: Double
    private let bytesPerSecond: Double
    private let maxBytes: Double
    private let headerMargin: Double = 64 * 1024

    private var file: AVAudioFile?
    private var part = 0
    private var framesInSegment: Double = 0
    private(set) var urls: [URL] = []
    private var writeCount = 0
    private var openFailureCount = 0
    private var nextOpenAttemptUptimeNanoseconds: UInt64 = 0

    init(folder: URL, baseName: String, settings: [String: Any],
         sampleRate: Double, bitrate: Double, maxBytes: Double) {
        self.folder = folder
        self.baseName = baseName
        self.settings = settings
        self.sampleRate = sampleRate
        self.bytesPerSecond = bitrate / 8.0
        self.maxBytes = maxBytes
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if file == nil {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= nextOpenAttemptUptimeNanoseconds else { return }
            guard openNext() else { return }
        }
        let estBytes = (framesInSegment / sampleRate) * bytesPerSecond + headerMargin
        if estBytes >= maxBytes, !openNext() { return }
        guard let file else { return }
        do {
            try file.write(from: buffer)
            framesInSegment += Double(buffer.frameLength)
            counterLock.lock()
            writeCount += 1
            let firstWrite = writeCount == 1
            counterLock.unlock()
            if firstWrite {
                RecLog.shared.log("writer: FIRST write ok (frames=\(buffer.frameLength))")
            }
        } catch {
            RecLog.shared.log("writer.write error: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func openNext() -> Bool {
        file = nil
        let nextPart = part + 1
        let name = String(format: "%@_part%02d.m4a", baseName, nextPart)
        let url = folder.appendingPathComponent(name)
        do {
            let openedFile = try AVAudioFile(forWriting: url, settings: settings)
            file = openedFile
            part = nextPart
            framesInSegment = 0
            urls.append(url)
            if openFailureCount > 0 {
                RecLog.shared.log("writer: recovered after \(openFailureCount) open failure(s)")
            }
            openFailureCount = 0
            nextOpenAttemptUptimeNanoseconds = 0
            RecLog.shared.log("writer: opened \(name)")
            return true
        } catch {
            openFailureCount += 1
            nextOpenAttemptUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds &+ 1_000_000_000
            if openFailureCount == 1 || openFailureCount.isMultiple(of: 10) {
                RecLog.shared.log(
                    "writer: FAILED to open \(name) (attempt \(openFailureCount)): \(error.localizedDescription)"
                )
            }
            return false
        }
    }

    func finish() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        file = nil
        return urls
    }

    func writeCountSnapshot() -> Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return writeCount
    }
}

// MARK: - AudioRecorder

@MainActor
final class AudioRecorder: NSObject, ObservableObject {

    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastFiles: [URL] = []
    @Published var captureSystemAudio = true
    @Published var captureMic = true
    @Published var statusMessage = ""
    @Published var needsScreenPermission = false

    // Zoom auto-record (on by default)
    @Published var autoRecordZoom = true

    // Auto-transcribe after each Zoom meeting (on by default)
    @Published var autoTranscribe = true

    // Library
    @Published var libraryDisplay = ""
    @Published var recordings: [String] = []
    @Published var selectedRecording: String?
    @Published var recordingName = ""

    // Weekly meetings
    @Published var weeklyMeetings: [MeetingRecord] = []

    // Transcription
    @Published var modelReady = false
    @Published var isTranscribing = false
    @Published var transcriptionStatus = ""
    @Published var transcriptSelfExists = false
    @Published var transcriptOtherExists = false
    @Published var transcriptMergedExists = false
    @Published private(set) var pendingTranscriptionCount = 0

    // Weekly summary generation
    @Published var isGeneratingSummary = false

    @Published var selectedWeek: String = ""
    @Published var availableWeeks: [String] = []

    // Calendar data generated by Codex
    @Published var calendarImportedCount = 0

    static let modelOptions = [
        "openai_whisper-large-v3_turbo",
        "openai_whisper-large-v3",
        "openai_whisper-medium",
        "openai_whisper-small"
    ]
    @Published var selectedModelName: String
    private var cancellables = Set<AnyCancellable>()

    private let sampleRate: Double = 48_000
    private let channelCount: AVAudioChannelCount = 2
    private let bitrate: Double = 128_000
    private let maxBytes: Double = 24 * 1024 * 1024

    private let procFormat: AVAudioFormat
    private var sysPump: AudioPump
    private var micPump: AudioPump

    private var micCapture = MicCaptureController()
    private var abandonedMicControllerCount = 0
    private let maxMicCaptureTimeouts = 2

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var systemCaptureTimeoutCount = 0
    private let maxSystemCaptureTimeouts = 3
    private var activeMicAvailable = false
    private var activeSystemAudioAvailable = false

    private var mixWriter: SegmentWriter?
    private var micWriter: SegmentWriter?
    private var sysWriter: SegmentWriter?
    private var mixer: Mixer?

    private var startDate: Date?
    private var elapsedTask: Task<Void, Never>?
    private var startGuardTask: Task<Void, Never>?
    private var startAsyncTask: Task<Void, Never>?
    @Published private(set) var isStarting = false
    @Published private(set) var isFinalizingRecording = false
    private var startAttemptID: UInt64 = 0
    private let zoomMonitor = ZoomMonitor()
    private var mixerWriteCountAtLastCheck = 0
    private var micPushCountAtLastCheck = 0
    private var sysPushCountAtLastCheck = 0
    private var watchdogTask: Task<Void, Never>?
    private var zoomTitleTask: Task<Void, Never>?

    private var activeRecordingFolder: URL?
    private var activeTimestamp = ""
    private var activeWeekFolder = ""
    private var micRecoveryTask: Task<Void, Never>?
    private var isRecoveringMic = false
    private var micRecoveryAttemptsWithoutProgress = 0
    private let maxMicRecoveryAttemptsWithoutProgress = 2
    private var recordingSessionGeneration: UInt64 = 0
    private var activeRecordingSessionGeneration: UInt64 = 0
    private var recordingWasAutomatic = false
    private var writerFinalizationTimeoutCount = 0
    private let maxWriterFinalizationTimeouts = 2

    // Queue of recording names waiting for auto-transcription
    private var transcriptionQueue: [String] = []
    private var activeTranscriptionPath: String?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionWatchdogTask: Task<Void, Never>?
    private var transcriptionProgressMonitor: TranscriptionProgressMonitor?
    private var transcriptionOperationGeneration: UInt64 = 0
    private var cancelledTranscriptionOperation: UInt64?
    private var transcriptionCancellationGuardTask: Task<Void, Never>?
    private let transcriptionCancellationGraceSeconds: TimeInterval = 30
    private var transcriptionDisabledUntilRestart = false
    private var transcriptionIOTimeoutCount = 0
    private let maxTranscriptionIOTimeouts = 2
    private let transcriptionQueueFileName = "_transcription_queue.json"
    private var transcriptionRetryTask: Task<Void, Never>?
    private var transcriptionRetryCounts: [String: Int] = [:]
    private var quarantinedTranscriptions = Set<String>()
    private let maxTranscriptionRetriesPerRun = 3
    private var stateIOQueue = DispatchQueue(label: "wrgent.state-io", qos: .utility)
    private var libraryIOQueue = DispatchQueue(label: "wrgent.library-io", qos: .utility)
    private var transcriptionIOQueue = DispatchQueue(label: "wrgent.transcription-io", qos: .utility)
    private var recordingIOQueue = DispatchQueue(label: "wrgent.recording-io", qos: .userInitiated)
    private var finalizationIOQueue = DispatchQueue(label: "wrgent.finalization-io", qos: .userInitiated)
    private var availableWeeksRefreshGeneration: UInt64 = 0
    private var weeklyMeetingsRefreshGeneration: UInt64 = 0
    private var calendarRefreshGeneration: UInt64 = 0
    private var pendingScanGeneration: UInt64 = 0
    private var queueLoadGeneration: UInt64 = 0
    private var summaryGeneration: UInt64 = 0
    private var modelRefreshGeneration: UInt64 = 0
    private var transcriptRefreshGeneration: UInt64 = 0
    private var recordingFolderTimeoutCount = 0
    private let maxRecordingFolderTimeouts = 2
    private var isSystemSleeping = false

    private var automaticStartFailureCount = 0
    private var nextAutomaticStartRetryAt: Date?
    private var currentStartWasAutomatic = false
    private var currentStartFollowsZoomLifecycle = false
    private var delayedRecordingRetryTask: Task<Void, Never>?
    private var delayedRecordingRetryGeneration: UInt64 = 0
    private var delayedRecordingRetryFollowsZoomLifecycle = false
    private var automaticStartFailureNotificationSent = false

    private let bookmarkKey = "wrgent.libraryBookmark"
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var terminateRequestObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var replyToTerminationAfterFinalizing = false

    private var libraryURL: URL?

    override init() {
        sysPump = AudioPump(name: "sys", sampleRate: 48_000, channels: 2)
        micPump = AudioPump(name: "mic", sampleRate: 48_000, channels: 2)
        procFormat = sysPump.procFormat
        let saved = UserDefaults.standard.string(forKey: "wrgent.selectedModelName") ?? ""
        selectedModelName = AudioRecorder.modelOptions.contains(saved)
            ? saved : AudioRecorder.modelOptions[0]
        super.init()
        resolveSavedLibrary()
        RecLog.shared.configure(folder: library())
        updateLibraryDisplay()
        refreshRecordings()
        refreshModelState()
        refreshScreenPermission()

        $selectedModelName.dropFirst().sink { [weak self] name in
            UserDefaults.standard.set(name, forKey: "wrgent.selectedModelName")
            self?.transcriptionRetryTask?.cancel()
            self?.transcriptionRetryTask = nil
            self?.transcriptionRetryCounts.removeAll()
            self?.quarantinedTranscriptions.removeAll()
            self?.refreshModelState()
            self?.refreshTranscriptState()
            self?.refreshWeeklyMeetings()
            self?.processTranscriptionQueue()
        }.store(in: &cancellables)

        // Persist autoRecordZoom
        autoRecordZoom = UserDefaults.standard.object(forKey: "wrgent.autoRecordZoom") as? Bool ?? true
        $autoRecordZoom.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            UserDefaults.standard.set(enabled, forKey: "wrgent.autoRecordZoom")
            if enabled {
                self.startZoomMonitor()
            } else {
                self.zoomMonitor.stop()
                if self.delayedRecordingRetryFollowsZoomLifecycle {
                    self.cancelDelayedRecordingRetry(reason: "Zoom auto-record disabled during retry delay")
                }
                if self.isStarting && self.currentStartFollowsZoomLifecycle {
                    self.cancelRecordingStart(reason: "Zoom auto-record disabled during startup")
                } else if self.isRecording && self.recordingWasAutomatic {
                    self.stopRecording()
                }
            }
        }.store(in: &cancellables)

        // Persist autoTranscribe
        autoTranscribe = UserDefaults.standard.object(forKey: "wrgent.autoTranscribe") as? Bool ?? true
        $autoTranscribe.dropFirst().sink { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: "wrgent.autoTranscribe")
            guard enabled, let self else { return }
            self.enqueuePendingTranscriptions()
            self.processTranscriptionQueue()
        }.store(in: &cancellables)

        if autoRecordZoom { startZoomMonitor() }
        migrateToWeekFolders()
        loadTranscriptionQueue()
        enqueuePendingTranscriptions()
        refreshAvailableWeeks()
        refreshCalendarCount()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.processTranscriptionQueue()
        }

        // Sleep: stop any active recording cleanly so audio files are saved before the machine sleeps.
        // Wake: resume the transcription queue (Core ML context survives sleep on Apple Silicon;
        //        on Intel the Task may error — user can retry manually via the menu).
        let wsCenter = NSWorkspace.shared.notificationCenter
        sleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSystemSleeping = true
                self.persistTranscriptionQueue()
                self.cancelDelayedRecordingRetry(reason: "system will sleep")
                if self.isStarting && !self.isRecording {
                    RecLog.shared.log("system: will sleep — cancelling recording startup")
                    self.cancelRecordingStart(reason: "system will sleep")
                } else if self.isRecording {
                    RecLog.shared.log("system: will sleep — stopping active recording")
                    self.stopRecording()
                    self.sendNotification(title: "スリープ前に録音を保存", body: "起動中にZoomミーティングを再開すると自動再開します")
                }
            }
        }
        wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSystemSleeping = false
                self.enqueuePendingTranscriptions()
                RecLog.shared.log("system: did wake — resuming transcription queue (pending=\(self.transcriptionQueue.count))")
                self.processTranscriptionQueue()
            }
        }
        activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshCalendarCount()
                self.refreshWeeklyMeetings()
                self.enqueuePendingTranscriptions()
                self.processTranscriptionQueue()
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persistTranscriptionQueue()
            }
        }
        terminateRequestObserver = NotificationCenter.default.addObserver(
            forName: .wrgentTerminationRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                self.persistTranscriptionQueue()
                self.cancelDelayedRecordingRetry(reason: "application termination")
                if self.isStarting && !self.isRecording {
                    self.cancelRecordingStart(reason: "application termination")
                }
                if self.isRecording {
                    RecLog.shared.log("application: termination requested — finalizing active recording")
                    self.stopRecording(replyToTermination: true)
                } else if self.isFinalizingRecording {
                    self.replyToTerminationAfterFinalizing = true
                } else {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    func refreshScreenPermission() {
        let granted = CGPreflightScreenCaptureAccess()
        needsScreenPermission = !granted
        RecLog.shared.log("permissions: screen-recording granted=\(granted)")
    }

    // MARK: - Zoom auto-recording

    private func startZoomMonitor() {
        zoomMonitor.setCallbacks(
            onMeetingStart: { [weak self] in
                Task { @MainActor in
                    guard let self, self.autoRecordZoom, !self.isRecording else { return }
                    self.resetAutomaticStartBackoff()
                    self.recordingName = "Zoomミーティング"
                    self.startRecordingAutomatically()
                }
            },
            onMeetingEnd: { [weak self] in
                Task { @MainActor in
                    guard let self, self.autoRecordZoom else { return }
                    self.resetAutomaticStartBackoff()
                    if self.delayedRecordingRetryFollowsZoomLifecycle {
                        self.cancelDelayedRecordingRetry(reason: "Zoom meeting ended during retry delay")
                    }
                    if self.isRecording && self.recordingWasAutomatic {
                        self.stopRecording()
                        self.sendNotification(title: "録音停止", body: "Zoomミーティングが終了しました。文字起こしを開始します")
                    } else if self.isStarting && self.currentStartFollowsZoomLifecycle {
                        self.cancelRecordingStart(reason: "Zoom meeting ended during startup")
                    }
                }
            },
            onMeetingStillActive: { [weak self] in
                Task { @MainActor in
                    guard let self, self.autoRecordZoom,
                          !self.isRecording, !self.isStarting,
                          self.delayedRecordingRetryTask == nil else { return }
                    RecLog.shared.log("zoomMonitor: meeting active but not recording — retrying startRecording")
                    self.startRecordingAutomatically()
                }
            }
        )
        zoomMonitor.start()
    }

    // MARK: - Zoom window title detection (Option C)

    nonisolated private static func extractZoomWindowTitle() -> String? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in list {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let name  = info[kCGWindowName  as String] as? String ?? ""
            guard owner.lowercased().contains("zoom") else { continue }

            // "Meeting Topic - Zoom"
            if name.hasSuffix(" - Zoom") {
                let t = String(name.dropLast(7)).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, t != "Zoom" { return t }
            }
            // 一部バージョンが使う日本語サフィックス
            if name.hasSuffix(" - Zoomミーティング") {
                let t = String(name.dropLast(" - Zoomミーティング".count)).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
            }
            let skip: Set<String> = ["Zoom", "zoom.us", "Zoom Meeting", "Zoomミーティング", "ZoomCall", ""]
            if !skip.contains(name), !name.hasPrefix("Zoom") { return name }
        }
        return nil
    }

    private func scheduleZoomTitleDetection(sessionGeneration: UInt64) {
        zoomTitleTask?.cancel()
        zoomTitleTask = Task { @MainActor [weak self] in
            for _ in 0..<6 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self,
                      self.autoRecordZoom,
                      self.isRecording,
                      self.recordingWasAutomatic,
                      self.activeRecordingSessionGeneration == sessionGeneration else { return }
                let title = await Task.detached(priority: .utility) {
                    Self.extractZoomWindowTitle()
                }.value
                guard self.isRecording,
                      self.activeRecordingSessionGeneration == sessionGeneration else { return }
                if let title {
                    self.recordingName = title
                    RecLog.shared.log("zoom: window title detected: \(title)")
                    return
                }
            }
        }
    }

    func refreshCalendarCount() {
        let week = selectedWeek
        guard !week.isEmpty else {
            calendarImportedCount = 0
            return
        }
        let library = library()
        let folder = library.appendingPathComponent(week, isDirectory: true)
        calendarRefreshGeneration &+= 1
        let generation = calendarRefreshGeneration
        libraryIOQueue.async { [weak self] in
            let count = CalendarStore.importedCount(in: folder)
            Task { @MainActor [weak self] in
                guard let self,
                      self.calendarRefreshGeneration == generation,
                      self.selectedWeek == week,
                      self.library() == library else { return }
                self.calendarImportedCount = count
            }
        }
    }

    func reloadCalendarAndMeetings() {
        refreshCalendarCount()
        refreshWeeklyMeetings()
        updateWeeklySummary(forWeek: selectedWeek)
        statusMessage = "予定を再読み込みしました（\(calendarImportedCount)件）"
    }

    func currentWeekFolderURL() -> URL {
        library().appendingPathComponent(selectedWeek, isDirectory: true)
    }

    func refreshAvailableWeeks() {
        let lib = library()
        let current = WeeklySummaryGenerator.weekFolderName(for: Date())
        if selectedWeek.isEmpty {
            selectedWeek = current
        }
        availableWeeksRefreshGeneration &+= 1
        let generation = availableWeeksRefreshGeneration
        libraryIOQueue.async { [weak self] in
            var weeks = Self.availableWeekNames(in: lib)
            if !weeks.contains(current) { weeks.append(current); weeks.sort() }
            Task { @MainActor [weak self] in
                guard let self,
                      self.availableWeeksRefreshGeneration == generation,
                      self.library() == lib else { return }
                let previousSelection = self.selectedWeek
                self.availableWeeks = weeks
                if self.selectedWeek.isEmpty || !weeks.contains(self.selectedWeek) {
                    self.selectedWeek = current
                }
                if previousSelection != self.selectedWeek {
                    self.refreshWeeklyMeetings()
                    self.refreshCalendarCount()
                }
            }
        }
    }

    nonisolated private static func availableWeekNames(in library: URL) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: library, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        return items.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                return nil
            }
            let name = url.lastPathComponent
            guard name.range(of: #"^\d{4}_W\d{2}$"#, options: .regularExpression) != nil else {
                return nil
            }
            return name
        }.sorted()
    }

    func migrateToWeekFolders() {
        let lib = library()
        libraryIOQueue.async { [weak self] in
            Self.performWeekFolderMigration(in: lib)
            Task { @MainActor [weak self] in
                guard let self, self.library() == lib else { return }
                self.refreshAvailableWeeks()
                self.refreshWeeklyMeetings()
            }
        }
    }

    nonisolated private static func performWeekFolderMigration(in lib: URL) {
        let fm = FileManager.default
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        guard let items = try? fm.contentsOfDirectory(
            at: lib, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles) else { return }

        for item in items {
            let name = item.lastPathComponent
            if name == "_models" || name == "wrgent_log.txt" { continue }
            if name.range(of: #"^\d{4}_W\d{2}$"#, options: .regularExpression) != nil { continue }

            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

            if isDir {
                if name.hasPrefix("_") { continue }
                let ts = name.components(separatedBy: " - ").first ?? name
                guard let date = df.date(from: ts) else { continue }
                let weekName = WeeklySummaryGenerator.weekFolderName(for: date)
                let weekDir = lib.appendingPathComponent(weekName)
                try? fm.createDirectory(at: weekDir, withIntermediateDirectories: true)
                let dest = weekDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: item, to: dest) }
            } else {
                // _calendar_YYYY_Wnn.json → YYYY_Wnn/_calendar.json
                if name.hasPrefix("_calendar_") && name.hasSuffix(".json") {
                    let weekPart = String(name.dropFirst("_calendar_".count).dropLast(".json".count))
                    let weekDir = lib.appendingPathComponent(weekPart)
                    if fm.fileExists(atPath: weekDir.path) {
                        let dest = weekDir.appendingPathComponent("_calendar.json")
                        if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: item, to: dest) }
                        else { try? fm.removeItem(at: item) }
                    }
                    continue
                }
                // weekly_summary_YYYY_Wnn.txt → YYYY_Wnn/summary.txt
                if name.hasPrefix("weekly_summary_") && name.hasSuffix(".txt") {
                    let weekPart = String(name.dropFirst("weekly_summary_".count).dropLast(".txt".count))
                    let weekDir = lib.appendingPathComponent(weekPart)
                    if fm.fileExists(atPath: weekDir.path) {
                        let dest = weekDir.appendingPathComponent("summary.txt")
                        if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: item, to: dest) }
                        else { try? fm.removeItem(at: item) }
                    }
                    continue
                }
                // _meeting_names.json → distribute to week folders
                if name == "_meeting_names.json" {
                    guard let data = try? Data(contentsOf: item),
                          let dict = try? JSONDecoder().decode([String: String].self, from: data) else { continue }
                    var weekDicts: [String: [String: String]] = [:]
                    var allEntriesMapped = true
                    for (fn, cn) in dict {
                        let ts = fn.components(separatedBy: " - ").first ?? fn
                        if let date = df.date(from: ts) {
                            let wn = WeeklySummaryGenerator.weekFolderName(for: date)
                            weekDicts[wn, default: [:]][fn] = cn
                        } else {
                            allEntriesMapped = false
                        }
                    }
                    var allDestinationsWritten = allEntriesMapped
                    for (wn, wd) in weekDicts {
                        let weekDir = lib.appendingPathComponent(wn)
                        guard fm.fileExists(atPath: weekDir.path) else {
                            allDestinationsWritten = false
                            continue
                        }
                        let destination = weekDir.appendingPathComponent("_meeting_names.json")
                        var merged = wd
                        if fm.fileExists(atPath: destination.path) {
                            guard let existingData = try? Data(contentsOf: destination),
                                  let existing = try? JSONDecoder().decode(
                                    [String: String].self,
                                    from: existingData
                                  ) else {
                                allDestinationsWritten = false
                                continue
                            }
                            // Per-week values may contain newer user edits, so
                            // they win over the legacy root file on duplicate keys.
                            for (key, value) in existing { merged[key] = value }
                        }
                        do {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            let encoded = try encoder.encode(merged)
                            try encoded.write(to: destination, options: .atomic)
                        } catch {
                            allDestinationsWritten = false
                            RecLog.shared.log(
                                "migration: meeting names write failed for \(wn): \(error.localizedDescription)"
                            )
                        }
                    }
                    if allDestinationsWritten {
                        do {
                            try fm.removeItem(at: item)
                        } catch {
                            RecLog.shared.log(
                                "migration: legacy meeting names cleanup failed: \(error.localizedDescription)"
                            )
                        }
                    } else {
                        RecLog.shared.log(
                            "migration: legacy meeting names retained because not every destination was written"
                        )
                    }
                    continue
                }
            }
        }
        RecLog.shared.log("migration: week folder migration complete")
    }

    func enqueueMeetingForTranscription(_ record: MeetingRecord) {
        let path = record.relativePath
        guard activeTranscriptionPath != path, !transcriptionQueue.contains(path) else { return }
        enqueueTranscription(path)
        RecLog.shared.log("manual transcribe: queued '\(path)'")
        processTranscriptionQueue()
    }

    func isMeetingInTranscriptionQueue(_ record: MeetingRecord) -> Bool {
        transcriptionQueue.contains(record.relativePath) || activeTranscriptionPath == record.relativePath
    }

    func setMeetingName(folderName: String, name: String) {
        let week = selectedWeek
        let library = library()
        let folder = library.appendingPathComponent(week, isDirectory: true)
        libraryIOQueue.async { [weak self] in
            let operationError: Error?
            do {
                try MeetingNameStore.save(folderName: folderName, name: name, in: folder)
                operationError = nil
            } catch {
                operationError = error
            }
            Task { @MainActor [weak self] in
                guard let self, self.library() == library else { return }
                if let operationError {
                    self.statusMessage = "会議名の保存に失敗: \(operationError.localizedDescription)"
                }
                if self.selectedWeek == week { self.refreshWeeklyMeetings() }
                self.updateWeeklySummary(forWeek: week)
            }
        }
    }

    func setMeetingInsightIncluded(folderName: String, included: Bool) {
        let week = selectedWeek
        let library = library()
        let folder = library.appendingPathComponent(week, isDirectory: true)
        libraryIOQueue.async { [weak self] in
            let operationError: Error?
            do {
                try MeetingInsightStore.save(folderName: folderName, included: included, in: folder)
                operationError = nil
            } catch {
                operationError = error
            }
            Task { @MainActor [weak self] in
                guard let self, self.library() == library else { return }
                if let operationError {
                    self.statusMessage = "インサイト設定の保存に失敗: \(operationError.localizedDescription)"
                }
                if self.selectedWeek == week { self.refreshWeeklyMeetings() }
                self.updateWeeklySummary(forWeek: week)
            }
        }
    }

    func setMeetingSummaryTranscriptSource(folderName: String, externalOnly: Bool) {
        let week = selectedWeek
        let library = library()
        let weekFolder = library.appendingPathComponent(week, isDirectory: true)
        libraryIOQueue.async { [weak self] in
            let operationError: Error?
            do {
                try MeetingSummaryTranscriptStore.save(
                    folderName: folderName,
                    externalOnly: externalOnly,
                    in: weekFolder
                )
                let meetingFolder = weekFolder.appendingPathComponent(folderName, isDirectory: true)
                Self.ensureExternalTranscripts(in: meetingFolder)
                operationError = nil
            } catch {
                operationError = error
            }
            Task { @MainActor [weak self] in
                guard let self, self.library() == library else { return }
                if let operationError {
                    self.statusMessage = "文字起こし設定の保存に失敗: \(operationError.localizedDescription)"
                }
                if self.selectedWeek == week { self.refreshWeeklyMeetings() }
                self.updateWeeklySummary(forWeek: week)
            }
        }
    }

    // MARK: - Notifications

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { RecLog.shared.log("notification error: \(err.localizedDescription)") }
        }
    }

    // MARK: - Unexpected stop

    private func unexpectedStop(reason: String) {
        guard isRecording else { return }
        RecLog.shared.log("unexpectedStop: \(reason)")
        stopRecording()
        statusMessage = "録音が予期せず終了しました: \(reason)"
        sendNotification(title: "録音が予期せず終了しました", body: reason)
    }

    // MARK: - Model management

    private func modelsDir() -> URL {
        library().appendingPathComponent("_models", isDirectory: true)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestScreenAccess() {
        let granted = CGRequestScreenCaptureAccess()
        needsScreenPermission = !granted
        if !granted { openScreenRecordingSettings() }
    }

    func refreshModelState() {
        let library = library()
        let directory = library.appendingPathComponent("_models", isDirectory: true)
        let model = selectedModelName
        modelRefreshGeneration &+= 1
        let generation = modelRefreshGeneration
        libraryIOQueue.async { [weak self] in
            let ready = Transcriber.isModelReady(modelsDir: directory, modelName: model)
            Task { @MainActor [weak self] in
                guard let self,
                      self.modelRefreshGeneration == generation,
                      self.selectedModelName == model,
                      self.library() == library else { return }
                self.modelReady = ready
            }
        }
    }

    func refreshTranscriptState() {
        transcriptRefreshGeneration &+= 1
        let generation = transcriptRefreshGeneration
        guard let sel = selectedRecording else {
            transcriptSelfExists = false; transcriptOtherExists = false; transcriptMergedExists = false
            return
        }
        transcriptSelfExists = false
        transcriptOtherExists = false
        transcriptMergedExists = false
        let library = library()
        let folder = library.appendingPathComponent(sel, isDirectory: true)
        let model = selectedModelName
        libraryIOQueue.async { [weak self] in
            let fm = FileManager.default
            let suffix = "_\(model)"
            let state = (
                fm.fileExists(atPath: folder.appendingPathComponent("transcript_self\(suffix).txt").path),
                fm.fileExists(atPath: folder.appendingPathComponent("transcript_other\(suffix).txt").path),
                fm.fileExists(atPath: folder.appendingPathComponent("transcript\(suffix).txt").path)
            )
            Task { @MainActor [weak self] in
                guard let self,
                      self.transcriptRefreshGeneration == generation,
                      self.selectedRecording == sel,
                      self.selectedModelName == model,
                      self.library() == library else { return }
                self.transcriptSelfExists = state.0
                self.transcriptOtherExists = state.1
                self.transcriptMergedExists = state.2
            }
        }
    }

    func downloadModel() {
        guard !isTranscribing else { return }
        guard cancelledTranscriptionOperation == nil else {
            transcriptionStatus = "前の文字起こし処理の終了を待っています…"
            return
        }
        guard !transcriptionDisabledUntilRestart else {
            transcriptionStatus = "文字起こし基盤が応答しないため、wrgentを再起動してください"
            return
        }
        isTranscribing = true
        transcriptionStatus = "モデルを取得中…（初回は数百MB、しばらくかかります）"
        let dir = modelsDir(); let name = selectedModelName
        transcriptionOperationGeneration &+= 1
        let operation = transcriptionOperationGeneration
        let monitor = TranscriptionProgressMonitor()
        transcriptionProgressMonitor = monitor
        startTranscriptionWatchdog(
            operation: operation,
            monitor: monitor,
            maximumIdleSeconds: 1_200,
            activityName: "モデル取得"
        )
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishTranscriptionTaskIfCurrent(operation: operation) }
            do {
                let t = Transcriber(modelsDir: dir, modelName: name)
                try await t.ensureLoaded(progressMonitor: monitor)
                guard self.transcriptionOperationGeneration == operation else { return }
                self.modelReady = true
                self.transcriptionStatus = "モデルの準備ができました"
                self.isTranscribing = false
                self.transcriptionRetryTask?.cancel()
                self.transcriptionRetryTask = nil
                self.transcriptionRetryCounts.removeAll()
                self.quarantinedTranscriptions.removeAll()
                self.processTranscriptionQueue()
            } catch {
                guard self.transcriptionOperationGeneration == operation else {
                    RecLog.shared.log("model download: ignored late completion after cancellation")
                    return
                }
                self.transcriptionStatus = "モデル取得に失敗: \(error.localizedDescription)"
                self.isTranscribing = false
            }
        }
    }

    // MARK: - Transcription

    func transcribeSelected() {
        guard !transcriptionDisabledUntilRestart else {
            transcriptionStatus = "文字起こし基盤が応答しないため、wrgentを再起動してください"
            return
        }
        guard let sel = selectedRecording else {
            if selectedRecording == nil { transcriptionStatus = "レコーディングを選択してください" }
            return
        }
        // A manual retry is an explicit request to release this item from the
        // per-launch quarantine and put it ahead of background work.
        transcriptionRetryTask?.cancel()
        transcriptionRetryTask = nil
        transcriptionRetryCounts.removeValue(forKey: sel)
        quarantinedTranscriptions.remove(sel)
        transcriptionQueue.removeAll { $0 == sel }
        transcriptionQueue.insert(sel, at: 0)
        pendingTranscriptionCount = transcriptionQueue.count
        persistTranscriptionQueue()
        processTranscriptionQueue()
    }

    private func runTranscription(path: String) {
        guard !isTranscribing, !isRecording, !isSystemSleeping,
              cancelledTranscriptionOperation == nil,
              !transcriptionDisabledUntilRestart else { return }
        let folder = library().appendingPathComponent(path, isDirectory: true)
        isTranscribing = true
        activeTranscriptionPath = path
        transcriptionStatus = "音声ファイルを確認中…"
        let dir = modelsDir(); let name = selectedModelName
        transcriptionOperationGeneration &+= 1
        let operation = transcriptionOperationGeneration
        let monitor = TranscriptionProgressMonitor()
        transcriptionProgressMonitor = monitor
        startTranscriptionWatchdog(
            operation: operation,
            monitor: monitor,
            maximumIdleSeconds: modelReady ? 600 : 1_200,
            activityName: "文字起こし"
        )

        transcriptionTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishTranscriptionTaskIfCurrent(operation: operation) }
            do {
                let inputs = try await self.loadTranscriptionInputs(
                    from: folder,
                    progressMonitor: monitor
                )
                guard self.transcriptionOperationGeneration == operation else { return }
                guard !self.isRecording else {
                    throw CancellationError()
                }
                guard !inputs.mic.isEmpty || !inputs.system.isEmpty else {
                    self.transcriptionStatus = "音声ファイルが見つかりません"
                    self.isTranscribing = false
                    self.activeTranscriptionPath = nil
                    self.completeTranscriptionQueueItem(path)
                    self.processTranscriptionQueue()
                    return
                }
                if let unreadable = inputs.unreadableFileName {
                    let message = "音声ファイルが破損しているため文字起こしをスキップしました: \(unreadable)"
                    RecLog.shared.log("transcribe: permanently skipped '\(path)': unreadable audio \(unreadable)")
                    self.transcriptionStatus = message
                    self.isTranscribing = false
                    self.activeTranscriptionPath = nil
                    self.completeTranscriptionQueueItem(path)
                    self.processTranscriptionQueue()
                    return
                }
                let t = Transcriber(modelsDir: dir, modelName: name)

                transcriptionStatus = modelReady ? "モデルをロード中…" : "モデルをダウンロード中…（初回は数百MB）"
                try await t.ensureLoaded(progressMonitor: monitor)
                guard self.transcriptionOperationGeneration == operation else { return }
                modelReady = true

                var selfText = ""
                var micSegs: [(start: Double, text: String)] = []
                var micOffset = 0.0
                for (i, part) in inputs.mic.enumerated() {
                    transcriptionStatus = "文字起こし中… 自分 \(i + 1)/\(inputs.mic.count)"
                    let (text, segs) = try await t.transcribe(
                        part.url,
                        progressMonitor: monitor
                    )
                    guard self.transcriptionOperationGeneration == operation else { return }
                    if !selfText.isEmpty { selfText += " " }
                    selfText += text
                    for seg in segs {
                        let s = seg.text.trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty { micSegs.append((start: seg.start + micOffset, text: s)) }
                    }
                    micOffset += part.duration
                }

                var otherText = ""
                var sysSegs: [(start: Double, text: String)] = []
                var sysOffset = 0.0
                for (i, part) in inputs.system.enumerated() {
                    transcriptionStatus = "文字起こし中… 相手 \(i + 1)/\(inputs.system.count)"
                    let (text, segs) = try await t.transcribe(
                        part.url,
                        progressMonitor: monitor
                    )
                    guard self.transcriptionOperationGeneration == operation else { return }
                    if !otherText.isEmpty { otherText += " " }
                    otherText += text
                    for seg in segs {
                        let s = seg.text.trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty { sysSegs.append((start: seg.start + sysOffset, text: s)) }
                    }
                    sysOffset += part.duration
                }

                let fileSuffix = "_\(name)"
                var outputs: [TranscriptOutput] = []
                if !selfText.isEmpty {
                    let fname = "transcript_self\(fileSuffix).txt"
                    outputs.append(TranscriptOutput(fileName: fname, text: selfText))
                }
                if !otherText.isEmpty {
                    let fname = "transcript_other\(fileSuffix).txt"
                    outputs.append(TranscriptOutput(fileName: fname, text: otherText))
                }
                let merged = mergeTranscripts(mic: micSegs, sys: sysSegs)
                if !merged.isEmpty {
                    let fname = "transcript\(fileSuffix).txt"
                    outputs.append(TranscriptOutput(fileName: fname, text: merged))
                }
                let external = externalTranscript(sysSegs)
                if !external.isEmpty {
                    let fname = "transcript_external\(fileSuffix).txt"
                    outputs.append(TranscriptOutput(fileName: fname, text: external))
                }
                let written = try await self.writeTranscriptionOutputs(
                    outputs,
                    to: folder,
                    progressMonitor: monitor
                )
                guard self.transcriptionOperationGeneration == operation else { return }

                RecLog.shared.log("transcribe: done, wrote \(written.joined(separator: ", "))")
                refreshTranscriptState()
                refreshWeeklyMeetings()
                if !written.isEmpty {
                    self.updateWeeklySummary(afterTranscriptionAt: path)
                }
                modelReady = true
                transcriptionStatus = written.isEmpty ? "文字起こし結果なし" : "完了: \(written.joined(separator: ", "))"
                isTranscribing = false
                activeTranscriptionPath = nil
                completeTranscriptionQueueItem(path)
                processTranscriptionQueue()

                if autoTranscribe && !written.isEmpty {
                    sendNotification(title: "文字起こし完了", body: path)
                }
            } catch {
                guard self.transcriptionOperationGeneration == operation else {
                    RecLog.shared.log("transcribe: ignored late completion for stale operation '\(path)'")
                    return
                }
                RecLog.shared.log("transcribe: failed '\(path)': \(error.localizedDescription)")
                self.handleTranscriptionFailure(path: path, error: error)
            }
        }
    }

    private func loadTranscriptionInputs(
        from folder: URL,
        progressMonitor: TranscriptionProgressMonitor
    ) async throws -> TranscriptionInputs {
        try await withCheckedThrowingContinuation { continuation in
            let completion = ThrowingContinuationGate<TranscriptionInputs>(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                completion.resolve(.failure(NSError(
                    domain: "wrgent", code: 50,
                    userInfo: [NSLocalizedDescriptionKey: "音声ファイル確認が15秒以内に完了しませんでした"]
                )))
            }
            transcriptionIOQueue.async {
                do {
                    let inputs = try Self.scanTranscriptionInputs(in: folder)
                    progressMonitor.markProgress()
                    completion.resolve(.success(inputs))
                } catch {
                    completion.resolve(.failure(error))
                }
            }
        }
    }

    nonisolated private static func scanTranscriptionInputs(in folder: URL) throws -> TranscriptionInputs {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        func urls(prefix: String) -> [URL] {
            files.filter {
                $0.lastPathComponent.hasPrefix(prefix + "_part") && $0.pathExtension == "m4a"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var unreadable: String?
        func inspect(_ urls: [URL]) -> [TranscriptionPart] {
            urls.compactMap { url in
                do {
                    let file = try AVAudioFile(forReading: url)
                    let duration = Double(file.length) / file.processingFormat.sampleRate
                    return TranscriptionPart(url: url, duration: duration)
                } catch {
                    if unreadable == nil { unreadable = url.lastPathComponent }
                    return nil
                }
            }
        }
        return TranscriptionInputs(
            mic: inspect(urls(prefix: "mic")),
            system: inspect(urls(prefix: "system")),
            unreadableFileName: unreadable
        )
    }

    private func writeTranscriptionOutputs(
        _ outputs: [TranscriptOutput],
        to folder: URL,
        progressMonitor: TranscriptionProgressMonitor
    ) async throws -> [String] {
        guard !outputs.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ThrowingContinuationGate<[String]>(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                completion.resolve(.failure(NSError(
                    domain: "wrgent", code: 51,
                    userInfo: [NSLocalizedDescriptionKey: "文字起こし結果の保存が15秒以内に完了しませんでした"]
                )))
            }
            transcriptionIOQueue.async {
                do {
                    var written: [String] = []
                    for output in outputs {
                        guard progressMonitor.shouldContinue() else { throw CancellationError() }
                        try output.text.write(
                            to: folder.appendingPathComponent(output.fileName),
                            atomically: true,
                            encoding: .utf8
                        )
                        written.append(output.fileName)
                        progressMonitor.markProgress()
                    }
                    completion.resolve(.success(written))
                } catch {
                    completion.resolve(.failure(error))
                }
            }
        }
    }

    private func startTranscriptionWatchdog(
        operation: UInt64,
        monitor: TranscriptionProgressMonitor,
        maximumIdleSeconds: TimeInterval,
        activityName: String
    ) {
        transcriptionWatchdogTask?.cancel()
        transcriptionWatchdogTask = Task { @MainActor [weak self] in
            do {
                while let self,
                      self.transcriptionOperationGeneration == operation,
                      self.isTranscribing {
                    try await Task.sleep(for: .seconds(30))
                    guard self.transcriptionOperationGeneration == operation,
                          self.isTranscribing else { return }
                    let idle = monitor.secondsSinceProgress()
                    guard idle >= maximumIdleSeconds else { continue }
                    RecLog.shared.log(
                        "transcribe: \(activityName) made no progress for \(Int(idle))s; disabling until restart"
                    )
                    monitor.cancel()
                    self.transcriptionTask?.cancel()
                    self.transcriptionOperationGeneration &+= 1
                    self.transcriptionTask = nil
                    self.transcriptionWatchdogTask = nil
                    self.transcriptionProgressMonitor = nil
                    self.isTranscribing = false
                    self.activeTranscriptionPath = nil
                    self.transcriptionDisabledUntilRestart = true
                    self.transcriptionStatus = "\(activityName)が応答しないため停止しました。wrgentを再起動してください"
                    return
                }
            } catch {}
        }
    }

    private func finishTranscriptionTaskIfCurrent(operation: UInt64) {
        guard transcriptionOperationGeneration == operation else { return }
        transcriptionWatchdogTask?.cancel()
        transcriptionWatchdogTask = nil
        transcriptionProgressMonitor = nil
        transcriptionTask = nil
    }

    private func pauseTranscriptionForRecording() {
        guard isTranscribing else { return }
        let cancelledOperation = transcriptionOperationGeneration
        let cancelledTask = transcriptionTask
        transcriptionOperationGeneration &+= 1
        transcriptionProgressMonitor?.cancel()
        transcriptionTask?.cancel()
        transcriptionWatchdogTask?.cancel()
        transcriptionTask = nil
        transcriptionWatchdogTask = nil
        transcriptionProgressMonitor = nil
        isTranscribing = false
        activeTranscriptionPath = nil
        transcriptionStatus = "録音を優先するため文字起こしを一時停止しました"
        RecLog.shared.log("transcribe: cancelled current operation to prioritize recording")

        guard let cancelledTask else { return }
        self.cancelledTranscriptionOperation = cancelledOperation
        transcriptionCancellationGuardTask?.cancel()
        transcriptionCancellationGuardTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: .seconds(self.transcriptionCancellationGraceSeconds))
            } catch {
                return
            }
            guard let self,
                  self.cancelledTranscriptionOperation == cancelledOperation else { return }
            self.transcriptionCancellationGuardTask = nil
            self.transcriptionDisabledUntilRestart = true
            self.transcriptionStatus = "中断した文字起こしが終了しないため、再起動まで文字起こしを停止しました"
            RecLog.shared.log(
                "transcribe: cancelled operation \(cancelledOperation) did not exit within \(Int(self.transcriptionCancellationGraceSeconds))s; circuit opened"
            )
        }
        Task.detached(priority: .utility) { [weak self] in
            await cancelledTask.value
            await self?.cancelledTranscriptionDidExit(operation: cancelledOperation)
        }
    }

    private func cancelledTranscriptionDidExit(operation: UInt64) {
        guard cancelledTranscriptionOperation == operation else { return }
        cancelledTranscriptionOperation = nil
        transcriptionCancellationGuardTask?.cancel()
        transcriptionCancellationGuardTask = nil
        RecLog.shared.log("transcribe: cancelled operation \(operation) exited")
        if !transcriptionDisabledUntilRestart {
            processTranscriptionQueue()
        }
    }

    private func handleTranscriptionFailure(path: String, error: Error) {
        isTranscribing = false
        activeTranscriptionPath = nil
        persistTranscriptionQueue()
        let nsError = error as NSError
        if nsError.domain == "wrgent" && (nsError.code == 50 || nsError.code == 51) {
            transcriptionIOTimeoutCount += 1
            if transcriptionIOTimeoutCount >= maxTranscriptionIOTimeouts {
                transcriptionDisabledUntilRestart = true
                transcriptionStatus = "保存先が繰り返し応答しないため文字起こしを停止しました。wrgentを再起動してください"
                RecLog.shared.log(
                    "transcribe: I/O timeout circuit opened after \(transcriptionIOTimeoutCount) failures"
                )
                return
            }
        }
        let retryCount = (transcriptionRetryCounts[path] ?? 0) + 1
        transcriptionRetryCounts[path] = retryCount
        if retryCount >= maxTranscriptionRetriesPerRun {
            quarantinedTranscriptions.insert(path)
            transcriptionStatus = "文字起こしをこの起動中は保留しました（\(retryCount)回失敗）: \(error.localizedDescription)"
            RecLog.shared.log(
                "transcribe: quarantined '\(path)' after \(retryCount) failures; continuing queue"
            )
            processTranscriptionQueue()
        } else {
            transcriptionStatus = "文字起こし失敗（\(retryCount)/\(maxTranscriptionRetriesPerRun)）: \(error.localizedDescription)"
            scheduleTranscriptionRetry(attempt: retryCount)
        }
    }

    // MARK: - Auto-transcription queue

    private func scheduleAutoTranscription(for recordingName: String) {
        guard autoTranscribe else { return }
        let currentWeek = WeeklySummaryGenerator.weekFolderName(for: Date())
        guard TranscriptionQueuePolicy.isEligibleForAutomaticTranscription(
            recordingName, currentWeek: currentWeek
        ) else {
            RecLog.shared.log("autoTranscribe: ignored past-week recording '\(recordingName)'")
            return
        }
        enqueueTranscription(recordingName)
        processTranscriptionQueue()
    }

    private func enqueueTranscription(_ path: String) {
        guard activeTranscriptionPath != path, !transcriptionQueue.contains(path) else { return }
        transcriptionQueue.append(path)
        pendingTranscriptionCount = transcriptionQueue.count
        persistTranscriptionQueue()
        RecLog.shared.log("autoTranscribe: queued '\(path)', queue=\(transcriptionQueue.count)")
    }

    private func processTranscriptionQueue() {
        guard !isTranscribing, !isRecording, !isStarting, !isFinalizingRecording,
              !isSystemSleeping, transcriptionRetryTask == nil,
              cancelledTranscriptionOperation == nil,
              !transcriptionDisabledUntilRestart else { return }
        guard let name = TranscriptionQueuePolicy.nextRunnable(
            in: transcriptionQueue,
            quarantined: quarantinedTranscriptions
        ) else {
            if !transcriptionQueue.isEmpty {
                transcriptionStatus = "文字起こしを保留中: \(transcriptionQueue.count)件（アプリ再起動またはモデル変更で再試行）"
            }
            return
        }
        RecLog.shared.log("autoTranscribe: starting '\(name)', queued=\(transcriptionQueue.count)")
        selectRecording(name)
        runTranscription(path: name)
    }

    private func completeTranscriptionQueueItem(_ path: String) {
        transcriptionQueue.removeAll { $0 == path }
        transcriptionRetryCounts.removeValue(forKey: path)
        quarantinedTranscriptions.remove(path)
        pendingTranscriptionCount = transcriptionQueue.count
        persistTranscriptionQueue()
    }

    private func transcriptionQueueURL() -> URL {
        library().appendingPathComponent(transcriptionQueueFileName)
    }

    private func persistTranscriptionQueue() {
        guard let data = try? JSONEncoder().encode(transcriptionQueue) else { return }
        let url = transcriptionQueueURL()
        stateIOQueue.async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                RecLog.shared.log("autoTranscribe: queue persist failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadTranscriptionQueue() {
        let url = transcriptionQueueURL()
        let library = library()
        let currentWeek = WeeklySummaryGenerator.weekFolderName(for: Date())
        queueLoadGeneration &+= 1
        let generation = queueLoadGeneration
        stateIOQueue.async { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let saved = try? JSONDecoder().decode([String].self, from: data) else { return }
            let fm = FileManager.default
            let restored = TranscriptionQueuePolicy.restoredAutomaticQueue(
                from: saved,
                currentWeek: currentWeek
            ) {
                fm.fileExists(atPath: library.appendingPathComponent($0, isDirectory: true).path)
            }
            let removed = saved.count - restored.count
            Task { @MainActor [weak self] in
                guard let self,
                      self.queueLoadGeneration == generation,
                      self.library() == library else { return }
                let newlyQueued = self.transcriptionQueue.filter { !restored.contains($0) }
                self.transcriptionQueue = restored + newlyQueued
                self.pendingTranscriptionCount = self.transcriptionQueue.count
                self.persistTranscriptionQueue()
                if removed > 0 {
                    RecLog.shared.log(
                        "autoTranscribe: removed \(removed) missing or past-week item(s) from saved queue"
                    )
                }
                if !restored.isEmpty {
                    RecLog.shared.log("autoTranscribe: restored queue=\(restored.count)")
                }
                self.processTranscriptionQueue()
            }
        }
    }

    private func scheduleTranscriptionRetry(attempt: Int) {
        guard transcriptionRetryTask == nil else { return }
        let delaySeconds = TranscriptionQueuePolicy.retryDelaySeconds(attempt: attempt)
        transcriptionRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self else { return }
            self.transcriptionRetryTask = nil
            self.processTranscriptionQueue()
        }
    }

    private func enqueuePendingTranscriptions() {
        guard autoTranscribe else { return }
        let lib = library()
        let currentWeek = WeeklySummaryGenerator.weekFolderName(for: Date())
        let model = selectedModelName
        pendingScanGeneration &+= 1
        let generation = pendingScanGeneration
        libraryIOQueue.async { [weak self] in
            let paths = Self.pendingTranscriptionPaths(
                in: lib,
                currentWeek: currentWeek,
                modelName: model
            )
            Task { @MainActor [weak self] in
                guard let self,
                      self.pendingScanGeneration == generation,
                      self.autoTranscribe,
                      self.selectedModelName == model,
                      self.library() == lib else { return }
                for path in paths { self.enqueueTranscription(path) }
                self.pendingTranscriptionCount = self.transcriptionQueue.count
                self.processTranscriptionQueue()
            }
        }
    }

    nonisolated private static func pendingTranscriptionPaths(
        in library: URL,
        currentWeek: String,
        modelName: String
    ) -> [String] {
        let fm = FileManager.default
        let meetingPattern = try? NSRegularExpression(pattern: #"^\d{8}_\d{6}"#)
        let week = library.appendingPathComponent(currentWeek, isDirectory: true)
        let meetings = (try? fm.contentsOfDirectory(
            at: week, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        return meetings.compactMap { meeting -> String? in
            let folderName = meeting.lastPathComponent
            let folderRange = NSRange(folderName.startIndex..<folderName.endIndex, in: folderName)
            guard meetingPattern?.firstMatch(in: folderName, range: folderRange) != nil,
                  WeeklySummaryGenerator.bestTranscriptURL(in: meeting, modelName: modelName) == nil
            else { return nil }
            let files = (try? fm.contentsOfDirectory(at: meeting, includingPropertiesForKeys: nil)) ?? []
            let hasAudio = files.contains {
                ($0.lastPathComponent.hasPrefix("mic_part") ||
                 $0.lastPathComponent.hasPrefix("system_part")) && $0.pathExtension == "m4a"
            }
            return hasAudio ? "\(currentWeek)/\(folderName)" : nil
        }
    }

    // MARK: - Weekly meetings

    func refreshWeeklyMeetings() {
        let week = selectedWeek
        guard !week.isEmpty else {
            weeklyMeetings = []
            return
        }
        let library = library()
        let weekDir = library.appendingPathComponent(week, isDirectory: true)
        let model = selectedModelName
        weeklyMeetingsRefreshGeneration &+= 1
        let generation = weeklyMeetingsRefreshGeneration
        libraryIOQueue.async { [weak self] in
            let records = WeeklySummaryGenerator.scanMeetings(in: weekDir, modelName: model).map {
                MeetingRecord(
                    id: $0.folderName,
                    weekFolder: week,
                    date: $0.date,
                    displayName: $0.displayName,
                    hasTranscript: $0.hasTranscript,
                    includeInInsight: $0.includeInInsight,
                    useExternalTranscriptForSummary: $0.useExternalTranscriptForSummary
                )
            }
            Task { @MainActor [weak self] in
                guard let self,
                      self.weeklyMeetingsRefreshGeneration == generation,
                      self.selectedWeek == week,
                      self.selectedModelName == model,
                      self.library() == library else { return }
                self.weeklyMeetings = records
            }
        }
    }

    // MARK: - Weekly summary

    private func updateWeeklySummary(afterTranscriptionAt path: String) {
        guard let weekName = path.split(separator: "/", maxSplits: 1).first.map(String.init) else { return }
        updateWeeklySummary(forWeek: weekName)
    }

    private func updateWeeklySummary(forWeek weekName: String) {
        guard weekName.range(of: #"^\d{4}_W\d{2}$"#, options: .regularExpression) != nil else { return }
        let library = library()
        let weekDir = library.appendingPathComponent(weekName, isDirectory: true)
        let model = selectedModelName
        summaryGeneration &+= 1
        let generation = summaryGeneration
        isGeneratingSummary = true
        libraryIOQueue.async { [weak self] in
            let result = Result {
                try WeeklySummaryGenerator.generate(
                    weekFolderURL: weekDir,
                    weekFolderName: weekName,
                    modelName: model
                )
            }
            Task { @MainActor [weak self] in
                guard let self,
                      self.summaryGeneration == generation,
                      self.library() == library else { return }
                switch result {
                case .success(let url):
                    RecLog.shared.log("weekly summary: auto-updated \(url.path)")
                case .failure(let error):
                    RecLog.shared.log("weekly summary: auto-update failed: \(error.localizedDescription)")
                }
                self.isGeneratingSummary = false
            }
        }
    }

    func openWeeklyReportInCodex() {
        let weekName = selectedWeek
        guard weekName.range(of: #"^\d{4}_W\d{2}$"#, options: .regularExpression) != nil else {
            statusMessage = "週報生成失敗: 対象週を選択してください"
            return
        }

        openCodexSkill(
            "$weekly-report WEEK=\(weekName)",
            successMessage: "Codexで\(weekName)の週報生成を準備しました"
        )
    }

    func openCalendarImportInCodex() {
        let weekName = selectedWeek
        guard weekName.range(of: #"^\d{4}_W\d{2}$"#, options: .regularExpression) != nil else {
            statusMessage = "予定取得失敗: 対象週を選択してください"
            return
        }
        openCodexSkill(
            "$wrgent-calendar-import WEEK=\(weekName)",
            successMessage: "Codexで\(weekName)の予定取得を準備しました"
        )
    }

    private func openCodexSkill(_ prompt: String, successMessage: String) {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "path", value: "/Users/tatsuzuk/Documents/Codex/weekly-report"),
            URLQueryItem(name: "prompt", value: prompt)
        ]

        guard let url = components.url, NSWorkspace.shared.open(url) else {
            statusMessage = "Codexを開けませんでした"
            return
        }

        statusMessage = successMessage
    }

    private func mergeTranscripts(
        mic: [(start: Double, text: String)],
        sys: [(start: Double, text: String)]
    ) -> String {
        struct Line { let start: Double; let text: String }
        let lines = mic.map { Line(start: $0.start, text: "[自分] \($0.text)") }
                   + sys.map { Line(start: $0.start, text: "[相手] \($0.text)") }
        return lines.sorted { $0.start < $1.start }
                    .map { $0.text }
                    .joined(separator: "\n")
    }

    private func externalTranscript(_ sys: [(start: Double, text: String)]) -> String {
        sys.sorted { $0.start < $1.start }
            .map { "[相手] \($0.text)" }
            .joined(separator: "\n")
    }

    nonisolated private static func ensureExternalTranscripts(in meetingFolder: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: meetingFolder, includingPropertiesForKeys: nil)) ?? []
        for allURL in files where allURL.lastPathComponent.hasPrefix("transcript_")
            && !allURL.lastPathComponent.hasPrefix("transcript_self_")
            && !allURL.lastPathComponent.hasPrefix("transcript_other_")
            && !allURL.lastPathComponent.hasPrefix("transcript_external_")
            && allURL.pathExtension == "txt" {
            let suffix = String(allURL.lastPathComponent.dropFirst("transcript".count))
            let externalURL = meetingFolder.appendingPathComponent("transcript_external\(suffix)")
            guard !fm.fileExists(atPath: externalURL.path),
                  let all = try? String(contentsOf: allURL, encoding: .utf8) else { continue }
            let external = all
                .split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { line -> String? in
                    guard !line.hasPrefix("[自分]") else { return nil }
                    return line.hasPrefix("[相手]") ? String(line) : "[相手] \(line)"
                }
                .joined(separator: "\n")
            try? external.write(to: externalURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Library & recordings

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        if panel.runModal() == .OK, let url = panel.url {
            cancelDelayedRecordingRetry(reason: "recording library changed")
            persistTranscriptionQueue()
            summaryGeneration &+= 1
            isGeneratingSummary = false
            // A disconnected old volume may have permanently occupied one of
            // these serial lanes. Switching libraries gets fresh lanes; stale
            // callbacks are already rejected by URL/generation checks.
            stateIOQueue = DispatchQueue(label: "wrgent.state-io.\(UUID().uuidString)", qos: .utility)
            libraryIOQueue = DispatchQueue(label: "wrgent.library-io.\(UUID().uuidString)", qos: .utility)
            transcriptionIOQueue = DispatchQueue(label: "wrgent.transcription-io.\(UUID().uuidString)", qos: .utility)
            recordingIOQueue = DispatchQueue(label: "wrgent.recording-io.\(UUID().uuidString)", qos: .userInitiated)
            finalizationIOQueue = DispatchQueue(label: "wrgent.finalization-io.\(UUID().uuidString)", qos: .userInitiated)
            libraryURL = url
            let key = bookmarkKey
            stateIOQueue.async {
                if let data = try? url.bookmarkData() {
                    UserDefaults.standard.set(data, forKey: key)
                }
            }
            updateLibraryDisplay()
            transcriptionQueue = []
            loadTranscriptionQueue()
            refreshRecordings()
            refreshModelState()
            refreshWeeklyMeetings()
            processTranscriptionQueue()
        }
    }

    private func resolveSavedLibrary() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            libraryURL = url
        }
    }

    func library() -> URL {
        if let u = libraryURL { return u }
        let fm = FileManager.default
        let base = fm.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        return base.appendingPathComponent("wrgent", isDirectory: true)
    }

    private func updateLibraryDisplay() { libraryDisplay = library().path }

    func refreshRecordings() {
        refreshAvailableWeeks()
        refreshWeeklyMeetings()
    }

    func openLibraryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([library()])
    }

    func selectRecording(_ name: String?) {
        selectedRecording = name
        if let name = name {
            // Extract just the recording folder name for display/naming
            let recName = name.components(separatedBy: "/").last ?? name
            recordingName = suffix(of: recName)
        } else {
            recordingName = ""
        }
        refreshTranscriptState()
    }

    // MARK: - Name helpers

    private func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:.\"'").union(.newlines)
        return s.components(separatedBy: bad).joined(separator: "_")
                .trimmingCharacters(in: .whitespaces)
    }

    private func folderName(timestamp: String, name: String) -> String {
        let n = sanitize(name)
        return n.isEmpty ? timestamp : "\(timestamp) - \(n)"
    }

    private func timestampPrefix(of folder: String) -> String {
        if let r = folder.range(of: " - ") { return String(folder[..<r.lowerBound]) }
        return folder
    }

    private func suffix(of folder: String) -> String {
        if let r = folder.range(of: " - ") { return String(folder[r.upperBound...]) }
        return ""
    }

    // MARK: - Recording control

    /// Manual recording is the emergency fallback. Pressing it while an automatic
    /// start is stuck cancels that attempt and immediately creates a clean attempt.
    func startRecording() {
        guard !isRecording, !isFinalizingRecording,
              delayedRecordingRetryTask == nil else { return }
        if isStarting {
            let followsZoomLifecycle = currentStartFollowsZoomLifecycle
            RecLog.shared.log("manual start: replacing in-progress automatic start")
            cancelRecordingStart(reason: "manual retry")
            scheduleDelayedRecordingRetry(followsZoomLifecycle: followsZoomLifecycle)
            return
        }
        beginRecordingStart(source: "manual", followsZoomLifecycle: false)
    }

    private func startRecordingAutomatically() {
        guard !isRecording, !isStarting, !isFinalizingRecording,
              delayedRecordingRetryTask == nil else { return }
        if let retryAt = nextAutomaticStartRetryAt, Date() < retryAt {
            return
        }
        guard !captureSystemAudio || !needsScreenPermission else {
            statusMessage = "画面収録の許可が必要です。許可後にwrgentを再起動してください"
            notifyAutomaticStartFailureOnce(statusMessage)
            return
        }
        beginRecordingStart(source: "zoom", followsZoomLifecycle: true)
    }

    private func scheduleDelayedRecordingRetry(followsZoomLifecycle: Bool) {
        delayedRecordingRetryGeneration &+= 1
        let generation = delayedRecordingRetryGeneration
        delayedRecordingRetryFollowsZoomLifecycle = followsZoomLifecycle
        statusMessage = "録音を再試行中…"
        delayedRecordingRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self,
                  self.delayedRecordingRetryGeneration == generation else { return }
            self.delayedRecordingRetryTask = nil
            self.delayedRecordingRetryFollowsZoomLifecycle = false
            self.beginRecordingStart(
                source: "manual retry",
                followsZoomLifecycle: followsZoomLifecycle
            )
        }
    }

    private func cancelDelayedRecordingRetry(reason: String) {
        guard delayedRecordingRetryTask != nil else { return }
        RecLog.shared.log("recording retry: cancelled reason=\(reason)")
        delayedRecordingRetryGeneration &+= 1
        delayedRecordingRetryTask?.cancel()
        delayedRecordingRetryTask = nil
        delayedRecordingRetryFollowsZoomLifecycle = false
    }

    private func beginRecordingStart(source: String, followsZoomLifecycle: Bool) {
        guard !isRecording, !isStarting, !isFinalizingRecording,
              !isSystemSleeping else { return }
        guard writerFinalizationTimeoutCount < maxWriterFinalizationTimeouts else {
            statusMessage = "録音終了処理が繰り返し停止したため、アプリを再起動してください"
            if source == "zoom" { notifyAutomaticStartFailureOnce(statusMessage) }
            return
        }
        pauseTranscriptionForRecording()
        startAttemptID &+= 1
        let attempt = startAttemptID
        currentStartWasAutomatic = source == "zoom"
        currentStartFollowsZoomLifecycle = followsZoomLifecycle
        isStarting = true
        statusMessage = "録音を開始中…"
        lastFiles = []
        RecLog.shared.log("startRecording: attempt=\(attempt) source=\(source)")
        startAsyncTask = Task { @MainActor [weak self] in
            await self?.startAsync(
                attempt: attempt,
                source: source,
                followsZoomLifecycle: followsZoomLifecycle
            )
        }
        startGuardTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(55))
            await self?.handleRecordingStartTimeout(attempt: attempt)
        }
    }

    private func handleRecordingStartTimeout(attempt: UInt64) {
        guard isStarting, startAttemptID == attempt else { return }
        let wasAutomatic = currentStartWasAutomatic
        RecLog.shared.log("startRecording: attempt=\(attempt) stuck after 55s, forcing teardown")
        cancelRecordingStart(reason: "startAsync 55s guard")
        if wasAutomatic {
            registerAutomaticStartFailure(reason: "録音の開始が55秒でタイムアウト")
        } else {
            statusMessage = "録音の開始がタイムアウトしました。手動でもう一度お試しください"
        }
    }

    private func cancelRecordingStart(reason: String) {
        guard isStarting || startAsyncTask != nil else { return }
        RecLog.shared.log("startRecording: cancel attempt=\(startAttemptID) reason=\(reason)")
        startAttemptID &+= 1 // invalidates every continuation belonging to the old attempt
        startAsyncTask?.cancel(); startAsyncTask = nil
        startGuardTask?.cancel(); startGuardTask = nil
        teardown(reason: reason)
        isStarting = false
        currentStartWasAutomatic = false
        currentStartFollowsZoomLifecycle = false
        discardEmptyActiveRecordingFolder()
    }

    private func resetAutomaticStartBackoff() {
        automaticStartFailureCount = 0
        nextAutomaticStartRetryAt = nil
        automaticStartFailureNotificationSent = false
    }

    private func registerAutomaticStartFailure(reason: String) {
        automaticStartFailureCount += 1
        let delay = TranscriptionQueuePolicy.automaticStartRetryDelaySeconds(
            failureCount: automaticStartFailureCount
        )
        nextAutomaticStartRetryAt = Date().addingTimeInterval(TimeInterval(delay))
        statusMessage = "録音開始に失敗しました。\(delay)秒後に自動再試行します（手動開始も使用できます）"
        RecLog.shared.log(
            "auto-start: failure=\(automaticStartFailureCount), backoff=\(delay)s, reason=\(reason)"
        )
        notifyAutomaticStartFailureOnce("\(reason)。\(delay)秒後に再試行します")
    }

    private func notifyAutomaticStartFailureOnce(_ body: String) {
        guard !automaticStartFailureNotificationSent else { return }
        automaticStartFailureNotificationSent = true
        sendNotification(title: "Zoom録音を開始できませんでした", body: body)
    }

    func stopRecording() {
        stopRecording(replyToTermination: false)
    }

    private func stopRecording(replyToTermination: Bool) {
        if isFinalizingRecording {
            replyToTerminationAfterFinalizing = replyToTerminationAfterFinalizing || replyToTermination
            return
        }
        if isStarting && !isRecording {
            cancelRecordingStart(reason: "user stop during startup")
            if replyToTermination { NSApp.reply(toApplicationShouldTerminate: true) }
            return
        }
        guard isRecording else {
            if replyToTermination { NSApp.reply(toApplicationShouldTerminate: true) }
            return
        }
        RecLog.shared.log("stopRecording: begin")
        let finishingMixer = mixer
        mixer = nil
        let folder = activeRecordingFolder
        let weekFolder = activeWeekFolder
        let timestamp = activeTimestamp
        let finalRecordingName = recordingName
        let desiredFolderName = folder.map { _ in
            folderName(timestamp: timestamp, name: finalRecordingName)
        }
        activeRecordingFolder = nil
        activeWeekFolder = ""
        activeTimestamp = ""
        micWriter = nil; sysWriter = nil; mixWriter = nil
        isRecording = false
        isFinalizingRecording = true
        replyToTerminationAfterFinalizing = replyToTerminationAfterFinalizing || replyToTermination
        elapsed = 0
        startDate = nil
        statusMessage = "録音を保存中…"
        teardown(reason: "recording stop", stopMixer: false)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result: RecordingFinalizationResult
            do {
                let saved = try await finishingMixer?.stopAndFinish() ?? []
                result = try await self.finalizeRecordingFilesWithTimeout(
                    saved: saved,
                    folder: folder,
                    desiredFolderName: desiredFolderName
                )
            } catch {
                RecLog.shared.log("stopRecording: writer finalization timed out/error: \(error.localizedDescription)")
                let nsError = error as NSError
                if nsError.domain == "wrgent" && (nsError.code == 40 || nsError.code == 41) {
                    self.writerFinalizationTimeoutCount += 1
                }
                result = RecordingFinalizationResult(
                    finalFolder: folder,
                    savedURLs: [],
                    fileStats: [],
                    moveError: nil,
                    finalizationError: error.localizedDescription
                )
            }
            self.completeRecordingFinalization(
                result: result,
                weekFolder: weekFolder,
                replyToTermination: self.replyToTerminationAfterFinalizing
            )
        }
    }

    private func finalizeRecordingFilesWithTimeout(
        saved: [URL],
        folder: URL?,
        desiredFolderName: String?
    ) async throws -> RecordingFinalizationResult {
        try await withCheckedThrowingContinuation { continuation in
            let completion = ThrowingContinuationGate<RecordingFinalizationResult>(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                completion.resolve(.failure(NSError(
                    domain: "wrgent", code: 41,
                    userInfo: [NSLocalizedDescriptionKey: "録音フォルダの整理が8秒以内に完了しませんでした"]
                )))
            }
            finalizationIOQueue.async {
                let result = Self.finalizeRecordingFiles(
                    saved: saved,
                    folder: folder,
                    desiredFolderName: desiredFolderName
                )
                if !completion.resolve(.success(result)) {
                    RecLog.shared.log("stopRecording: folder finalization completed after timeout")
                }
            }
        }
    }

    nonisolated private static func finalizeRecordingFiles(
        saved: [URL],
        folder: URL?,
        desiredFolderName: String?
    ) -> RecordingFinalizationResult {
        var finalFolder = folder
        var moveError: String?
        if let folder, let desiredFolderName, desiredFolderName != folder.lastPathComponent {
            let destination = folder.deletingLastPathComponent()
                .appendingPathComponent(desiredFolderName, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: folder, to: destination)
                finalFolder = destination
            } catch {
                moveError = error.localizedDescription
            }
        }
        let savedURLs: [URL]
        if let folder, let finalFolder, folder != finalFolder {
            savedURLs = saved.map { url in
                finalFolder.appendingPathComponent(url.lastPathComponent)
            }
        } else {
            savedURLs = saved
        }
        let fileStats = savedURLs.map { url in
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
            return SavedFileStat(url: url, size: size)
        }
        return RecordingFinalizationResult(
            finalFolder: finalFolder,
            savedURLs: savedURLs,
            fileStats: fileStats,
            moveError: moveError,
            finalizationError: nil
        )
    }

    private func completeRecordingFinalization(
        result: RecordingFinalizationResult,
        weekFolder: String,
        replyToTermination: Bool
    ) {
        if let finalFolder = result.finalFolder {
            selectedRecording = "\(weekFolder)/\(finalFolder.lastPathComponent)"
        }
        let justRecordedPath = result.finalFolder.flatMap {
            weekFolder.isEmpty ? nil : "\(weekFolder)/\($0.lastPathComponent)"
        }
        lastFiles = result.savedURLs
        for stat in result.fileStats {
            RecLog.shared.log("stopRecording: \(stat.url.lastPathComponent) size=\(stat.size) bytes")
        }
        isFinalizingRecording = false
        if let finalizationError = result.finalizationError {
            statusMessage = "録音の終了処理を打ち切りました: \(finalizationError)（保存先を確認してください）"
        } else if let moveError = result.moveError {
            RecLog.shared.log("stopRecording: folder rename failed: \(moveError)")
            statusMessage = result.savedURLs.isEmpty
                ? "保存ファイルがありません（ログを確認してください）"
                : "保存しました（フォルダ名の変更のみ失敗）"
        } else {
            statusMessage = result.savedURLs.isEmpty
                ? "保存ファイルがありません（ログを確認してください）"
                : "保存しました（\(result.savedURLs.count)ファイル）"
        }
        if result.finalizationError == nil,
           !result.savedURLs.isEmpty,
           let justRecordedPath {
            // A rename collision does not invalidate the recording. Queue the
            // actual source folder instead of waiting for a later app activation.
            scheduleAutoTranscription(for: justRecordedPath)
        }
        if replyToTermination {
            replyToTerminationAfterFinalizing = false
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            refreshAvailableWeeks()
            refreshWeeklyMeetings()
            processTranscriptionQueue()
        }
    }

    private func discardEmptyActiveRecordingFolder() {
        guard !isRecording, let folder = activeRecordingFolder else { return }
        activeRecordingFolder = nil
        activeWeekFolder = ""
        activeTimestamp = ""
        recordingIOQueue.async {
            Self.removeRecordingFolderIfEmpty(folder)
        }
    }

    private func teardown(reason: String, stopMixer: Bool = true) {
        RecLog.shared.log("teardown: \(reason)")
        startGuardTask?.cancel(); startGuardTask = nil
        micRecoveryTask?.cancel(); micRecoveryTask = nil
        zoomTitleTask?.cancel(); zoomTitleTask = nil
        isRecoveringMic = false
        watchdogTask?.cancel(); watchdogTask = nil
        elapsedTask?.cancel(); elapsedTask = nil
        if stopMixer, let abandonedMixer = mixer {
            mixer = nil
            Task { _ = try? await abandonedMixer.stopAndFinish() }
        }
        if let s = stream {
            streamOutput?.deactivate()
            s.stopCapture { err in
                if let err = err { RecLog.shared.log("teardown: stopCapture error: \(err.localizedDescription)") }
            }
        }
        stream = nil
        streamOutput = nil
        activeSystemAudioAvailable = false
        micCapture.stop()
        activeMicAvailable = false
        activeRecordingSessionGeneration = 0
        recordingWasAutomatic = false
    }

    private func startAsync(
        attempt: UInt64,
        source: String,
        followsZoomLifecycle: Bool
    ) async {
        defer {
            if startAttemptID == attempt {
                if source == "zoom" {
                    if isRecording {
                        resetAutomaticStartBackoff()
                    } else if !needsScreenPermission {
                        registerAutomaticStartFailure(reason: "音声ソースを開始できませんでした")
                    }
                }
                startGuardTask?.cancel(); startGuardTask = nil
                startAsyncTask = nil
                isStarting = false
                currentStartWasAutomatic = false
                currentStartFollowsZoomLifecycle = false
                processTranscriptionQueue()
            }
        }

        guard !Task.isCancelled, startAttemptID == attempt else { return }

        let lib = library()
        RecLog.shared.configure(folder: lib)
        RecLog.shared.log("start: attempt=\(attempt) sys=\(captureSystemAudio) mic=\(captureMic) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")

        // Use local vars so a failed session never overwrites user preferences
        var useSys = captureSystemAudio
        var useMic = captureMic

        if useSys {
            if !CGPreflightScreenCaptureAccess() {
                RecLog.shared.log("start: screen-recording NOT granted -> aborting without blocking TCC prompt")
                needsScreenPermission = true
                statusMessage = "画面収録の許可が必要です。［システム設定を開く］から許可し、wrgentを再起動してください"
                return
            }
            needsScreenPermission = false
        }

        let tsf = DateFormatter(); tsf.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = tsf.string(from: Date())
        let weekName = WeeklySummaryGenerator.weekFolderName(for: Date())
        let prepared: PreparedRecordingFolder
        do {
            prepared = try await prepareRecordingFolder(
                library: lib,
                weekName: weekName,
                timestamp: timestamp
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == "wrgent", nsError.code == 20 {
                recordingFolderTimeoutCount += 1
            }
            statusMessage = "録音フォルダを準備できませんでした: \(error.localizedDescription)"
            RecLog.shared.log("start: recording folder preparation failed: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled, startAttemptID == attempt else {
            discardPreparedRecordingFolderIfEmpty(prepared.folder)
            return
        }
        activeWeekFolder = prepared.weekName
        let folder = prepared.folder
        activeRecordingFolder = prepared.folder
        activeTimestamp = timestamp

        guard !Task.isCancelled, startAttemptID == attempt else { return }

        // Every attempt owns independent pumps/rings. If a framework writer from
        // an older session never returns, it cannot consume or contaminate a new
        // recording after the bounded finalization deadline.
        recordingSessionGeneration &+= 1
        let sessionGeneration = recordingSessionGeneration
        activeRecordingSessionGeneration = sessionGeneration
        micRecoveryAttemptsWithoutProgress = 0
        sysPump = AudioPump(name: "sys", sampleRate: sampleRate, channels: channelCount)
        micPump = AudioPump(name: "mic", sampleRate: sampleRate, channels: channelCount)

        if useMic {
            let granted = await requestMicAccess()
            if !granted {
                statusMessage = "マイクのアクセスが許可されていません（システム設定 > プライバシー > マイク）"
                useMic = false
            }
        }

        guard !Task.isCancelled, startAttemptID == attempt else { return }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: Int(bitrate)
        ]
        func makeWriter(_ base: String) -> SegmentWriter {
            SegmentWriter(folder: folder, baseName: base, settings: settings,
                          sampleRate: sampleRate, bitrate: bitrate, maxBytes: maxBytes)
        }
        sysPump.resetCounters(); micPump.resetCounters()
        sysPump.ring.reset(); micPump.ring.reset()

        if useMic {
            do {
                RecLog.shared.log("start: attempt=\(attempt) starting microphone")
                try await startMicCapture(sessionGeneration: sessionGeneration)
            } catch {
                RecLog.shared.log("mic: engine FAILED: \(error.localizedDescription)")
                useMic = false
                micCapture.stop()
            }
        }
        activeMicAvailable = useMic

        guard !Task.isCancelled, startAttemptID == attempt else { return }

        if useSys {
            do {
                guard systemCaptureTimeoutCount < maxSystemCaptureTimeouts else {
                    throw NSError(
                        domain: "wrgent", code: 13,
                        userInfo: [NSLocalizedDescriptionKey: "システム音声開始が繰り返し停止したため、アプリ再起動まで無効化しました"]
                    )
                }
                RecLog.shared.log("start: attempt=\(attempt) starting system audio")
                let capture = try await makeSystemAudioCapture()
                guard !Task.isCancelled, startAttemptID == attempt else {
                    capture.output.deactivate()
                    stopSystemStreamWithoutWaiting(
                        capture.stream,
                        context: "cancelled attempt"
                    )
                    return
                }
                stream = capture.stream
                streamOutput = capture.output
            } catch {
                let nsError = error as NSError
                if nsError.domain == "wrgent", nsError.code == 10 || nsError.code == 11 {
                    systemCaptureTimeoutCount += 1
                    RecLog.shared.log(
                        "scstream: timeout circuit count=\(systemCaptureTimeoutCount)/\(maxSystemCaptureTimeouts)"
                    )
                }
                RecLog.shared.log("scstream: startCapture FAILED: \(error.localizedDescription)")
                statusMessage = "システム音声の取得に失敗: \(error.localizedDescription)"
                useSys = false
            }
        }
        activeSystemAudioAvailable = useSys

        // If the guard task cancelled us while we were waiting on SCShareableContent, abort here.
        guard !Task.isCancelled, startAttemptID == attempt else { return }

        guard useSys || useMic else {
            teardown(reason: "no source available")
            discardEmptyActiveRecordingFolder()
            statusMessage = "音声ソースを開始できませんでした。もう一度お試しください"
            return
        }

        guard !followsZoomLifecycle || autoRecordZoom else {
            teardown(reason: "Zoom auto-record disabled before capture became active")
            discardEmptyActiveRecordingFolder()
            return
        }

        let mixW = makeWriter("mix")
        let micW = useMic ? makeWriter("mic") : nil
        let sysW = useSys ? makeWriter("system") : nil
        mixWriter = mixW; micWriter = micW; sysWriter = sysW

        let mx = Mixer(format: procFormat,
                       sysRing: useSys ? sysPump.ring : nil,
                       micRing: useMic ? micPump.ring : nil,
                       mixWriter: mixW, micWriter: micW, sysWriter: sysW)
        mixer = mx
        mx.start()

        startDate = Date()
        isRecording = true
        recordingWasAutomatic = followsZoomLifecycle
        RecLog.shared.log("start: attempt=\(attempt) recording active")
        statusMessage = "録音中…"
        if followsZoomLifecycle {
            sendNotification(title: "録音開始", body: "Zoomミーティングの録音を開始しました")
            scheduleZoomTitleDetection(sessionGeneration: sessionGeneration)
        }

        elapsedTask = Task { @MainActor [weak self] in
            do {
                while let self, self.isRecording {
                    if let s = self.startDate { self.elapsed = Date().timeIntervalSince(s) }
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch {}
        }

        mixerWriteCountAtLastCheck = 0
        micPushCountAtLastCheck = micPump.countSnapshot()
        sysPushCountAtLastCheck = sysPump.countSnapshot()
        watchdogTask = Task { @MainActor [weak self] in
            do {
                while let self, self.isRecording {
                    try await Task.sleep(for: .seconds(20))
                    guard self.isRecording else { return }
                    let current = self.mixWriter?.writeCountSnapshot() ?? 0
                    let micCurrent = self.micPump.countSnapshot()
                    let sysCurrent = self.sysPump.countSnapshot()
                    if current == self.mixerWriteCountAtLastCheck {
                        RecLog.shared.log("watchdog: mixer stalled at writeCount=\(current)")
                        self.unexpectedStop(reason: "録音データの書き込みが停止しました")
                        return
                    }
                    let micAdvanced = micCurrent > self.micPushCountAtLastCheck
                    let sysAdvanced = sysCurrent > self.sysPushCountAtLastCheck
                    if micAdvanced {
                        self.micRecoveryAttemptsWithoutProgress = 0
                    } else if self.activeMicAvailable && !self.isRecoveringMic {
                        if self.micRecoveryAttemptsWithoutProgress >= self.maxMicRecoveryAttemptsWithoutProgress {
                            RecLog.shared.log("watchdog: microphone recovery exhausted without buffers")
                            self.activeMicAvailable = false
                            self.micCapture.stop()
                            if self.activeSystemAudioAvailable && sysAdvanced {
                                self.statusMessage = "マイクを復旧できないため無効化しました（システム音声は録音継続中）"
                            } else {
                                self.unexpectedStop(reason: "マイクを復旧しても音声データが届きませんでした")
                                return
                            }
                        } else {
                            RecLog.shared.log("watchdog: microphone buffers stalled — scheduling recovery")
                            self.scheduleMicRecovery(reason: "watchdog detected no microphone buffers")
                        }
                    }
                    if self.activeSystemAudioAvailable && !sysAdvanced {
                        RecLog.shared.log("watchdog: system audio buffers stalled")
                        if self.activeMicAvailable && micAdvanced {
                            self.statusMessage = "システム音声が停止しています（マイク録音は継続中）"
                        }
                    }
                    let anyConfiguredSource = self.activeMicAvailable || self.activeSystemAudioAvailable
                    let anySourceAdvanced =
                        (self.activeMicAvailable && micAdvanced) ||
                        (self.activeSystemAudioAvailable && sysAdvanced)
                    if !anyConfiguredSource || !anySourceAdvanced {
                        if self.activeMicAvailable,
                           !self.activeSystemAudioAvailable,
                           self.isRecoveringMic {
                            // mic-only recordings need one watchdog interval for
                            // the bounded recovery attempt to run. Its failure
                            // path stops the recording when no system source exists.
                            RecLog.shared.log("watchdog: waiting for microphone recovery")
                        } else {
                            self.unexpectedStop(reason: "すべての音声入力が停止しました")
                            return
                        }
                    }
                    self.mixerWriteCountAtLastCheck = current
                    self.micPushCountAtLastCheck = micCurrent
                    self.sysPushCountAtLastCheck = sysCurrent
                }
            } catch {}
        }
    }

    private func prepareRecordingFolder(
        library: URL,
        weekName: String,
        timestamp: String
    ) async throws -> PreparedRecordingFolder {
        guard recordingFolderTimeoutCount < maxRecordingFolderTimeouts else {
            throw NSError(
                domain: "wrgent", code: 21,
                userInfo: [NSLocalizedDescriptionKey: "保存先が繰り返し応答しないため、アプリ再起動まで録音開始を停止しました"]
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate<PreparedRecordingFolder>(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                gate.resolve(.failure(NSError(
                    domain: "wrgent", code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "保存先が8秒以内に応答しませんでした"]
                )))
            }
            recordingIOQueue.async {
                do {
                    let weekDir = library.appendingPathComponent(weekName, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: weekDir,
                        withIntermediateDirectories: true
                    )
                    var preparedFolder: URL?
                    for attempt in 1...999 {
                        let folderName = attempt == 1
                            ? timestamp
                            : "\(timestamp) - 再録音\(attempt)"
                        let candidate = weekDir.appendingPathComponent(folderName, isDirectory: true)
                        if FileManager.default.fileExists(atPath: candidate.path) { continue }
                        do {
                            try FileManager.default.createDirectory(
                                at: candidate,
                                withIntermediateDirectories: false
                            )
                            preparedFolder = candidate
                            break
                        } catch {
                            // A second process may have won the name between the
                            // existence check and creation. Only retry that race.
                            if FileManager.default.fileExists(atPath: candidate.path) { continue }
                            throw error
                        }
                    }
                    guard let folder = preparedFolder else {
                        throw NSError(
                            domain: "wrgent", code: 22,
                            userInfo: [NSLocalizedDescriptionKey: "同じ時刻の録音フォルダが多すぎます"]
                        )
                    }
                    let prepared = PreparedRecordingFolder(weekName: weekName, folder: folder)
                    if !gate.resolve(.success(prepared)) {
                        Self.removeRecordingFolderIfEmpty(folder)
                        RecLog.shared.log("recording folder: removed late unused folder \(folder.lastPathComponent)")
                    }
                } catch {
                    gate.resolve(.failure(error))
                }
            }
        }
    }

    private func discardPreparedRecordingFolderIfEmpty(_ folder: URL) {
        recordingIOQueue.async {
            Self.removeRecordingFolderIfEmpty(folder)
        }
    }

    nonisolated private static func removeRecordingFolderIfEmpty(_ folder: URL) {
        let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard items?.isEmpty == true else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            RecLog.shared.log(
                "recording folder: unused-folder cleanup failed for \(folder.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Mic capture

    private func startMicCapture(sessionGeneration: UInt64) async throws {
        guard abandonedMicControllerCount < maxMicCaptureTimeouts else {
            throw NSError(
                domain: "wrgent", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "マイク開始が繰り返し停止したため、アプリ再起動までマイクを無効化しました"]
            )
        }
        let controller = micCapture
        let pump = micPump
        do {
            try await controller.start(pump: pump) { [weak self, weak controller] in
                Task { @MainActor in
                    guard let self, let controller,
                          self.isRecording,
                          self.activeRecordingSessionGeneration == sessionGeneration,
                          self.micCapture === controller else { return }
                    self.scheduleMicRecovery(reason: "audio device configuration changed")
                }
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == "wrgent", nsError.code == 3, micCapture === controller {
                abandonedMicControllerCount += 1
                // The old serial queue may be permanently blocked inside
                // AVAudioEngine. Abandon it and give the next recording one
                // fresh controller, but cap replacements to prevent leaks.
                micCapture = MicCaptureController()
                RecLog.shared.log(
                    "mic: abandoned blocked controller (lifetime count=\(abandonedMicControllerCount)/\(maxMicCaptureTimeouts))"
                )
            }
            throw error
        }
    }

    /// Zoom commonly changes the microphone format while joining a meeting.
    /// This is a recoverable source change, not a reason to discard the whole recording.
    private func scheduleMicRecovery(reason: String) {
        guard isRecording, activeMicAvailable, !isRecoveringMic else { return }
        let sessionGeneration = activeRecordingSessionGeneration
        isRecoveringMic = true
        micRecoveryAttemptsWithoutProgress += 1
        micRecoveryTask?.cancel()
        RecLog.shared.log(
            "mic: configuration change — recovery \(micRecoveryAttemptsWithoutProgress)/\(maxMicRecoveryAttemptsWithoutProgress) scheduled (\(reason))"
        )
        micRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  !Task.isCancelled,
                  self.isRecording,
                  self.activeRecordingSessionGeneration == sessionGeneration else { return }
            defer {
                self.isRecoveringMic = false
                self.micRecoveryTask = nil
            }
            do {
                try await self.startMicCapture(sessionGeneration: sessionGeneration)
                guard !Task.isCancelled,
                      self.isRecording,
                      self.activeRecordingSessionGeneration == sessionGeneration else { return }
                self.activeMicAvailable = true
                self.micPushCountAtLastCheck = self.micPump.countSnapshot()
                RecLog.shared.log("mic: recovery succeeded")
                self.statusMessage = "録音中…（マイクを再接続しました）"
            } catch {
                self.activeMicAvailable = false
                RecLog.shared.log("mic: recovery failed: \(error.localizedDescription)")
                if self.activeSystemAudioAvailable {
                    self.statusMessage = "マイクの再接続に失敗しました（システム音声は録音継続中）"
                } else {
                    self.unexpectedStop(reason: "マイクの再接続に失敗しました: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - System audio capture

    private func makeSystemAudioCapture() async throws -> (stream: SCStream, output: StreamOutput) {
        let content = try await shareableContentWithTimeout()
        guard let display = content.displays.first else {
            throw NSError(domain: "wrgent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ディスプレイが見つかりません"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = Int(channelCount)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let pump = sysPump
        let output = StreamOutput { sampleBuffer in pump.push(sampleBuffer) }
        output.onError = { [weak self, weak output] error in
            Task { @MainActor in
                guard let self, let output,
                      self.isRecording, self.streamOutput === output else { return }
                self.activeSystemAudioAvailable = false
                RecLog.shared.log("scstream: runtime error: \(error.localizedDescription)")
                if self.activeMicAvailable {
                    self.statusMessage = "システム音声エラー（マイク録音は継続中）"
                    self.sendNotification(title: "システム音声が停止しました", body: "マイク録音は継続しています")
                } else {
                    self.unexpectedStop(reason: "システム音声エラー: \(error.localizedDescription)")
                }
            }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "wrgent.audio"))
        do {
            try await startCaptureWithTimeout(stream)
        } catch {
            output.deactivate()
            stopSystemStreamWithoutWaiting(stream, context: "failed start")
            throw error
        }
        return (stream, output)
    }

    private func stopSystemStreamWithoutWaiting(_ stream: SCStream, context: String) {
        let streamBox = SendableStreamBox(stream)
        Task.detached(priority: .utility) {
            do {
                try await streamBox.stream.stopCapture()
            } catch {
                RecLog.shared.log("scstream: \(context) stop error: \(error.localizedDescription)")
            }
        }
    }

    /// Completion-handler APIs are used deliberately here. A task group still
    /// waits for a cancelled child before leaving its scope; ScreenCaptureKit
    /// calls have been observed to ignore cancellation, making a nominal timeout
    /// wait forever. The one-shot gate lets the timeout actually return.
    private func shareableContentWithTimeout() async throws -> SCShareableContent {
        let box: SendableShareableContentBox = try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate<SendableShareableContentBox>(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                gate.resolve(.failure(NSError(
                    domain: "wrgent", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "SCShareableContent タイムアウト（15秒）"]
                )))
            }
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ) { content, error in
                if let content {
                    gate.resolve(.success(SendableShareableContentBox(content)))
                } else {
                    gate.resolve(.failure(error ?? NSError(
                        domain: "wrgent", code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "画面共有対象を取得できませんでした"]
                    )))
                }
            }
        }
        return box.content
    }

    private func startCaptureWithTimeout(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate<Void>(continuation)
            let streamBox = SendableStreamBox(stream)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                gate.resolve(.failure(NSError(
                    domain: "wrgent", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "SCStream.startCapture タイムアウト（8秒）"]
                )))
            }
            streamBox.stream.startCapture { error in
                if let error {
                    gate.resolve(.failure(error))
                } else if !gate.resolve(.success(())) {
                    // The stream started after the attempt had already timed out.
                    // Stop it so abandoned retries cannot accumulate captures.
                    streamBox.stream.stopCapture { lateStopError in
                        if let lateStopError {
                            RecLog.shared.log("scstream: late stop error: \(lateStopError.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Permissions

    private func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return (try? await withCheckedThrowingContinuation { continuation in
                let gate = ThrowingContinuationGate<Bool>(continuation)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10) {
                    gate.resolve(.success(false))
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    gate.resolve(.success(granted))
                }
            }) ?? false
        default: return false
        }
    }
}

// MARK: - SCStream output handler

private final class SendableStreamBox: @unchecked Sendable {
    let stream: SCStream
    init(_ stream: SCStream) { self.stream = stream }
}

/// SCShareableContent is an immutable framework snapshot, but the SDK does not
/// yet declare it Sendable. This box documents the single ownership transfer
/// from ScreenCaptureKit's completion queue to the awaiting recording attempt.
private final class SendableShareableContentBox: @unchecked Sendable {
    let content: SCShareableContent
    init(_ content: SCShareableContent) { self.content = content }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onAudio: (CMSampleBuffer) -> Void
    var onError: ((Error) -> Void)?
    private let stateLock = NSLock()
    private var active = true

    init(onAudio: @escaping (CMSampleBuffer) -> Void) { self.onAudio = onAudio }

    func deactivate() {
        stateLock.lock()
        active = false
        onError = nil
        stateLock.unlock()
    }

    private func callbacksIfActive() -> (((CMSampleBuffer) -> Void), ((Error) -> Void)?)? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard active else { return nil }
        return (onAudio, onError)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let callbacks = callbacksIfActive() else { return }
        callbacks.0(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard let callbacks = callbacksIfActive() else { return }
        RecLog.shared.log("scstream: didStopWithError: \(error.localizedDescription)")
        callbacks.1?(error)
    }
}

// MARK: - ZoomMonitor

final class ZoomMonitor: @unchecked Sendable {
    private var onMeetingStart: (@Sendable () -> Void)?
    private var onMeetingEnd: (@Sendable () -> Void)?
    /// Fires on every poll while meeting is active. Used by AudioRecorder to retry if recording didn't start.
    private var onMeetingStillActive: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "wrgent.zoommonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var wasMeetingActive = false
    private var consecutiveProbeFailures = 0
    private let maxProbeFailuresWhileRecording = 12

    func setCallbacks(
        onMeetingStart: @escaping @Sendable () -> Void,
        onMeetingEnd: @escaping @Sendable () -> Void,
        onMeetingStillActive: @escaping @Sendable () -> Void
    ) {
        // Callback retain/release and callback reads are confined to the same
        // queue as the timer, including rapid OFF -> ON transitions.
        queue.async { [weak self] in
            self?.onMeetingStart = onMeetingStart
            self?.onMeetingEnd = onMeetingEnd
            self?.onMeetingStillActive = onMeetingStillActive
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 5)
            t.setEventHandler { [weak self] in self?.check() }
            self.timer = t
            t.resume()
            RecLog.shared.log("zoomMonitor: started (polling every 5s)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.wasMeetingActive = false
            self?.consecutiveProbeFailures = 0
            RecLog.shared.log("zoomMonitor: stopped")
        }
    }

    private func check() {
        guard let active = meetingActiveProbe() else {
            consecutiveProbeFailures += 1
            if wasMeetingActive && consecutiveProbeFailures >= maxProbeFailuresWhileRecording {
                wasMeetingActive = false
                consecutiveProbeFailures = 0
                RecLog.shared.log("zoomMonitor: probe unavailable for 60s — conservatively ending recording")
                let cb = onMeetingEnd
                DispatchQueue.main.async { cb?() }
            }
            return
        }
        consecutiveProbeFailures = 0
        if active && !wasMeetingActive {
            wasMeetingActive = true
            RecLog.shared.log("zoomMonitor: meeting STARTED")
            let cb = onMeetingStart
            DispatchQueue.main.async { cb?() }
        } else if !active && wasMeetingActive {
            wasMeetingActive = false
            RecLog.shared.log("zoomMonitor: meeting ENDED")
            let cb = onMeetingEnd
            DispatchQueue.main.async { cb?() }
        } else if active && wasMeetingActive {
            let cb = onMeetingStillActive
            DispatchQueue.main.async { cb?() }
        }
    }

    private func meetingActiveProbe() -> Bool? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "CptHost"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do {
            try task.run()
            guard exited.wait(timeout: .now() + 1) == .success else {
                task.terminate()
                RecLog.shared.log("zoomMonitor: pgrep timed out; meeting state is unknown")
                return nil
            }
            return task.terminationStatus == 0
        } catch {
            RecLog.shared.log("zoomMonitor: pgrep failed: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - CMSampleBuffer -> AVAudioPCMBuffer

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(self),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
