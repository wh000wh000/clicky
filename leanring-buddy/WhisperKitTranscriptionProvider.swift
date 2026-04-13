//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  On-device transcription provider backed by WhisperKit (Apple Neural Engine).
//  Buffers all audio from the push-to-talk session and transcribes in one pass
//  on key release. Falls back gracefully when the model is not yet downloaded.
//

import AVFoundation
import Foundation
import WhisperKit

// MARK: - Provider

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {

    let displayName = "WhisperKit (On-Device)"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        WhisperKitModelManager.shared.isReady
    }

    var unavailableExplanation: String? {
        switch WhisperKitModelManager.shared.modelState {
        case .notDownloaded:
            return "Voice model not downloaded. Download it from the main panel."
        case .downloading:
            return "Voice model is downloading. Please wait."
        case .failed(let message):
            return "Voice model failed to load: \(message)"
        case .ready:
            return nil
        }
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let whisperKit = WhisperKitModelManager.shared.whisperKit else {
            throw WhisperKitProviderError(
                message: "WhisperKit model is not loaded. Download and load the model first."
            )
        }

        return WhisperKitTranscriptionSession(
            whisperKit: whisperKit,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

// MARK: - Error

private struct WhisperKitProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Session

/// Buffers all incoming audio during the push-to-talk session and runs
/// WhisperKit transcription in one pass when `requestFinalTranscript()`
/// is called (i.e. when the user releases the PTT key).
private final class WhisperKitTranscriptionSession: BuddyStreamingTranscriptionSession {

    /// WhisperKit processes the full buffer locally so the fallback delay
    /// only needs to cover local inference time.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 5.0

    private let whisperKit: WhisperKit
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    /// Raw float audio samples accumulated during the recording session.
    private var accumulatedSamples: [Float] = []
    private var inputSampleRate: Double = 16000
    private var hasRequestedFinalTranscript = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        whisperKit: WhisperKit,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.whisperKit = whisperKit
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !hasRequestedFinalTranscript else { return }
        guard let channelData = audioBuffer.floatChannelData else { return }

        // Record the sample rate from the first buffer so we can resample later
        // if needed. AVAudioEngine typically delivers at the hardware rate (44.1/48 kHz).
        inputSampleRate = audioBuffer.format.sampleRate

        let frameCount = Int(audioBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        accumulatedSamples.append(contentsOf: samples)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript else { return }
        hasRequestedFinalTranscript = true

        transcriptionTask = Task {
            do {
                guard !accumulatedSamples.isEmpty else {
                    onFinalTranscriptReady("")
                    return
                }

                // Resample to 16 kHz mono if the input was at a different rate.
                // WhisperKit expects 16 kHz float audio.
                let targetSampleRate: Double = 16000
                let audioSamples: [Float]
                if abs(inputSampleRate - targetSampleRate) > 1 {
                    audioSamples = resampleAudio(
                        accumulatedSamples,
                        fromRate: inputSampleRate,
                        toRate: targetSampleRate
                    )
                } else {
                    audioSamples = accumulatedSamples
                }

                let results = try await whisperKit.transcribe(audioArray: audioSamples)
                let transcriptText = results.map { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                onTranscriptUpdate(transcriptText)
                onFinalTranscriptReady(transcriptText)

                let durationSeconds = Double(accumulatedSamples.count) / inputSampleRate
                print("🎙️ WhisperKit: transcribed \(String(format: "%.1f", durationSeconds))s audio → \(transcriptText.count) chars")
            } catch {
                onError(error)
            }
        }
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        accumulatedSamples.removeAll()
    }

    // MARK: - Resampling

    /// Simple linear interpolation resampler. Converts float audio from one
    /// sample rate to another. Good enough for speech — no need for a
    /// high-quality sinc filter here.
    private func resampleAudio(
        _ samples: [Float],
        fromRate: Double,
        toRate: Double
    ) -> [Float] {
        let ratio = fromRate / toRate
        let outputLength = Int(Double(samples.count) / ratio)
        var output = [Float](repeating: 0, count: outputLength)
        for i in 0..<outputLength {
            let sourceIndex = Double(i) * ratio
            let indexFloor = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(indexFloor))
            let sample0 = samples[min(indexFloor, samples.count - 1)]
            let sample1 = samples[min(indexFloor + 1, samples.count - 1)]
            output[i] = sample0 + fraction * (sample1 - sample0)
        }
        return output
    }
}
