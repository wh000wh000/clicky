//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        // Read from APIConfiguration (runtime user preference) so the user's
        // in-app selection takes effect without an app restart.
        let configuredProvider = APIConfiguration.shared.sttProvider

        switch configuredProvider {
        case .whisperKit:
            let whisperKitProvider = WhisperKitTranscriptionProvider()
            if whisperKitProvider.isConfigured {
                return whisperKitProvider
            }
            // Model not downloaded yet — fall back to Apple Speech silently.
            // The panel UI informs the user about the download requirement.
            print("⚠️ Transcription: WhisperKit selected but not ready, falling back to Apple Speech")
            return AppleSpeechTranscriptionProvider()

        case .apple:
            return AppleSpeechTranscriptionProvider()

        case .assemblyAI:
            let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
            if assemblyAIProvider.isConfigured {
                return assemblyAIProvider
            }
            print("⚠️ Transcription: AssemblyAI preferred but not configured, falling back")
            return AppleSpeechTranscriptionProvider()

        case .openAI:
            let openAIProvider = OpenAIAudioTranscriptionProvider()
            if openAIProvider.isConfigured {
                return openAIProvider
            }
            print("⚠️ Transcription: OpenAI preferred but not configured, falling back")
            return AppleSpeechTranscriptionProvider()
        }
    }
}
