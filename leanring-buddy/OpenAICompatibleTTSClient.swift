//
//  OpenAICompatibleTTSClient.swift
//  leanring-buddy
//
//  TTS client for OpenAI-compatible endpoints (SiliconFlow CosyVoice2, etc.).
//  Uses the standard /v1/audio/speech format. Drop-in replacement for
//  ElevenLabsTTSClient — same method signatures.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAICompatibleTTSClient {
    private let apiURL: URL
    private let apiKey: String
    private let modelID: String
    private let voice: String
    private let session: URLSession

    /// The audio player for the current TTS playback.
    private var audioPlayer: AVAudioPlayer?

    init(baseURL: String, apiKey: String, model: String = "CosyVoice2-0.5B", voice: String = "alloy") {
        let cleanedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if baseURL.hasSuffix("/audio/speech") {
            self.apiURL = URL(string: baseURL)!
        } else {
            self.apiURL = URL(string: "\(cleanedBaseURL)/audio/speech")!
        }
        self.apiKey = apiKey
        self.modelID = model
        self.voice = voice

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to the TTS endpoint and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": modelID,
            "input": text,
            "voice": voice
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAICompatibleTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAICompatibleTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 OpenAI-compatible TTS: playing \(data.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
