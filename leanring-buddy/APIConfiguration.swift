//
//  APIConfiguration.swift
//  leanring-buddy
//
//  Centralized configuration store for all external API endpoints, models,
//  and API keys. Supports two modes: proxy (Worker holds the keys) and
//  direct (user provides their own key). Non-sensitive settings persist to
//  UserDefaults; API keys persist to macOS Keychain via Security framework.
//

import Combine
import Foundation
import Security

// MARK: - Enums

enum ChatAPIMode: String, CaseIterable {
    case proxy = "proxy"
    case direct = "direct"
}

enum ChatAPIFormat: String, CaseIterable {
    case anthropic = "anthropic"
    case openaiCompatible = "openai_compatible"

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openaiCompatible: return "OpenAI Compatible"
        }
    }
}

enum TTSProvider: String, CaseIterable {
    case elevenLabs = "elevenlabs"
    case openaiCompatible = "openai_compatible"

    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .openaiCompatible: return "OpenAI Compatible"
        }
    }
}

/// Preset model configurations for quick setup.
struct APIPreset {
    let name: String
    let chatBaseURL: String
    let chatFormat: ChatAPIFormat
    let chatModels: [(id: String, displayName: String)]
    let defaultChatModel: String
    let ttsProvider: TTSProvider

    static let siliconFlow = APIPreset(
        name: "SiliconFlow",
        chatBaseURL: "https://api.siliconflow.cn/v1",
        chatFormat: .openaiCompatible,
        chatModels: [
            (id: "Qwen/Qwen3.5-397B-A17B", displayName: "Qwen3.5-397B (MoE)"),
            (id: "Qwen/Qwen3.5-122B-A10B", displayName: "Qwen3.5-122B (MoE)"),
            (id: "Qwen/Qwen3.5-35B-A3B", displayName: "Qwen3.5-35B (MoE)"),
            (id: "Qwen/Qwen3.5-27B", displayName: "Qwen3.5-27B (Dense)"),
            (id: "Kimi-K2.5", displayName: "Kimi K2.5 (1T MoE)"),
        ],
        defaultChatModel: "Qwen/Qwen3.5-397B-A17B",
        ttsProvider: .openaiCompatible
    )

    static let anthropic = APIPreset(
        name: "Anthropic",
        chatBaseURL: "https://api.anthropic.com/v1/messages",
        chatFormat: .anthropic,
        chatModels: [
            (id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
            (id: "claude-opus-4-6", displayName: "Claude Opus 4.6"),
        ],
        defaultChatModel: "claude-sonnet-4-6",
        ttsProvider: .elevenLabs
    )

    static let allPresets: [APIPreset] = [siliconFlow, anthropic]
}

enum STTProvider: String, CaseIterable {
    case whisperKit = "whisperkit"
    case assemblyAI = "assemblyai"
    case openAI = "openai"
    case apple = "apple"

    var displayName: String {
        switch self {
        case .whisperKit: return "WhisperKit (On-Device)"
        case .assemblyAI: return "AssemblyAI"
        case .openAI: return "OpenAI"
        case .apple: return "Apple Speech"
        }
    }
}

// MARK: - API Configuration

@MainActor
final class APIConfiguration: ObservableObject {
    static let shared = APIConfiguration()

    // MARK: - Default Values

    private static let defaultWorkerBaseURL = "https://api.lingyuan.ai"
    private static let defaultChatFormat = ChatAPIFormat.openaiCompatible
    private static let defaultChatModel = "Qwen/Qwen3.5-397B-A17B"
    private static let defaultTTSProvider = TTSProvider.openaiCompatible
    private static let defaultTTSModel = "FunAudioLLM/CosyVoice2-0.5B"
    private static let defaultTTSVoiceID = "FunAudioLLM/CosyVoice2-0.5B:alex"
    private static let defaultSTTProvider = STTProvider.whisperKit
    private static let defaultElementDetectionURL = "https://api.anthropic.com/v1/messages"
    private static let defaultElementDetectionModel = "claude-sonnet-4-6"

    // MARK: - Chat API

    @Published var chatAPIMode: ChatAPIMode {
        didSet { UserDefaults.standard.set(chatAPIMode.rawValue, forKey: "apiConfig.chat.mode") }
    }

