import Cocoa
import CoreData

private typealias ExecutableResolution = (executableURL: URL, leadingArguments: [String], environment: [String: String]?)

private enum SegmentationOutputType: Equatable {
    case dicom
    case nifti
    case other(String?)

    init(argumentValue: String?) {
        guard let normalized = argumentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else {
            self = .dicom
            return
        }

        switch normalized {
        case "dicom":
            self = .dicom
        case "nifti", "nifti_gz", "nii", "nii.gz":
            self = .nifti
        default:
            self = .other(argumentValue)
        }
    }

    var description: String {
        switch self {
        case .dicom:
            return "dicom"
        case .nifti:
            return "nifti"
        case .other(let value):
            return value ?? "unknown"
        }
    }
}

private struct ExportedSeries {
    let managedObject: NSManagedObject
    let modality: String
    let exportedDirectory: URL
    let exportedFiles: [URL]
    let seriesInstanceUID: String?
    let studyInstanceUID: String?
}

private struct ExportResult {
    let directory: URL
    let series: [ExportedSeries]
}

private struct SegmentationImportResult {
    let addedFilePaths: [String]
    let rtStructPaths: [String]
    let importedObjectIDs: [NSManagedObjectID]
    let outputType: SegmentationOutputType
}

private enum SegmentationPostProcessingError: LocalizedError {
    case browserUnavailable
    case databaseUnavailable
    case noImportableResults
    case unsupportedOutputType(String?)

    var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            return "The Horos browser window is not available."
        case .databaseUnavailable:
            return "The Horos database is not available."
        case .noImportableResults:
            return "No segmentation outputs could be imported into Horos."
        case .unsupportedOutputType(let value):
            if let value = value, !value.isEmpty {
                return "The segmentation output type '\(value)' is not supported by the plugin."
            }
            return "The segmentation output type is not supported by the plugin."
        }
    }
}

private struct SegmentationAuditEntry: Codable {
    struct SeriesInfo: Codable {
        let seriesInstanceUID: String?
        let studyInstanceUID: String?
        let modality: String
        let exportedFileCount: Int
    }

