//
//  APISettingsView.swift
//  leanring-buddy
//
//  Settings UI for configuring API endpoints, models, and API keys.
//  Accessible from the gear icon in the menu bar panel header.
//  Styled with the DS design system to match the panel aesthetic.
//

import SwiftUI

struct APISettingsView: View {
    @ObservedObject var apiConfiguration: APIConfiguration
    var companionManager: CompanionManager?
    @Environment(\.dismiss) private var dismiss

    // Local state for API key fields — committed to Keychain on disappear
    // to avoid writing to Keychain on every keystroke.
    @State private var chatAPIKeyLocal: String = ""
    @State private var ttsAPIKeyLocal: String = ""
    @State private var sttAPIKeyLocal: String = ""
    @State private var elementDetectionAPIKeyLocal: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsHeader
                chatAPISection
                Divider().background(DS.Colors.borderSubtle)
                ttsSection
                Divider().background(DS.Colors.borderSubtle)
                sttSection
                Divider().background(DS.Colors.borderSubtle)
                elementDetectionSection
                Divider().background(DS.Colors.borderSubtle)
                resetButton
                resetOnboardingButton
            }
            .padding(20)
        }
        .frame(width: 400, height: 520)
        .background(DS.Colors.background)
        .onAppear {
            chatAPIKeyLocal = apiConfiguration.chatAPIKey
            ttsAPIKeyLocal = apiConfiguration.ttsAPIKey
            sttAPIKeyLocal = apiConfiguration.sttAPIKey
            elementDetectionAPIKeyLocal = apiConfiguration.elementDetectionAPIKey
        }
        .onDisappear {
            commitAPIKeysToKeychain()
        }
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack {
            Text("API Settings")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(DS.Colors.surface2))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Chat API

    private var chatAPISection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Chat / Vision API")

            // Preset buttons
            VStack(alignment: .leading, spacing: 6) {
                // Warn the user when currently in proxy mode — picking a preset
                // switches to Direct mode and requires filling in an API key.
                if apiConfiguration.chatAPIMode == .proxy {
                    Text("选择预设将切换到 Direct 模式（需填写 API Key）")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.warning)
                }

                HStack(spacing: 6) {
                    ForEach(APIPreset.allPresets, id: \.name) { preset in
                        let isActivePreset = apiConfiguration.activePresetName == preset.name
                        Button(action: {
                            // Commit any in-progress key edits before applying the preset,
                            // so the user's typed keys are not silently discarded.
                            commitAPIKeysToKeychain()
                            apiConfiguration.applyPreset(preset)
                            // Reload all four key locals to stay in sync with Keychain.
                            reloadLocalKeysFromKeychain()
                        }) {
                            Text(preset.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(isActivePreset ? DS.Colors.textOnAccent : DS.Colors.accentText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(isActivePreset ? DS.Colors.accent : DS.Colors.surface1)
                                )
                                .overlay(
                                    Capsule().stroke(
                                        isActivePreset ? Color.clear : DS.Colors.borderSubtle,
                                        lineWidth: 0.5
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                    Spacer()
                }
            }

            // Mode picker: Proxy vs Direct
            HStack(spacing: 8) {
                Text("Mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: $apiConfiguration.chatAPIMode) {
                    Text("Proxy").tag(ChatAPIMode.proxy)
                    Text("Direct").tag(ChatAPIMode.direct)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            // Format picker: Anthropic vs OpenAI Compatible
            if apiConfiguration.chatAPIMode == .direct {
                HStack(spacing: 8) {
                    Text("Format")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Picker("", selection: $apiConfiguration.chatAPIFormat) {
                        ForEach(ChatAPIFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }

            configTextField(label: "Base URL", text: $apiConfiguration.chatAPIBaseURL)
            configTextField(label: "Model", text: $apiConfiguration.chatAPIModel)

            if apiConfiguration.chatAPIMode == .direct {
                configSecureField(label: "API Key", text: $chatAPIKeyLocal)
            }
        }
    }

    // MARK: - TTS

    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Text-to-Speech (TTS)")

            HStack(spacing: 8) {
                Text("Provider")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: $apiConfiguration.ttsProvider) {
                    ForEach(TTSProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // In proxy mode the Worker manages TTS credentials — hide the
            // configuration fields so the user isn't confused by irrelevant inputs.
            if apiConfiguration.chatAPIMode == .proxy {
                managedByProxyNote
            } else {
                configTextField(label: "Base URL", text: $apiConfiguration.ttsAPIBaseURL)
                configTextField(label: "Model", text: $apiConfiguration.ttsAPIModel)
                configTextField(label: "Voice ID", text: $apiConfiguration.ttsAPIVoiceID)
                configSecureField(label: "API Key", text: $ttsAPIKeyLocal)
            }
        }
    }

    // MARK: - STT

    @ObservedObject private var whisperKitManager = WhisperKitModelManager.shared

    private var sttSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Speech-to-Text (STT)")

            HStack(spacing: 8) {
                Text("Provider")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Picker("", selection: $apiConfiguration.sttProvider) {
                    ForEach(STTProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            if apiConfiguration.sttProvider == .whisperKit {
                whisperKitStatusBlock
            } else if apiConfiguration.sttProvider == .apple {
                // Apple Speech runs on-device — no URL or key needed.
                EmptyView()
            } else if apiConfiguration.chatAPIMode == .proxy {
                // In proxy mode the Worker fetches STT tokens server-side —
                // hide the fields so the user isn't prompted for credentials.
                managedByProxyNote
            } else {
                configTextField(label: "Base URL", text: $apiConfiguration.sttAPIBaseURL)
                configSecureField(label: "API Key", text: $sttAPIKeyLocal)
            }
        }
    }

    private var whisperKitStatusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-Device Voice Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Model: \(WhisperKitModelManager.modelVariant)  ·  \(WhisperKitModelManager.approximateModelSizeDescription), one-time download")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
            }

            switch whisperKitManager.modelState {
            case .notDownloaded:
                Button(action: { WhisperKitModelManager.shared.startDownload() }) {
                    Text("Download Model")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

            case .downloading(let progress):
                VStack(spacing: 6) {
                    HStack {
                        Text("Downloading…")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(DS.Colors.accent)
                    Button(action: { WhisperKitModelManager.shared.cancelDownload() }) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

            case .ready:
                HStack(spacing: 6) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 7, height: 7)
                    Text("Model ready — on-device transcription active")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.success)
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Download failed: \(message)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: { WhisperKitModelManager.shared.startDownload() }) {
                        Text("Retry Download")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(DS.Colors.surface1)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .animation(.easeInOut(duration: DS.Animation.normal), value: whisperKitManager.modelState)
    }

    // MARK: - Element Detection

    private var elementDetectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Element Detection")

            Text("Pinpoints UI element coordinates more precisely than Claude's built-in estimate. Leave API Key blank to disable.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Quick-fill presets for known element detection providers
            HStack(spacing: 6) {
                let isUITARSActive = apiConfiguration.elementDetectionModel.lowercased().contains("ui-tars")
                let isClaudeActive = apiConfiguration.elementDetectionModel.lowercased().contains("claude")

                Button(action: {
                    apiConfiguration.elementDetectionBaseURL = "https://openrouter.ai/api/v1"
                    apiConfiguration.elementDetectionModel = "bytedance/ui-tars-1.5-7b"
                }) {
                    Text("UI-TARS (OpenRouter)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isUITARSActive ? DS.Colors.textOnAccent : DS.Colors.accentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(isUITARSActive ? DS.Colors.accent : DS.Colors.surface1))
                        .overlay(Capsule().stroke(isUITARSActive ? Color.clear : DS.Colors.borderSubtle, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: {
                    apiConfiguration.elementDetectionBaseURL = "https://api.anthropic.com/v1/messages"
                    apiConfiguration.elementDetectionModel = "claude-sonnet-4-6"
                }) {
                    Text("Claude Computer Use")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isClaudeActive ? DS.Colors.textOnAccent : DS.Colors.accentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(isClaudeActive ? DS.Colors.accent : DS.Colors.surface1))
                        .overlay(Capsule().stroke(isClaudeActive ? Color.clear : DS.Colors.borderSubtle, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Spacer()
            }

            configTextField(label: "Base URL", text: $apiConfiguration.elementDetectionBaseURL)
            configTextField(label: "Model", text: $apiConfiguration.elementDetectionModel)
            configSecureField(label: "API Key", text: $elementDetectionAPIKeyLocal)
        }
    }

    // MARK: - Reset

    private var resetButton: some View {
        Button(action: {
            apiConfiguration.resetToDefaults()
            chatAPIKeyLocal = ""
            ttsAPIKeyLocal = ""
            sttAPIKeyLocal = ""
            elementDetectionAPIKeyLocal = ""
        }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                Text("Reset to Defaults")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Reset Onboarding

    private var resetOnboardingButton: some View {
        Button(action: {
            companionManager?.resetOnboarding()
            dismiss()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
                Text("Reset Onboarding")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Reusable Components

    /// Shown in TTS/STT sections when in proxy mode — the Worker holds the
    /// credentials, so the user does not need to fill in any keys or URLs.
    private var managedByProxyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.success)
            Text("由代理服务管理，无需填写")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.top, 2)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func configTextField(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 70, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
    }

    private func configSecureField(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 70, alignment: .trailing)
            SecureField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            // Status dot: green when a key is present, dim grey when empty.
            // Reflects the local @State value so it updates as the user types.
            Circle()
                .fill(text.wrappedValue.isEmpty
                      ? DS.Colors.textTertiary.opacity(0.35)
                      : DS.Colors.success)
                .frame(width: 7, height: 7)
        }
    }

    // MARK: - Keychain Commit / Reload

    private func commitAPIKeysToKeychain() {
        apiConfiguration.chatAPIKey = chatAPIKeyLocal
        apiConfiguration.ttsAPIKey = ttsAPIKeyLocal
        apiConfiguration.sttAPIKey = sttAPIKeyLocal
        apiConfiguration.elementDetectionAPIKey = elementDetectionAPIKeyLocal
    }

    /// Re-reads all four API keys from Keychain into the local @State variables.
    /// Call this after applying a preset or any operation that may change Keychain state,
    /// so the UI fields stay in sync with what's actually stored.
    private func reloadLocalKeysFromKeychain() {
        chatAPIKeyLocal = apiConfiguration.chatAPIKey
        ttsAPIKeyLocal = apiConfiguration.ttsAPIKey
        sttAPIKeyLocal = apiConfiguration.sttAPIKey
        elementDetectionAPIKeyLocal = apiConfiguration.elementDetectionAPIKey
    }
}