    @Published var chatAPIFormat: ChatAPIFormat {
        didSet { UserDefaults.standard.set(chatAPIFormat.rawValue, forKey: "apiConfig.chat.format") }
    }

    @Published var chatAPIBaseURL: String {
        didSet { UserDefaults.standard.set(chatAPIBaseURL, forKey: "apiConfig.chat.baseURL") }
    }

    @Published var chatAPIModel: String {
        didSet { UserDefaults.standard.set(chatAPIModel, forKey: "apiConfig.chat.model") }
    }

    var chatAPIKey: String {
        get { keychainRead(key: "apiConfig.chat.apiKey") ?? "" }
        set {
            if newValue.isEmpty {
                keychainDelete(key: "apiConfig.chat.apiKey")
            } else {
                keychainWrite(key: "apiConfig.chat.apiKey", value: newValue)
            }
        }
    }

    /// The effective chat API format, accounting for mode.
    /// Proxy mode always uses OpenAI-compatible format because the Worker
    /// accepts that format and forwards to SiliconFlow's OpenAI-compatible API.
    var effectiveChatAPIFormat: ChatAPIFormat {
        chatAPIMode == .proxy ? .openaiCompatible : chatAPIFormat
    }

    /// Returns the resolved chat endpoint URL based on the current mode.
    /// In proxy mode, appends "/chat" to the Worker base URL.
    /// In direct mode, returns the base URL as-is (user provides full endpoint).
    var resolvedChatURL: String {
        switch chatAPIMode {
        case .proxy:
            return chatAPIBaseURL + "/chat"
        case .direct:
            return chatAPIBaseURL
        }
    }

    // MARK: - TTS API

    @Published var ttsProvider: TTSProvider {
        didSet { UserDefaults.standard.set(ttsProvider.rawValue, forKey: "apiConfig.tts.provider") }
    }

    @Published var ttsAPIBaseURL: String {
        didSet { UserDefaults.standard.set(ttsAPIBaseURL, forKey: "apiConfig.tts.baseURL") }
    }

    @Published var ttsAPIModel: String {
        didSet { UserDefaults.standard.set(ttsAPIModel, forKey: "apiConfig.tts.model") }
    }

    @Published var ttsAPIVoiceID: String {
        didSet { UserDefaults.standard.set(ttsAPIVoiceID, forKey: "apiConfig.tts.voiceID") }
    }

    var ttsAPIKey: String {
        get { keychainRead(key: "apiConfig.tts.apiKey") ?? "" }
        set {
            if newValue.isEmpty {
                keychainDelete(key: "apiConfig.tts.apiKey")
            } else {
                keychainWrite(key: "apiConfig.tts.apiKey", value: newValue)
            }
        }
    }

    /// Resolved TTS endpoint. In proxy mode, appends "/tts" to the Worker URL.
    var resolvedTTSURL: String {
        if chatAPIMode == .proxy && ttsAPIBaseURL == chatAPIBaseURL {
            return ttsAPIBaseURL + "/tts"
        }
        return ttsAPIBaseURL
    }

    // MARK: - STT API

    @Published var sttProvider: STTProvider {
        didSet { UserDefaults.standard.set(sttProvider.rawValue, forKey: "apiConfig.stt.provider") }
    }

    @Published var sttAPIBaseURL: String {
        didSet { UserDefaults.standard.set(sttAPIBaseURL, forKey: "apiConfig.stt.baseURL") }
    }

    var sttAPIKey: String {
        get { keychainRead(key: "apiConfig.stt.apiKey") ?? "" }
        set {
            if newValue.isEmpty {
                keychainDelete(key: "apiConfig.stt.apiKey")
            } else {
                keychainWrite(key: "apiConfig.stt.apiKey", value: newValue)
            }
        }
    }

    /// Resolved STT token endpoint for AssemblyAI proxy mode.
    var resolvedSTTTokenURL: String {
        if chatAPIMode == .proxy && sttAPIBaseURL == chatAPIBaseURL {
            return sttAPIBaseURL + "/transcribe-token"
        }
        return sttAPIBaseURL
    }

    // MARK: - Element Detection API

