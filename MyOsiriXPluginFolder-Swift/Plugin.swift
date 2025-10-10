import Cocoa

class TotalSegmentatorHorosPlugin: PluginFilter {
    @IBOutlet private weak var settingsWindow: NSWindow!
    @IBOutlet private weak var executablePathField: NSTextField!
    @IBOutlet private weak var taskPopupButton: NSPopUpButton!
    @IBOutlet private weak var devicePopupButton: NSPopUpButton!
    @IBOutlet private weak var fastModeCheckbox: NSButton!
    @IBOutlet private weak var additionalArgumentsField: NSTextField!

    private enum MenuAction: String {
        case showSettings = "TotalSegmentator Settings"
        case runSegmentation = "Run TotalSegmentator"
    }

    private let preferences = SegmentationPreferences()
    private var progressWindowController: SegmentationProgressWindowController?

    private let taskOptions: [(title: String, value: String?)] = [
        (NSLocalizedString("Automatic (default)", comment: "Default task option"), nil),
        ("Total (multi-organ)", "total"),
        ("Total (fast)", "total_fast"),
        ("Lung", "lung"),
        ("Lung (vessels)", "lung_vessels"),
        ("Heart", "heart"),
        ("Head & Neck", "headneck"),
        ("Cerebral Bleed", "cerebral_bleed"),
        ("Femur", "femur"),
        ("Hip", "hip"),
        ("Kidneys", "kidney"),
        ("Liver", "liver"),
        ("Pelvis", "pelvis"),
        ("Prostate", "prostate"),
        ("Spleen", "spleen"),
        ("Spine (vertebrae)", "vertebrae"),
        ("Body (fat & muscles)", "body"),
        ("Brain (structures)", "brain"),
        ("Cardiac (chambers)", "cardiac"),
        ("Coronary Arteries", "coronary_arteries"),
        ("Pancreas", "pancreas")
    ]

    private let deviceOptions: [(title: String, value: String?)] = [
        (NSLocalizedString("Auto", comment: "Automatic device selection"), nil),
        ("cpu", "cpu"),
        ("gpu", "gpu"),
        ("mps", "mps")
    ]

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

