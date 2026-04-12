//
//  CursorInputPopupView.swift
//  leanring-buddy
//
//  SwiftUI content for the cursor-following input popup. Shows a row of
//  quick action chips and a text input field. Styled to match the design
//  system (dark surface, subtle border, layered shadow).
//

import SwiftUI

struct CursorInputPopupView: View {
    @ObservedObject var companionManager: CompanionManager
    let dismissAction: () -> Void

    @State private var textQueryInput: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            quickActionChips
            textInputRow
        }
        .padding(12)
        .frame(width: 300)
        .background(popupBackground)
        .onAppear {
            // Auto-focus the text field shortly after appearing so the
            // user can start typing immediately.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }

    // MARK: - Quick Action Chips

    private var quickActionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(companionManager.sceneAwareQuickActionPresets) { preset in
                    Button(action: {
                        dismissAction()
                        companionManager.sendTextQueryToClaudeWithScreenshot(textQuery: preset.promptText)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: preset.iconName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.accentText)
                            Text(preset.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    // MARK: - Text Input

    private var textInputRow: some View {
        HStack(spacing: 8) {
            TextField("Ask anything...", text: $textQueryInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isTextFieldFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(
                            isTextFieldFocused ? DS.Colors.accent.opacity(0.5) : DS.Colors.borderSubtle,
                            lineWidth: 0.5
                        )
                )
                .onSubmit {
                    submitQuery()
                }

            Button(action: { submitQuery() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(
                        textQueryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? DS.Colors.textTertiary
                            : DS.Colors.accent
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(textQueryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Background

    private var popupBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
            .fill(DS.Colors.surface1.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
    }

    // MARK: - Actions

    private func submitQuery() {
        let queryText = textQueryInput
        textQueryInput = ""
        isTextFieldFocused = false
        dismissAction()
        companionManager.sendTextQueryToClaudeWithScreenshot(textQuery: queryText)
    }
}
