//
// TotalSegmentatorHorosPlugin+Utilities.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational

        if let browserWindow = BrowserController.currentBrowser()?.window {
            alert.beginSheetModal(for: browserWindow, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    func logToConsole(_ message: String) {
        NSLog("[TotalSegmentator] %@", message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
