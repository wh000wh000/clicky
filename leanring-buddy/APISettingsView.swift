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
                    .background(Circle().fill(Color.white.opacity(0.08)))
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
            HStack(spacing: 6) {
                ForEach(APIPreset.allPresets, id: \.name) { preset in
                    Button(action: {
                        apiConfiguration.applyPreset(preset)
                        chatAPIKeyLocal = apiConfiguration.chatAPIKey
                    }) {
                        Text(preset.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                Spacer()
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

            configTextField(label: "Base URL", text: $apiConfiguration.ttsAPIBaseURL)
            configTextField(label: "Model", text: $apiConfiguration.ttsAPIModel)
            configTextField(label: "Voice ID", text: $apiConfiguration.ttsAPIVoiceID)
            configSecureField(label: "API Key", text: $ttsAPIKeyLocal)
        }
    }

    // MARK: - STT

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
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if apiConfiguration.sttProvider != .apple {
                configTextField(label: "Base URL", text: $apiConfiguration.sttAPIBaseURL)
                configSecureField(label: "API Key", text: $sttAPIKeyLocal)
            }
        }
    }

    // MARK: - Element Detection

    private var elementDetectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Element Detection")
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
                    .fill(Color.white.opacity(0.06))
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
                        .fill(Color.white.opacity(0.06))
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
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
    }

    // MARK: - Keychain Commit

    private func commitAPIKeysToKeychain() {
        apiConfiguration.chatAPIKey = chatAPIKeyLocal
        apiConfiguration.ttsAPIKey = ttsAPIKeyLocal
        apiConfiguration.sttAPIKey = sttAPIKeyLocal
        apiConfiguration.elementDetectionAPIKey = elementDetectionAPIKeyLocal
    }
}
