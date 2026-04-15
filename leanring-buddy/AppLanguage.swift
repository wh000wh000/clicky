//
//  AppLanguage.swift
//  leanring-buddy
//
//  App language selection. Drives UI locale, Claude response language,
//  NSSpeechSynthesizer voice for error fallbacks, and CosyVoice2 voice ID auto-sync.
//

import Combine
import Foundation

// MARK: - AppLanguage

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"

    /// Native display name shown in the language picker button.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        }
    }

    /// NSSpeechSynthesizer voice identifier for error-fallback audio (screen permission
    /// denied, credits exhausted, API errors). Used when the primary TTS client is unavailable.
    var nsSpeechSynthesizerVoiceIdentifier: String {
        switch self {
        case .english: return "com.apple.speech.synthesis.voice.Alex"
        case .simplifiedChinese: return "com.apple.speech.synthesis.voice.Ting-Ting"
        case .traditionalChinese: return "com.apple.speech.synthesis.voice.Sin-ji"
        case .japanese: return "com.apple.speech.synthesis.voice.Kyoko"
        }
    }

    /// CosyVoice2 language-specific speaker voice ID. Used to auto-sync the TTS voice ID
    /// when the user switches language and is already using a known CosyVoice2 language variant.
    var cosyVoice2VoiceID: String {
        switch self {
        case .english: return "FunAudioLLM/CosyVoice2-0.5B:en"
        case .simplifiedChinese: return "FunAudioLLM/CosyVoice2-0.5B:zh_CN"
        case .traditionalChinese: return "FunAudioLLM/CosyVoice2-0.5B:zh_TW"
        case .japanese: return "FunAudioLLM/CosyVoice2-0.5B:ja_JP"
        }
    }

    /// Instruction appended to the Claude system prompt to enforce the response language.
    /// Written in lowercase to match the casual style of the existing system prompt.
    var claudeResponseLanguageInstruction: String {
        switch self {
        case .english: return "respond in english."
        case .simplifiedChinese: return "用简体中文回复。"
        case .traditionalChinese: return "用繁體中文回覆。"
        case .japanese: return "日本語で返答してください。"
        }
    }
}

// MARK: - App Locale Helper

/// Returns the app's selected locale for `String(localized:locale:)` calls.
/// Reads directly from UserDefaults so it can be called from any isolation
/// context without requiring `@MainActor`. This is necessary because
/// `String(localized:)` defaults to `Locale.current` (the system locale),
/// which does NOT change when the user picks a language in-app. All
/// `String(localized:)` calls must pass `locale: appLocale` for runtime
/// language switching to work correctly.
var appLocale: Locale {
    let rawValue = UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"
    return Locale(identifier: rawValue)
}

// MARK: - LocalizationManager

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let userDefaultsKey = "appLanguage"

    @Published var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: Self.userDefaultsKey)
        }
    }

    /// Locale derived from the current language, injected into SwiftUI views via
    /// `.environment(\.locale, localizationManager.currentLocale)` so all `Text("key")`
    /// calls resolve against the correct Localizable.xcstrings entry without restart.
    var currentLocale: Locale {
        Locale(identifier: currentLanguage.rawValue)
    }

    private init() {
        let savedRawValue = UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? ""
        self.currentLanguage = AppLanguage(rawValue: savedRawValue) ?? .simplifiedChinese
    }
}
