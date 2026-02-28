// TranscriberIntegrationTests.swift — Feeds real audio through the transcriber.
// Requires the Parakeet model to be installed in ~/Library/Application Support/Chirp/models/.
// Skips gracefully if the model is not available.

import Testing
import Foundation
@testable import Chirp

@Suite("Transcriber Integration")
struct TranscriberIntegrationTests {

    /// Load 16 kHz mono Float32 WAV samples from a file.
    /// Parses the RIFF/WAV header to find the actual "data" chunk offset.
    private static func loadWAV(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Find the "data" chunk — its offset varies by encoder
        guard let dataChunkOffset = data.range(of: Data("data".utf8))?.lowerBound else {
            throw TestError.noDataChunk
        }
        // 4 bytes "data" + 4 bytes chunk size = 8 bytes before audio samples
        let audioStart = dataChunkOffset + 8
        guard data.count > audioStart else {
            throw TestError.tooShort
        }
        let audioData = data.subdata(in: audioStart..<data.count)
        let floatCount = audioData.count / MemoryLayout<Float>.size
        let samples = audioData.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self).prefix(floatCount))
        }
        return samples
    }

    /// Resolve model paths — checks env vars, App Support, and bazel runfiles.
    private static func findModelPaths() -> ModelPaths? {
        let fm = FileManager.default

        // Model directory: env var, App Support, or home-relative
        let modelDir: String
        if let envDir = ProcessInfo.processInfo.environment["CHIRP_MODEL_DIR"],
           fm.fileExists(atPath: envDir + "/encoder.int8.onnx") {
            modelDir = envDir
        } else {
            // Try FileManager's Application Support first, then HOME-relative
            let appSupportCandidates: [String] = [
                fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                    .first?.appendingPathComponent("Chirp/models").path,
                ProcessInfo.processInfo.environment["HOME"]
                    .map { "\($0)/Library/Application Support/Chirp/models" },
                NSHomeDirectory() + "/Library/Application Support/Chirp/models",
            ].compactMap { $0 }

            let modelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
            var found: String?
            for base in appSupportCandidates {
                let candidate = "\(base)/\(modelName)"
                if fm.fileExists(atPath: "\(candidate)/encoder.int8.onnx") {
                    found = candidate
                    break
                }
            }
            guard let dir = found else { return nil }
            modelDir = dir
        }

        // VAD: env var, bundle, runfiles root, or model dir
        let vadCandidates: [String] = [
            ProcessInfo.processInfo.environment["CHIRP_VAD_PATH"],
            Bundle.main.resourcePath.map { "\($0)/silero_vad.onnx" },
            // Bazel runfiles: executable is at .runfiles/_main/...xctest/Contents/MacOS/binary
            // VAD is at .runfiles/+deps+silero_vad/file/silero_vad.onnx
            Bundle.main.executablePath.flatMap { execPath in
                var url = URL(fileURLWithPath: execPath)
                // Walk up to the *.runfiles directory
                while !url.lastPathComponent.hasSuffix(".runfiles") {
                    let prev = url
                    url = url.deletingLastPathComponent()
                    if url == prev { return nil }
                }
                return url.appendingPathComponent("+deps+silero_vad/file/silero_vad.onnx").path
            },
            "\(modelDir)/silero_vad.onnx",
        ].compactMap { $0 }

        for vad in vadCandidates {
            if fm.fileExists(atPath: vad) {
                return ModelPaths(modelDir: modelDir, vadPath: vad)
            }
        }
        return nil
    }

    /// Find the test WAV file relative to the source file.
    private static func findTestWAV() -> String? {
        // Try relative to this source file, then common locations
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("hello_world.wav").path,
            "Tests/ChirpTests/hello_world.wav",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    enum TestError: Error {
        case tooShort
        case noDataChunk
    }

    // MARK: - Helpers

    /// Poll until a condition is true (up to 3s).
    @MainActor
    private static func poll(timeout: Int = 30, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<timeout {
            try await Task.sleep(nanoseconds: 100_000_000)
            if condition() { return }
        }
    }

    // MARK: - Unit-level tests

    @Test("Real transcriber produces output from speech audio")
    func realTranscription() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: Model not found — install Parakeet model or set CHIRP_MODEL_DIR + CHIRP_VAD_PATH")
            return
        }
        guard let wavPath = Self.findTestWAV() else {
            print("SKIP: hello_world.wav not found")
            return
        }

        let samples = try Self.loadWAV(path: wavPath)
        print("Loaded \(samples.count) samples (\(Double(samples.count) / 16000.0)s)")
        #expect(samples.count > 1600, "Audio too short")

        let transcriber = Transcriber()
        let ok = await transcriber.initialize(paths: paths)
        #expect(ok, "Transcriber failed to initialize")

        // Feed all audio at once (simulates a single utterance)
        let segments = await transcriber.feedAudio(samples: samples)
        print("feedAudio segments: \(segments)")

        // Flush remaining
        let flushed = await transcriber.flush()
        print("flush result: \"\(flushed)\"")

        let allText = (segments + [flushed])
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        print("Combined transcription: \"\(allText)\"")

        #expect(!allText.isEmpty, "Transcriber produced no output from speech audio")
        #expect(allText.contains("hello") || allText.contains("world") || allText.contains("test"),
                "Transcription doesn't contain expected words: \"\(allText)\"")
    }

    @Test("Transcriber feedAudio + peek + flush lifecycle")
    func transcriptionLifecycle() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: Model not found")
            return
        }
        guard let wavPath = Self.findTestWAV() else {
            print("SKIP: hello_world.wav not found")
            return
        }

        let samples = try Self.loadWAV(path: wavPath)
        let transcriber = Transcriber()
        let ok = await transcriber.initialize(paths: paths)
        #expect(ok)

        // Feed audio in chunks (simulates real-time streaming at ~85ms intervals)
        let chunkSize = 1360  // ~85ms at 16kHz
        var allSegments: [String] = []
        var chunkCount = 0

        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            let segs = await transcriber.feedAudio(samples: chunk)
            allSegments.append(contentsOf: segs)
            chunkCount += 1
        }
        print("Fed \(chunkCount) chunks, got \(allSegments.count) segments")

        // Peek should work if there's pending audio
        let peek = await transcriber.peekTranscription()
        print("peek: \(peek ?? "nil")")

        // Flush remaining
        let flushed = await transcriber.flush()
        print("flush: \"\(flushed)\"")

        let allText = (allSegments + [flushed])
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("Full transcription: \"\(allText)\"")

        #expect(!allText.isEmpty, "No transcription output from chunked audio")
    }

    // MARK: - End-to-end: AppState + real Transcriber + MockAudioRecorder

    @Test("End-to-end: audio injected via MockAudioRecorder → real transcriber → text output")
    @MainActor
    func endToEnd() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: Model not found")
            return
        }
        guard let wavPath = Self.findTestWAV() else {
            print("SKIP: hello_world.wav not found")
            return
        }

        let samples = try Self.loadWAV(path: wavPath)

        // Real transcriber, mock recorder + inserter
        let transcriber = Transcriber()
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let state = AppState(
            audioRecorder: recorder,
            transcriber: transcriber,
            textInserter: inserter,
            startListening: false
        )
        state.modelFileCheck = { true }
        state.lingerDuration = 1_000_000  // 1ms

        // Initialize transcriber with real model
        let ok = await transcriber.initialize(paths: paths)
        #expect(ok, "Transcriber failed to initialize")
        state.status = .ready

        // Start recording → installs consumer task
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording, got \(state.status)")
            return
        }

        // Wait for consumer task to start (resetVAD runs first)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Feed audio in chunks via the mock recorder's callback
        // (same path as real audio: recorder → continuation → consumer → pipeline)
        let chunkSize = 1360  // ~85ms at 16kHz
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            recorder.lastOnSamples?(chunk)
            // Small delay to simulate real-time pacing and let the consumer process
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        // Stop recording → triggers flush
        state.stopRecording()

        // Wait for transcription to complete
        try await Self.poll {
            if case .ready = state.status { return true }
            return false
        }

        let transcribedText = state.transcribedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("E2E transcription: \"\(transcribedText)\"")
        print("E2E typed texts: \(inserter.typedTexts)")

        #expect(!transcribedText.isEmpty, "End-to-end produced no transcription")
        let lower = transcribedText.lowercased()
        #expect(lower.contains("hello") || lower.contains("world") || lower.contains("test"),
                "Transcription doesn't contain expected words: \"\(transcribedText)\"")
        #expect(!inserter.typedTexts.isEmpty, "TextInserter received no text")
    }

    // MARK: - Pipeline Mode E2E Tests

    /// Shared helper: runs the full E2E pipeline with a given post-processing mode.
    @MainActor
    private static func runPipelineE2E(
        postProcessingMode: PostProcessingMode,
        paths: ModelPaths,
        samples: [Float]
    ) async throws -> (transcribedText: String, typedTexts: [String], typesIncrementally: Bool) {
        let transcriber = Transcriber()
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let state = AppState(
            audioRecorder: recorder,
            transcriber: transcriber,
            textInserter: inserter,
            startListening: false
        )
        state.modelFileCheck = { true }
        state.lingerDuration = 1_000_000  // 1ms

        // Configure pipeline mode
        let mode = AIMode(
            name: "Test-\(postProcessingMode.rawValue)",
            transcriptionMode: .offline,
            postProcessingMode: postProcessingMode
        )
        var settings = AISettings()
        settings.modes = [mode]
        settings.activeModeID = mode.id
        state.aiSettings = settings
        state.rebuildPipeline()

        let typesIncrementally = state.pipelineTypesIncrementally

        // Initialize transcriber
        let ok = await transcriber.initialize(paths: paths)
        #expect(ok, "Transcriber failed to initialize")
        state.status = .ready

        // Start recording
        state.startRecording()
        guard case .recording = state.status else {
            Issue.record("Expected .recording, got \(state.status)")
            return ("", [], typesIncrementally)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        // Feed audio in chunks
        let chunkSize = 1360  // ~85ms at 16kHz
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            recorder.lastOnSamples?(chunk)
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Stop recording → triggers flush
        state.stopRecording()

        // Wait for completion
        try await poll {
            if case .ready = state.status { return true }
            return false
        }

        return (
            transcribedText: state.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines),
            typedTexts: inserter.typedTexts,
            typesIncrementally: typesIncrementally
        )
    }

    @Test("Pipeline mode: none (passthrough, no post-processing)")
    @MainActor
    func pipelineModeNone() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: Model not found"); return
        }
        guard let wavPath = Self.findTestWAV() else {
            print("SKIP: hello_world.wav not found"); return
        }
        let samples = try Self.loadWAV(path: wavPath)

        let result = try await Self.runPipelineE2E(
            postProcessingMode: .none, paths: paths, samples: samples
        )
        print("Pipeline .none: \"\(result.transcribedText)\" typed=\(result.typedTexts)")
        #expect(result.typesIncrementally, "Passthrough mode should type incrementally")
        #expect(!result.transcribedText.isEmpty, "Passthrough mode produced no transcription")
        #expect(!result.typedTexts.isEmpty, "Passthrough mode typed no text")
    }

    @Test("Pipeline mode: regex")
    @MainActor
    func pipelineModeRegex() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: Model not found"); return
        }
        guard let wavPath = Self.findTestWAV() else {
            print("SKIP: hello_world.wav not found"); return
        }
        let samples = try Self.loadWAV(path: wavPath)

        let result = try await Self.runPipelineE2E(
            postProcessingMode: .regex, paths: paths, samples: samples
        )
        print("Pipeline .regex: \"\(result.transcribedText)\" typed=\(result.typedTexts)")
        #expect(result.typesIncrementally, "Regex mode should type incrementally")
        #expect(!result.transcribedText.isEmpty, "Regex mode produced no transcription")
        #expect(!result.typedTexts.isEmpty, "Regex mode typed no text")
    }

    @Test("Pipeline mode: offlineLLM (T5 only)")
    @MainActor
    func pipelineModeOfflineLLM() async throws {
        guard T5ModelManager.isAvailable else {
            print("SKIP: T5 model not downloaded"); return
        }
        guard let paths = Self.findModelPaths() else {
            print("SKIP: Model not found"); return
        }
        guard let wavPath = Self.findTestWAV() else {
            print("SKIP: hello_world.wav not found"); return
        }
        let samples = try Self.loadWAV(path: wavPath)

        let result = try await Self.runPipelineE2E(
            postProcessingMode: .offlineLLM, paths: paths, samples: samples
        )
        print("Pipeline .offlineLLM: \"\(result.transcribedText)\" typed=\(result.typedTexts)")
        #expect(!result.typesIncrementally, "T5 mode should batch until flush")
        #expect(!result.transcribedText.isEmpty, "T5 mode produced no transcription")
        #expect(!result.typedTexts.isEmpty, "T5 mode typed no text")
    }

    @Test("Pipeline mode: regexThenOfflineLLM (Offline + Fixup)")
    @MainActor
    func pipelineModeRegexThenOfflineLLM() async throws {
        guard T5ModelManager.isAvailable else {
            print("SKIP: T5 model not downloaded"); return
        }
        guard let paths = Self.findModelPaths() else {
            print("SKIP: Model not found"); return
        }
        guard let wavPath = Self.findTestWAV() else {
            print("SKIP: hello_world.wav not found"); return
        }
        let samples = try Self.loadWAV(path: wavPath)

        let result = try await Self.runPipelineE2E(
            postProcessingMode: .regexThenOfflineLLM, paths: paths, samples: samples
        )
        print("Pipeline .regexThenOfflineLLM: \"\(result.transcribedText)\" typed=\(result.typedTexts)")
        #expect(!result.typesIncrementally, "Offline+Fixup mode should batch until flush")
        #expect(!result.transcribedText.isEmpty, "Offline+Fixup mode produced no transcription")
        #expect(!result.typedTexts.isEmpty, "Offline+Fixup mode typed no text")
    }

    @Test("End-to-end: segments typed incrementally during recording")
    @MainActor
    func endToEndIncremental() async throws {
        guard let paths = Self.findModelPaths() else {
            print("SKIP: Model not found")
            return
        }
        guard let wavPath = Self.findTestWAV() else {
            print("SKIP: hello_world.wav not found")
            return
        }

        let samples = try Self.loadWAV(path: wavPath)

        let transcriber = Transcriber()
        let recorder = MockAudioRecorder()
        let inserter = MockTextInserter()
        let state = AppState(
            audioRecorder: recorder,
            transcriber: transcriber,
            textInserter: inserter,
            startListening: false
        )
        state.modelFileCheck = { true }
        state.lingerDuration = 1_000_000

        let ok = await transcriber.initialize(paths: paths)
        #expect(ok)
        state.status = .ready
        state.startRecording()

        try await Task.sleep(nanoseconds: 50_000_000)

        // Feed audio in chunks with pauses to trigger VAD segment boundaries
        let chunkSize = 1360
        for start in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            recorder.lastOnSamples?(chunk)
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Add 0.6s of silence to trigger VAD segment boundary
        let silence = [Float](repeating: 0, count: 16000 * 6 / 10)
        for start in stride(from: 0, to: silence.count, by: chunkSize) {
            let end = min(start + chunkSize, silence.count)
            let chunk = Array(silence[start..<end])
            recorder.lastOnSamples?(chunk)
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Wait for VAD to emit a segment
        try await Self.poll { !state.transcribedText.isEmpty }

        let midText = state.transcribedText
        print("E2E incremental mid-recording text: \"\(midText)\"")

        // Text should have been typed incrementally (before stop)
        if !midText.isEmpty {
            #expect(!inserter.typedTexts.isEmpty, "Text should be typed incrementally during recording")
        }

        state.stopRecording()

        try await Self.poll {
            if case .ready = state.status { return true }
            return false
        }

        print("E2E incremental final text: \"\(state.transcribedText)\"")
        #expect(!state.transcribedText.isEmpty, "No transcription after incremental recording")
    }
}
