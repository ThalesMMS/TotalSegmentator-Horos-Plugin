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
            presentAlert(title: "TotalSegmentator", message: "Unsupported action selected.")
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
        guard let study = currentDicomStudy() else {
            presentAlert(title: "TotalSegmentator", message: "No active study selected in the browser.")
            return
        }

        let exportDirectory: URL
        do {
            exportDirectory = try exportCompatibleSeries(from: study)
        } catch {
            presentAlert(title: "TotalSegmentator", message: error.localizedDescription)
            return
        }

        guard let outputURL = promptForOutputDirectory() else {
            NSLog("Segmentation cancelled: no output directory selected.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            self.runSegmentation(input: exportDirectory, output: outputURL)
        }
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

    private func currentDicomStudy() -> NSObject? {
        guard let browser = BrowserController.currentBrowser() else {
            NSLog("TotalSegmentatorHorosPlugin could not determine the current browser controller.")
            return nil
        }

        return browser.value(forKey: "selectedStudy") as? NSObject
    }

    private func exportCompatibleSeries(from study: NSObject) throws -> URL {
        enum ExportError: LocalizedError {
            case noSeries
            case noCompatibleSeries
            case exportFailed(underlying: Error)

            var errorDescription: String? {
                switch self {
                case .noSeries:
                    return "The selected study does not contain any series to export."
                case .noCompatibleSeries:
                    return "The selected study does not contain CT or MR series compatible with TotalSegmentator."
                case .exportFailed(let underlying):
                    return "Failed to export DICOM files: \(underlying.localizedDescription)"
                }
            }
        }

        let supportedModalities: Set<String> = ["CT", "MR"]

        let seriesCollection = study.value(forKey: "series")
        let seriesArray: [NSObject]

        if let array = seriesCollection as? [NSObject] {
            seriesArray = array
        } else if let orderedSet = seriesCollection as? NSOrderedSet, let array = orderedSet.array as? [NSObject] {
            seriesArray = array
        } else if let set = seriesCollection as? Set<NSObject> {
            seriesArray = Array(set)
        } else if let nsSet = seriesCollection as? NSSet, let array = nsSet.allObjects as? [NSObject] {
            seriesArray = array
        } else {
            seriesArray = []
        }

        guard !seriesArray.isEmpty else {
            throw ExportError.noSeries
        }

        let compatibleSeries = seriesArray.compactMap { series -> (series: NSObject, modality: String, paths: [String])? in
            guard let modalityValue = series.value(forKey: "modality") as? String else {
                return nil
            }

            let modality = modalityValue.uppercased()

            guard supportedModalities.contains(modality),
                  let paths = series.value(forKey: "paths") as? [String],
                  !paths.isEmpty else {
                return nil
            }

            return (series, modality, paths)
        }

        guard !compatibleSeries.isEmpty else {
            throw ExportError.noCompatibleSeries
        }

        let exportDirectory = try makeExportDirectory()

        var exportedFiles = 0

        do {
            for entry in compatibleSeries {
                let seriesIdentifier = (entry.series.value(forKey: "seriesInstanceUID") as? String)
                    .map { sanitizePathComponent($0) }
                    ?? UUID().uuidString

                let seriesDirectory = exportDirectory.appendingPathComponent(seriesIdentifier, isDirectory: true)
                try FileManager.default.createDirectory(at: seriesDirectory, withIntermediateDirectories: true)

                for path in entry.paths {
                    let sourceURL = URL(fileURLWithPath: path)
                    let destinationURL = seriesDirectory.appendingPathComponent(sourceURL.lastPathComponent)

                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        continue
                    }

                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    exportedFiles += 1
                }
            }
        } catch {
            throw ExportError.exportFailed(underlying: error)
        }

        if exportedFiles == 0 {
            throw ExportError.noCompatibleSeries
        }

        return exportDirectory
    }

    private func makeExportDirectory() throws -> URL {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TotalSegmentator", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let exportDirectory = baseDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        return exportDirectory
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = value.unicodeScalars.reduce(into: "") { partialResult, scalar in
            if allowed.contains(scalar) {
                partialResult.append(Character(scalar))
            } else {
                partialResult.append("_")
            }
        }

        return result.isEmpty ? UUID().uuidString : result
    }
}