    let timestamp: Date
    let outputDirectory: String
    let outputType: String
    let importedFileCount: Int
    let rtStructCount: Int
    let task: String?
    let device: String?
    let useFast: Bool
    let additionalArguments: String?
    let modelVersion: String?
    let series: [SeriesInfo]
}

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
    private let auditQueue = DispatchQueue(label: "org.totalsegmentator.horos.audit", qos: .utility)

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
        let bundle = Bundle(identifier: "com.totalsegmentator.horosplugin")
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

        let exportResult: ExportResult
        do {
            exportResult = try exportCompatibleSeries(from: study)
        } catch {
            presentAlert(title: "TotalSegmentator", message: error.localizedDescription)
            return
        }

        guard let outputURL = promptForOutputDirectory() else {
            NSLog("Segmentation cancelled: no output directory selected.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            self.runSegmentation(exportResult: exportResult, output: outputURL)
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

    private func runSegmentation(exportResult: ExportResult, output: URL) {
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

        let additionalTokens: [String]
        if let additional = currentPreferences.additionalArguments,
           !additional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            additionalTokens = tokenize(commandLine: additional)
        } else {
            additionalTokens = []
        }

        let outputDetection = detectOutputType(from: additionalTokens)
        let effectiveOutputType = outputDetection.explicit ? outputDetection.type : .dicom

        var arguments: [String] = []
        arguments.append(contentsOf: executableResolution.leadingArguments)
        arguments.append(contentsOf: ["-i", exportResult.directory.path, "-o", output.path])

        if !outputDetection.explicit {
            arguments.append(contentsOf: ["--output_type", SegmentationOutputType.dicom.description])
        }

        if let task = currentPreferences.task, !task.isEmpty {
            arguments.append(contentsOf: ["--task", task])
        }

        if currentPreferences.useFast {
            arguments.append("--fast")
        }

        if let device = currentPreferences.device, !device.isEmpty {
            arguments.append(contentsOf: ["--device", device])
        }

        if !additionalTokens.isEmpty {
            arguments.append(contentsOf: additionalTokens)
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

        let postProcessingResult: Result<SegmentationImportResult, Error>

        if process.terminationStatus == 0 {
            do {
                try self.validateSegmentationOutput(at: output)
                let importResult = try self.integrateSegmentationOutput(
                    at: output,
                    outputType: effectiveOutputType,
                    exportContext: exportResult,
                    preferences: currentPreferences,
                    executable: executableResolution,
                    progressController: progressController
                )
                postProcessingResult = .success(importResult)
            } catch {
                postProcessingResult = .failure(error)
            }
        } else {
            postProcessingResult = .failure(
                NSError(
                    domain: "org.totalsegmentator.plugin",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: self.translateErrorOutput(combinedOutput, status: process.terminationStatus)]
                )
            )
        }

        DispatchQueue.main.async {
            progressController.markProcessFinished()

            switch postProcessingResult {
            case .success(let importResult):
                progressController.append("Segmentation finished successfully.")
                progressController.append("Imported \(importResult.addedFilePaths.count) file(s) into Horos.")
                if !importResult.rtStructPaths.isEmpty {
                    progressController.append("Detected \(importResult.rtStructPaths.count) RT Struct file(s).")
                }
                progressController.close(after: 0.5)
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "Segmentation finished successfully."
                )
            case .failure(let error):
                let message: String
                if (error as NSError).domain == "org.totalsegmentator.plugin" {
                    message = error.localizedDescription
                } else {
                    message = error.localizedDescription
                }
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

    private func exportCompatibleSeries(from study: NSObject) throws -> ExportResult {
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
        var exportedSeries: [ExportedSeries] = []

        do {
            for entry in compatibleSeries {
                let seriesIdentifier = (entry.series.value(forKey: "seriesInstanceUID") as? String)
                    .map { sanitizePathComponent($0) }
                    ?? UUID().uuidString

                let seriesDirectory = exportDirectory.appendingPathComponent(seriesIdentifier, isDirectory: true)
                try FileManager.default.createDirectory(at: seriesDirectory, withIntermediateDirectories: true)

                var copiedFiles: [URL] = []

                for path in entry.paths {
                    let sourceURL = URL(fileURLWithPath: path)
                    let destinationURL = seriesDirectory.appendingPathComponent(sourceURL.lastPathComponent)

                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        continue
                    }

                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    exportedFiles += 1
                    copiedFiles.append(destinationURL)
                }

                if let managedSeries = entry.series as? NSManagedObject {
                    let seriesUID = managedSeries.value(forKey: "seriesInstanceUID") as? String
                    let studyUID: String? = {
                        if let studyObject = managedSeries.value(forKey: "study") as? NSManagedObject,
                           let uid = studyObject.value(forKey: "studyInstanceUID") as? String {
                            return uid
                        }
                        return managedSeries.value(forKey: "studyInstanceUID") as? String
                    }()

                    let seriesInfo = ExportedSeries(
                        managedObject: managedSeries,
                        modality: entry.modality,
                        exportedDirectory: seriesDirectory,
                        exportedFiles: copiedFiles,
                        seriesInstanceUID: seriesUID,
                        studyInstanceUID: studyUID
                    )
                    exportedSeries.append(seriesInfo)
                }
            }
        } catch {
            throw ExportError.exportFailed(underlying: error)
        }

        if exportedFiles == 0 {
            throw ExportError.noCompatibleSeries
        }

        if exportedSeries.isEmpty {
            throw ExportError.noCompatibleSeries
        }

        return ExportResult(directory: exportDirectory, series: exportedSeries)
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

    private func detectOutputType(from tokens: [String]) -> (type: SegmentationOutputType, explicit: Bool) {
        var detectedType: SegmentationOutputType = .dicom
        var explicit = false

        for (index, token) in tokens.enumerated() {
            if token == "--output_type" {
                explicit = true
                let value = tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
                detectedType = SegmentationOutputType(argumentValue: value)
            } else if token.hasPrefix("--output_type=") {
                explicit = true
                let value = String(token.dropFirst("--output_type=".count))
                detectedType = SegmentationOutputType(argumentValue: value)
            }
        }

        return (detectedType, explicit)
    }

    private func integrateSegmentationOutput(
        at url: URL,
        outputType: SegmentationOutputType,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        progressController: SegmentationProgressWindowController?
    ) throws -> SegmentationImportResult {
        let importResult: SegmentationImportResult

        switch outputType {
        case .dicom:
            importResult = try importDicomOutputs(from: url)
        case .nifti:
            importResult = try importNiftiOutputs(from: url)
        case .other(let value):
            throw SegmentationPostProcessingError.unsupportedOutputType(value)
        }

        updateVisualization(with: importResult, exportContext: exportContext, progressController: progressController)
        persistAuditMetadata(
            for: importResult,
            exportContext: exportContext,
            outputDirectory: url,
            preferences: preferences,
            outputType: outputType,
            executable: executable
        )

        return importResult
    }

    private func importDicomOutputs(from directory: URL) throws -> SegmentationImportResult {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var dicomPaths: [String] = []
        var rtStructPaths: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                continue
            }

            if isLikelyDicomFile(at: fileURL) {
                dicomPaths.append(fileURL.path)
                if isLikelyRTStruct(at: fileURL) {
                    rtStructPaths.append(fileURL.path)
                }
            }
        }

        guard !dicomPaths.isEmpty else {
            throw SegmentationPostProcessingError.noImportableResults
        }

        var importedObjectIDs: [NSManagedObjectID] = []
        var importError: Error?

        DispatchQueue.main.sync {
            guard let database = BrowserController.currentBrowser()?.database() else {
                importError = SegmentationPostProcessingError.databaseUnavailable
                return
            }

            if let result = database.addFiles(
                atPaths: dicomPaths,
                postNotifications: true,
                dicomOnly: true,
                rereadExistingItems: false,
                generatedByOsiriX: true,
                returnArray: true
            ) as? [NSManagedObjectID] {
                importedObjectIDs = result
            }
        }

        if let error = importError {
            throw error
        }

        return SegmentationImportResult(
            addedFilePaths: dicomPaths,
            rtStructPaths: rtStructPaths,
            importedObjectIDs: importedObjectIDs,
            outputType: .dicom
        )
    }

    private func importNiftiOutputs(from directory: URL) throws -> SegmentationImportResult {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var niftiPaths: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                continue
            }

            if isLikelyNiftiFile(at: fileURL) {
                niftiPaths.append(fileURL.path)
            }
        }

        guard !niftiPaths.isEmpty else {
            throw SegmentationPostProcessingError.noImportableResults
        }

        var importedObjectIDs: [NSManagedObjectID] = []
        var importError: Error?

        DispatchQueue.main.sync {
            guard let database = BrowserController.currentBrowser()?.database() else {
                importError = SegmentationPostProcessingError.databaseUnavailable
                return
            }

            if let result = database.addFiles(
                atPaths: niftiPaths,
                postNotifications: true,
                dicomOnly: false,
                rereadExistingItems: false,
                generatedByOsiriX: true,
                returnArray: true
            ) as? [NSManagedObjectID] {
                importedObjectIDs = result
            }
        }

        if let error = importError {
            throw error
        }

        return SegmentationImportResult(
            addedFilePaths: niftiPaths,
            rtStructPaths: [],
            importedObjectIDs: importedObjectIDs,
            outputType: .nifti
        )
    }

    private func updateVisualization(
        with importResult: SegmentationImportResult,
        exportContext: ExportResult,
        progressController: SegmentationProgressWindowController?
    ) {
        guard importResult.outputType == .dicom, !importResult.rtStructPaths.isEmpty else {
            return
        }

        DispatchQueue.main.async {
            guard let browser = BrowserController.currentBrowser() else {
                progressController?.append("Unable to locate the Horos browser to update the viewer.")
                return
            }

            let viewer = ViewerController.frontMostDisplayed2DViewer() ?? self.openViewer(for: exportContext, browser: browser)

            guard let activeViewer = viewer else {
                progressController?.append("Unable to open a viewer for RT Struct overlay.")
                return
            }

            for path in importResult.rtStructPaths {
                activeViewer.roiLoad(fromSeries: path)
            }

            activeViewer.needsDisplayUpdate()
            progressController?.append("Applied \(importResult.rtStructPaths.count) RT Struct overlay(s) to the active viewer.")
        }
    }

    private func openViewer(for exportContext: ExportResult, browser: BrowserController) -> ViewerController? {
        for series in exportContext.series {
            if let viewer = browser.loadSeries(series.managedObject, viewer: nil, firstViewer: true, keyImagesOnly: false) {
                return viewer
            }
        }

        return nil
    }

    private func persistAuditMetadata(
        for importResult: SegmentationImportResult,
        exportContext: ExportResult,
        outputDirectory: URL,
        preferences: SegmentationPreferences.State,
        outputType: SegmentationOutputType,
        executable: ExecutableResolution
    ) {
        auditQueue.async {
            let version = self.fetchTotalSegmentatorVersion(using: executable)
            let seriesInfo = exportContext.series.map {
                SegmentationAuditEntry.SeriesInfo(
                    seriesInstanceUID: $0.seriesInstanceUID,
                    studyInstanceUID: $0.studyInstanceUID,
                    modality: $0.modality,
                    exportedFileCount: $0.exportedFiles.count
                )
            }

            let entry = SegmentationAuditEntry(
                timestamp: Date(),
                outputDirectory: outputDirectory.path,
                outputType: outputType.description,
                importedFileCount: importResult.addedFilePaths.count,
                rtStructCount: importResult.rtStructPaths.count,
                task: preferences.task,
                device: preferences.device,
                useFast: preferences.useFast,
                additionalArguments: preferences.additionalArguments,
                modelVersion: version,
                series: seriesInfo
            )

            do {
                try self.appendAuditEntry(entry)
            } catch {
                NSLog("[TotalSegmentator] Failed to persist audit metadata: %@", error.localizedDescription)
            }
        }
    }

    private func appendAuditEntry(_ entry: SegmentationAuditEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        var lineData = data
        lineData.append(0x0A)

        let fileURL = try auditLogFileURL()

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(lineData)
        } else {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try lineData.write(to: fileURL, options: .atomic)
        }
    }

    private func auditLogFileURL() throws -> URL {
        let fileManager = FileManager.default

        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "org.totalsegmentator.plugin",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve the Application Support directory for audit logging."]
            )
        }

        let pluginDirectory = supportDirectory.appendingPathComponent("TotalSegmentatorHorosPlugin", isDirectory: true)
        return pluginDirectory.appendingPathComponent("audit-log.jsonl", isDirectory: false)
    }

    private func fetchTotalSegmentatorVersion(using executable: ExecutableResolution) -> String? {
        let process = Process()
        process.executableURL = executable.executableURL
        process.arguments = executable.leadingArguments + ["--version"]
        process.environment = executable.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
            return nil
        }

        return version
    }

    private func isLikelyDicomFile(at url: URL) -> Bool {
        if DicomFile.isDICOMFile(url.path) {
            return true
        }

        let ext = url.pathExtension.lowercased()
        return ext == "dcm" || ext == "dicom"
    }

    private func isLikelyNiftiFile(at url: URL) -> Bool {
        if DicomFile.isNIfTIFile(url.path) {
            return true
        }

        let lowercased = url.lastPathComponent.lowercased()
        return lowercased.hasSuffix(".nii") || lowercased.hasSuffix(".nii.gz")
    }

    private func isLikelyRTStruct(at url: URL) -> Bool {
        let dicomIndicatesRTStruct: Bool = autoreleasepool(invoking: { () -> Bool in
            guard let dicomFile = DicomFile(url.path) else {
                return false
            }

            if dicomFile.getDicomFile() != 0 {
                return false
            }

            guard let elements = dicomFile.dicomElements() as? [AnyHashable: Any] else {
                return false
            }

            if let sopClassUID = elements["SOPClassUID"] as? String,
               sopClassUID == "1.2.840.10008.5.1.4.1.1.481.3" {
                return true
            }

            if let modality = (elements["Modality"] ?? elements["modality"]) as? String,
               modality.uppercased() == "RTSTRUCT" {
                return true
            }

            if let description = (elements["SeriesDescription"] ?? elements["seriesDescription"]) as? String {
                let normalized = description.lowercased()
                if normalized.contains("rtstruct") || normalized.contains("rt struct") {
                    return true
                }
            }

            return false
        })

        if dicomIndicatesRTStruct {
            return true
        }

        return url.lastPathComponent.lowercased().contains("rtstruct")
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
