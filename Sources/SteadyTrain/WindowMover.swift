import AppKit
import ApplicationServices

/// Moves another app's window through the Accessibility API.
/// Only touch this from one queue (the camera queue).
final class WindowMover {
    private var window: AXUIElement?
    private var anchor = CGPoint.zero        // where the window "lives" when there's no shake
    private var lastSet: CGPoint?            // last position we wrote
    private var lastOffset = CGPoint.zero
    private var framesSinceCheck = 0

    var isLocked: Bool { window != nil }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Grabs the focused window of the given app.
    func lock(pid: pid_t) -> Bool {
        release()

        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }

        let win = value as! AXUIElement
        AXUIElementSetMessagingTimeout(win, 0.05)   // a slow app must not stall the camera loop
        window = win

        guard let pos = readPosition() else { window = nil; return false }
        anchor = pos
        lastSet = pos
        lastOffset = .zero
        framesSinceCheck = 0
        return true
    }

    /// Puts the window back where it was and lets go.
    func release() {
        if window != nil, let lastSet, lastSet != anchor {
            write(anchor)
        }
        window = nil
        lastSet = nil
    }

    /// Places the window at its home position plus `offset` (screen points, y down).
    func setOffset(_ offset: CGPoint) {
        guard window != nil else { return }

        // Every ~half second, check whether you dragged the window somewhere new.
        // If so, that becomes its new home instead of fighting you.
        framesSinceCheck += 1
        if framesSinceCheck >= 15 {
            framesSinceCheck = 0
            if let current = readPosition(), let last = lastSet,
               hypot(current.x - last.x, current.y - last.y) > 4 {
                anchor = CGPoint(x: current.x - lastOffset.x, y: current.y - lastOffset.y)
                lastSet = current
            }
        }

        let target = CGPoint(x: (anchor.x + offset.x).rounded(),
                             y: (anchor.y + offset.y).rounded())
        guard target != lastSet else { return }

        if write(target) {
            lastSet = target
            lastOffset = CGPoint(x: target.x - anchor.x, y: target.y - anchor.y)
        }
    }

    // MARK: - AX helpers

    private func readPosition() -> CGPoint? {
        guard let window else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    @discardableResult
    private func write(_ point: CGPoint) -> Bool {
        guard let window else { return false }
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        if result == .invalidUIElement { self.window = nil }   // window was closed
        return result == .success
    }
}