        configureSettingsInterfaceIfNeeded()
        populateSettingsUI()

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
        persistPreferencesFromUI()
        settingsWindow?.close()
    }

    @IBAction private func browseForExecutable(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select TotalSegmentator executable"
        panel.prompt = "Choose"

        if let existingPath = executablePathField?.stringValue,
           !existingPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (existingPath as NSString).deletingLastPathComponent)
        }

        if panel.runModal() == .OK, let url = panel.url {
            executablePathField?.stringValue = url.path
        }
    }

    override func initPlugin() {
        let bundle = Bundle(identifier: "com.rossetantoine.OsiriXTestPlugin")
        bundle?.loadNibNamed("Settings", owner: self, topLevelObjects: nil)
        settingsWindow?.delegate = self
        configureSettingsInterfaceIfNeeded()
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
        let currentPreferences = preferences.effectivePreferences()

        guard let executableResolution = resolveExecutable(using: currentPreferences) else {
            DispatchQueue.main.async {
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "Unable to locate the TotalSegmentator executable. Please verify the path in the plugin settings."
                )
            }
            return
        }

        var arguments: [String] = []
        arguments.append(contentsOf: executableResolution.leadingArguments)
        arguments.append(contentsOf: ["-i", input.path, "-o", output.path, "--output_type", "dicom"])

        if let task = currentPreferences.task, !task.isEmpty {
            arguments.append(contentsOf: ["--task", task])
        }

        if currentPreferences.useFast {
            arguments.append("--fast")
        }

        if let device = currentPreferences.device, !device.isEmpty {
            arguments.append(contentsOf: ["--device", device])
        }

        if let additional = currentPreferences.additionalArguments,
           !additional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: tokenize(commandLine: additional))
        }

        let process = Process()
        process.executableURL = executableResolution.executableURL
        process.arguments = arguments

        if let environment = executableResolution.environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutBuffer = Data()
        var stderrBuffer = Data()

        let progressController = makeProgressWindow(for: process)
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self, weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data)
            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                DispatchQueue.main.async {
                    progressController?.append(message)
                    self?.logToConsole(message)
                }
            }
        }

        stderrHandle.readabilityHandler = { [weak self, weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                DispatchQueue.main.async {
                    progressController?.append(message)
                    self?.logToConsole(message)
                }
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            DispatchQueue.main.async {
                progressController.markProcessFinished()
                progressController.close()
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "Failed to start segmentation: \(error.localizedDescription)"
                )
                self.progressWindowController = nil
            }
            return
        }

        process.waitUntilExit()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        stdoutBuffer.append(stdoutHandle.readDataToEndOfFile())
        stderrBuffer.append(stderrHandle.readDataToEndOfFile())

        let combinedErrorOutput = String(data: stderrBuffer, encoding: .utf8) ?? ""
        let combinedStandardOutput = String(data: stdoutBuffer, encoding: .utf8) ?? ""
        let combinedOutput = combinedStandardOutput + combinedErrorOutput

        DispatchQueue.main.async {
            progressController.markProcessFinished()

            if process.terminationStatus == 0 {
                do {
                    try self.validateSegmentationOutput(at: output)
                    progressController.append("Segmentation finished successfully.")
                    progressController.close(after: 0.5)
                    self.presentAlert(
                        title: "TotalSegmentator",
                        message: "Segmentation finished successfully."
                    )
                } catch {
                    progressController.append(error.localizedDescription)
                    progressController.close(after: 0.5)
                    self.presentAlert(
                        title: "TotalSegmentator",
                        message: error.localizedDescription
                    )
                }
            } else {
                let message = self.translateErrorOutput(combinedOutput, status: process.terminationStatus)
                progressController.append(message)
                progressController.close(after: 0.5)
                self.presentAlert(title: "TotalSegmentator", message: message)
            }

            self.progressWindowController = nil
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

    private func configureSettingsInterfaceIfNeeded() {
        guard let taskPopupButton = taskPopupButton,
              taskPopupButton.numberOfItems == 0 else { return }

        taskPopupButton.removeAllItems()
        for option in taskOptions {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.value
            taskPopupButton.menu?.addItem(item)
        }

        if let menu = taskPopupButton.menu, !menu.items.isEmpty {
            taskPopupButton.select(menu.items.first)
        }

        devicePopupButton?.removeAllItems()
        if let deviceMenu = devicePopupButton?.menu {
            for option in deviceOptions {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.value
                deviceMenu.addItem(item)
            }
            devicePopupButton?.select(deviceMenu.items.first)
        }

        additionalArgumentsField?.placeholderString = "--roi_subset liver --statistics"
    }

    private func populateSettingsUI() {
        let current = preferences.effectivePreferences()
        executablePathField?.stringValue = current.executablePath ?? ""
        additionalArgumentsField?.stringValue = current.additionalArguments ?? ""
        fastModeCheckbox?.state = current.useFast ? .on : .off

        if let task = current.task,
           let menuItem = taskPopupButton?.menu?.items.first(where: { ($0.representedObject as? String) == task }) {
            taskPopupButton?.select(menuItem)
        } else {
            taskPopupButton?.selectItem(at: 0)
        }

        if let device = current.device,
           let menuItem = devicePopupButton?.menu?.items.first(where: { ($0.representedObject as? String) == device }) {
            devicePopupButton?.select(menuItem)
        } else {
            devicePopupButton?.selectItem(at: 0)
        }
    }

    private func persistPreferencesFromUI() {
        var updated = preferences.effectivePreferences()
        let executablePath = executablePathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.executablePath = executablePath?.isEmpty == false ? executablePath : nil

        if let selectedTask = taskPopupButton?.selectedItem?.representedObject as? String {
            updated.task = selectedTask
        } else {
            updated.task = nil
        }

        updated.useFast = fastModeCheckbox?.state == .on

        if let selectedDevice = devicePopupButton?.selectedItem?.representedObject as? String {
            updated.device = selectedDevice
        } else {
            updated.device = nil
        }

        let additionalArgs = additionalArgumentsField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.additionalArguments = additionalArgs?.isEmpty == false ? additionalArgs : nil

        preferences.store(updated)
    }

    private func resolveExecutable(using preferences: SegmentationPreferences.State) -> (executableURL: URL, leadingArguments: [String], environment: [String: String]?)? {
        if let explicitPath = preferences.executablePath,
           !explicitPath.isEmpty {
            let trimmed = explicitPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") {
                let url = URL(fileURLWithPath: trimmed)
                guard FileManager.default.isExecutableFile(atPath: url.path) else {
                    return nil
                }
                return (url, [], nil)
            } else {
                return (
                    URL(fileURLWithPath: "/usr/bin/env"),
                    [trimmed],
                    nil
                )
            }
        }

        if let bundled = try? preferences.defaultExecutableURL(),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return (bundled, [], nil)
        }

        return (
            URL(fileURLWithPath: "/usr/bin/env"),
            ["TotalSegmentator"],
            nil
        )
    }

    private func makeProgressWindow(for process: Process) -> SegmentationProgressWindowController {
        let controller: SegmentationProgressWindowController = {
            if Thread.isMainThread {
                return SegmentationProgressWindowController()
            } else {
                return DispatchQueue.main.sync { SegmentationProgressWindowController() }
            }
        }()

        DispatchQueue.main.async {
            controller.showWindow(nil)
            controller.start()
        }

        controller.setCancelHandler { [weak process] in
            process?.terminate()
        }

        progressWindowController = controller
        return controller
    }

    private func tokenize(commandLine: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var isInQuotes = false
        var escapeNext = false
        var quoteCharacter: Character = "\""

        for character in commandLine {
            if escapeNext {
                current.append(character)
                escapeNext = false
                continue
            }

            if character == "\\" {
                escapeNext = true
                continue
            }

            if character == "\"" || character == "'" {
                if isInQuotes {
                    if character == quoteCharacter {
                        isInQuotes = false
                    } else {
                        current.append(character)
                    }
                } else {
                    isInQuotes = true
                    quoteCharacter = character
                }
                continue
            }

            if character.isWhitespace && !isInQuotes {
                if !current.isEmpty {
                    arguments.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            arguments.append(current)
        }

        return arguments
    }

    private func validateSegmentationOutput(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw SegmentationValidationError.outputDirectoryMissing
        }

        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])

        while let element = enumerator?.nextObject() as? URL {
            if let values = try? element.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true {
                return
            }
        }

        throw SegmentationValidationError.outputDirectoryEmpty
    }

    private func translateErrorOutput(_ output: String, status: Int32) -> String {
        let lowercased = output.lowercased()

        if lowercased.contains("no module named") || lowercased.contains("command not found") {
            return "TotalSegmentator could not be executed. Please verify the Python environment and executable path."
        }

        if lowercased.contains("weights") {
            return "The required model weights were not found. Please download them using TotalSegmentator's CLI before running the plugin."
        }

        if lowercased.contains("license") {
            return "A TotalSegmentator license is required for this task. Please configure your license and try again."
        }

        if lowercased.contains("permission denied") {
            return "The configured TotalSegmentator executable is not readable or lacks execution permissions."
        }

        return "Segmentation failed (status \(status)). Please review the TotalSegmentator logs for more details."
    }

    private func logToConsole(_ message: String) {
        NSLog("[TotalSegmentator] %@", message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension TotalSegmentatorHorosPlugin {
    struct SegmentationPreferences {
        struct State {
            var executablePath: String?
            var task: String?
            var useFast: Bool
            var device: String?
            var additionalArguments: String?
        }

        private enum Keys {
            static let executablePath = "TotalSegmentatorExecutablePath"
            static let task = "TotalSegmentatorTask"
            static let fastMode = "TotalSegmentatorFastMode"
            static let device = "TotalSegmentatorDevice"
            static let additionalArguments = "TotalSegmentatorAdditionalArguments"
        }

        private let defaults = UserDefaults.standard

        func effectivePreferences() -> State {
            State(
                executablePath: defaults.string(forKey: Keys.executablePath),
                task: defaults.string(forKey: Keys.task),
                useFast: defaults.bool(forKey: Keys.fastMode),
                device: defaults.string(forKey: Keys.device),
                additionalArguments: defaults.string(forKey: Keys.additionalArguments)
            )
        }

        func store(_ state: State) {
            defaults.setValue(state.executablePath, forKey: Keys.executablePath)
            defaults.setValue(state.task, forKey: Keys.task)
            defaults.setValue(state.useFast, forKey: Keys.fastMode)
            defaults.setValue(state.device, forKey: Keys.device)
            defaults.setValue(state.additionalArguments, forKey: Keys.additionalArguments)
        }

        func defaultExecutableURL() throws -> URL {
            if let pythonHome = ProcessInfo.processInfo.environment["TOTALSEGMENTATOR_HOME"] {
                let url = URL(fileURLWithPath: pythonHome).appendingPathComponent("bin/TotalSegmentator")
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }

            let defaultPaths = [
                "/opt/homebrew/bin/TotalSegmentator",
                "/usr/local/bin/TotalSegmentator",
                "/usr/bin/TotalSegmentator"
            ]

            for path in defaultPaths where FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }

            throw SegmentationValidationError.executableNotFound
        }
    }
}

private enum SegmentationValidationError: LocalizedError {
    case executableNotFound
    case outputDirectoryMissing
    case outputDirectoryEmpty

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Unable to locate the TotalSegmentator executable. Please review the settings."
        case .outputDirectoryMissing:
            return "No output directory was created by TotalSegmentator."
        case .outputDirectoryEmpty:
            return "The TotalSegmentator output directory is empty. Please check the logs for errors."
        }
    }
}

extension TotalSegmentatorHorosPlugin: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == settingsWindow else {
            return
        }

        persistPreferencesFromUI()
    }
}