    @Published var elementDetectionBaseURL: String {
        didSet { UserDefaults.standard.set(elementDetectionBaseURL, forKey: "apiConfig.elementDetection.baseURL") }
    }

    @Published var elementDetectionModel: String {
        didSet { UserDefaults.standard.set(elementDetectionModel, forKey: "apiConfig.elementDetection.model") }
    }

    var elementDetectionAPIKey: String {
        get { keychainRead(key: "apiConfig.elementDetection.apiKey") ?? "" }
        set {
            if newValue.isEmpty {
                keychainDelete(key: "apiConfig.elementDetection.apiKey")
            } else {
                keychainWrite(key: "apiConfig.elementDetection.apiKey", value: newValue)
            }
        }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        self.chatAPIMode = ChatAPIMode(rawValue: defaults.string(forKey: "apiConfig.chat.mode") ?? "") ?? .proxy
        self.chatAPIFormat = ChatAPIFormat(rawValue: defaults.string(forKey: "apiConfig.chat.format") ?? "") ?? Self.defaultChatFormat
        self.chatAPIBaseURL = defaults.string(forKey: "apiConfig.chat.baseURL") ?? Self.defaultWorkerBaseURL
        self.chatAPIModel = defaults.string(forKey: "apiConfig.chat.model") ?? Self.defaultChatModel

        self.ttsProvider = TTSProvider(rawValue: defaults.string(forKey: "apiConfig.tts.provider") ?? "") ?? Self.defaultTTSProvider
        self.ttsAPIBaseURL = defaults.string(forKey: "apiConfig.tts.baseURL") ?? Self.defaultWorkerBaseURL
        self.ttsAPIModel = defaults.string(forKey: "apiConfig.tts.model") ?? Self.defaultTTSModel
        self.ttsAPIVoiceID = defaults.string(forKey: "apiConfig.tts.voiceID") ?? Self.defaultTTSVoiceID

        self.sttProvider = STTProvider(rawValue: defaults.string(forKey: "apiConfig.stt.provider") ?? "") ?? Self.defaultSTTProvider
        self.sttAPIBaseURL = defaults.string(forKey: "apiConfig.stt.baseURL") ?? Self.defaultWorkerBaseURL

        self.elementDetectionBaseURL = defaults.string(forKey: "apiConfig.elementDetection.baseURL") ?? Self.defaultElementDetectionURL
        self.elementDetectionModel = defaults.string(forKey: "apiConfig.elementDetection.model") ?? Self.defaultElementDetectionModel
    }

    // MARK: - Reset

    /// Resets all API configuration to factory defaults. Clears API keys from Keychain.
    func resetToDefaults() {
        chatAPIMode = .proxy
        chatAPIFormat = Self.defaultChatFormat
        chatAPIBaseURL = Self.defaultWorkerBaseURL
        chatAPIModel = Self.defaultChatModel
        chatAPIKey = ""

        ttsProvider = Self.defaultTTSProvider
        ttsAPIBaseURL = Self.defaultWorkerBaseURL
        ttsAPIModel = Self.defaultTTSModel
        ttsAPIVoiceID = Self.defaultTTSVoiceID
        ttsAPIKey = ""

        sttProvider = Self.defaultSTTProvider
        sttAPIBaseURL = Self.defaultWorkerBaseURL
        sttAPIKey = ""

        elementDetectionBaseURL = Self.defaultElementDetectionURL
        elementDetectionModel = Self.defaultElementDetectionModel
        elementDetectionAPIKey = ""
    }

    /// Applies a preset configuration (e.g., SiliconFlow or Anthropic).
    func applyPreset(_ preset: APIPreset) {
        chatAPIMode = .direct
        chatAPIFormat = preset.chatFormat
        chatAPIBaseURL = preset.chatBaseURL
        chatAPIModel = preset.defaultChatModel
        ttsProvider = preset.ttsProvider
        if preset.ttsProvider == .openaiCompatible {
            ttsAPIBaseURL = preset.chatBaseURL
            ttsAPIModel = "CosyVoice2-0.5B"
        }
        sttAPIBaseURL = preset.chatBaseURL
    }

    // MARK: - Keychain Helpers

    private let keychainServiceName = "com.clicky.api-configuration"

    private func keychainRead(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete existing item first to avoid duplicate errors
        keychainDelete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
