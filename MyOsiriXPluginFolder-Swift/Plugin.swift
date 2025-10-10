import Cocoa

class TotalSegmentatorHorosPlugin: PluginFilter {
    @IBOutlet private weak var settingsWindow: NSWindow!

    private enum MenuAction: String {
        case showSettings = "TotalSegmentator Settings"
        case runSegmentation = "Run TotalSegmentator"
    }

    override func filterImage(_ menuName: String!) -> Int {
        guard let menuName = menuName,
              let action = MenuAction(rawValue: menuName) else {
            NSLog("TotalSegmentatorHorosPlugin received unsupported menu action: %@", menuName ?? "nil")
            return 0
        }

        switch action {
        case .showSettings:
            presentSettingsWindow()
        case .runSegmentation:
            startSegmentationFlow()
        }

        return 0
    }

    private func presentSettingsWindow() {
        guard let window = settingsWindow else {
            NSLog("Settings window has not been loaded. Did initPlugin run?")
            return
        }

        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let browserWindow = BrowserController.currentBrowser()?.window else {
            NSLog("Unable to determine current browser window to display settings sheet.")
            window.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.beginSheet(window, modalFor: browserWindow, modalDelegate: nil, didEnd: nil, contextInfo: nil)
    }

    @IBAction private func closeSettings(_ sender: Any) {
        settingsWindow?.close()
    }

    override func initPlugin() {
        let bundle = Bundle(identifier: "com.rossetantoine.OsiriXTestPlugin")
        bundle?.loadNibNamed("Settings", owner: self, topLevelObjects: nil)
        NSLog("TotalSegmentatorHorosPlugin loaded and ready.")
    }

    private func startSegmentationFlow() {
        guard let inputURL = promptForInputVolume() else {
            NSLog("Segmentation cancelled: no input volume selected.")
            return
        }

        guard let outputURL = promptForOutputDirectory() else {
            NSLog("Segmentation cancelled: no output directory selected.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            self.runSegmentation(input: inputURL, output: outputURL)
        }
    }

    private func promptForInputVolume() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["nii", "nii.gz", "dcm", "dicom"]
        panel.title = "Select input image for TotalSegmentator"

        return panel.runModal() == .OK ? panel.url : nil
    }

    private func promptForOutputDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = "Select output directory for TotalSegmentator"

        return panel.runModal() == .OK ? panel.url : nil
    }

    private func runSegmentation(input: URL, output: URL) {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["TotalSegmentator", "-i", input.path, "-o", output.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.presentAlert(title: "TotalSegmentator", message: "Failed to start segmentation: \(error.localizedDescription)")
            }
            return
        }

        process.waitUntilExit()

        DispatchQueue.main.async {
            if process.terminationStatus == 0 {
                self.presentAlert(title: "TotalSegmentator", message: "Segmentation finished successfully.")
            } else {
                self.presentAlert(title: "TotalSegmentator", message: "Segmentation failed with status \(process.terminationStatus).")
            }
        }
    }

    private func presentAlert(title: String, message: String) {
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
}
