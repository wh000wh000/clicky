//
//  CursorInputPopupManager.swift
//  leanring-buddy
//
//  Interactive floating panel that appears near the mouse cursor when
//  the user presses the text input shortcut (Cmd+Shift+Space). Unlike
//  CompanionResponseOverlayManager, this panel accepts mouse and keyboard
//  input so the user can type a query or tap a quick action.
//
//  The panel anchors at the cursor position when shown and does NOT follow
//  the cursor while the user interacts — same behavior as Spotlight/Alfred.
//

import AppKit
import SwiftUI

// MARK: - Interactive Panel (canBecomeKey for text field focus)

private class InputPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Popup Manager

@MainActor
final class CursorInputPopupManager {
    private weak var companionManager: CompanionManager?
    private var popupPanel: InputPopupPanel?
    private var clickOutsideMonitor: Any?
    private var escapeKeyMonitor: Any?

    /// The popup width — slightly narrower than the menu bar panel (320px)
    /// to feel lighter and more transient.
    private let popupWidth: CGFloat = 300

    /// Offset from cursor to avoid obscuring the pointer.
    private let cursorOffsetX: CGFloat = 20
    private let cursorOffsetY: CGFloat = 10

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    var isPopupVisible: Bool {
        popupPanel?.isVisible ?? false
    }

    func showPopupAtCursor() {
        // If already visible, dismiss and re-show at new cursor position
        if isPopupVisible {
            dismissPopup()
        }

        guard let companionManager else { return }

        // Refresh presets based on the frontmost app before showing the popup
        companionManager.refreshSceneAwarePresets()

        let popupView = CursorInputPopupView(
            companionManager: companionManager,
            dismissAction: { [weak self] in
                self?.dismissPopup()
            }
        )
        // Inject the app's current locale so Text("key") calls resolve to the
        // correct Localizable.xcstrings entry (same as CompanionPanelView).
        .environment(\.locale, LocalizationManager.shared.currentLocale)

        let hostingView = NSHostingView(rootView: popupView)
        let fittingSize = hostingView.fittingSize
        let panelWidth = min(fittingSize.width, popupWidth)
        let panelHeight = fittingSize.height

        let initialFrame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = InputPopupPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false  // Interactive — key difference from response overlay

        hostingView.frame = initialFrame
        panel.contentView = hostingView

        positionPanelNearCursor(panel: panel, panelSize: CGSize(width: panelWidth, height: panelHeight))

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        popupPanel = panel

        installClickOutsideMonitor()
        installEscapeKeyMonitor()
    }

    func dismissPopup() {
        removeClickOutsideMonitor()
        removeEscapeKeyMonitor()
        popupPanel?.orderOut(nil)
        popupPanel = nil
    }

    // MARK: - Positioning

    /// Positions the panel near the mouse cursor, clamping to screen edges.
    /// Same edge-clamping logic as CompanionResponseOverlayManager.repositionPanelNearCursor.
    private func positionPanelNearCursor(panel: NSPanel, panelSize: CGSize) {
        let mouseLocation = NSEvent.mouseLocation

        // Default: to the right and below the cursor (AppKit coords: Y increases upward)
        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        if let currentScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            let visibleFrame = currentScreen.visibleFrame

            // Flip to left of cursor if it would overflow the right edge
            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }

            // Push above cursor if it would overflow the bottom edge
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            // Final clamp to visible frame
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        panel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }

    // MARK: - Dismissal Monitors

    /// Dismisses the popup when the user clicks outside it.
    /// Same pattern as MenuBarPanelManager.installClickOutsideMonitor.
    private func installClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.popupPanel else { return }
            let clickLocation = NSEvent.mouseLocation
            if !panel.frame.contains(clickLocation) {
                Task { @MainActor in
                    self.dismissPopup()
                }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// Dismisses the popup when the user presses Escape.
    private func installEscapeKeyMonitor() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape key
                Task { @MainActor in
                    self?.dismissPopup()
                }
                return nil // Consume the event
            }
            return event
        }
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }
}
