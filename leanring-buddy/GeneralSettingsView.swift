//
//  GeneralSettingsView.swift
//  leanring-buddy
//
//  General preferences panel: language / locale selection.
//  Presented as a sheet from the globe icon in the companion panel header.
//  Styled to match APISettingsView — dark background, DS design system.
//

import SwiftUI

struct GeneralSettingsView: View {
    var companionManager: CompanionManager?

    @ObservedObject private var localizationManager = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsHeader
                languageSection
                if companionManager != nil {
                    responseTextOverlaySection
                }
            }
            .padding(20)
        }
        .frame(width: 400, height: 300)
        .background(DS.Colors.background)
        .onDisappear {
            // Trigger CosyVoice2 voice ID auto-sync and reload TTS/chat clients
            // so any language-driven voice changes take effect immediately.
            companionManager?.reloadAPIClients()
        }
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack {
            Text("General Settings")
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

    // MARK: - Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Language")

            HStack(spacing: 6) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                    languageButton(for: language)
                }
                Spacer()
            }

            Text("Affects UI text, Claude's response language, and TTS voice (when using a standard CosyVoice2 language variant).")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func languageButton(for language: AppLanguage) -> some View {
        let isActive = localizationManager.currentLanguage == language
        return Button(action: {
            localizationManager.currentLanguage = language
        }) {
            Text(language.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isActive ? DS.Colors.textOnAccent : DS.Colors.accentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isActive ? DS.Colors.accent : DS.Colors.surface1)
                )
                .overlay(
                    Capsule().stroke(
                        isActive ? Color.clear : DS.Colors.borderSubtle,
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Response Text Overlay

    private var responseTextOverlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "Display", locale: appLocale))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Response Text")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Display AI response as floating text near the cursor alongside voice audio.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if let companionManager {
                    Toggle("", isOn: Binding(
                        get: { companionManager.isResponseTextOverlayEnabled },
                        set: { companionManager.setResponseTextOverlayEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
                    .scaleEffect(0.8)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}
