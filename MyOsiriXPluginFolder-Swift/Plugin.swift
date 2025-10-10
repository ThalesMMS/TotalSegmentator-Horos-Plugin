import Cocoa
import CoreData

private typealias ExecutableResolution = (executableURL: URL, leadingArguments: [String], environment: [String: String]?)

private struct ProcessExecutionResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
    let error: Error?
}

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
    let series: DicomSeries
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

private enum ClassSelectionError: LocalizedError {
    case retrievalFailed(String)
    case decodingFailed
    case noClassesAvailable

    var errorDescription: String? {
        switch self {
        case .retrievalFailed(let message):
            return "Failed to load available classes: \(message)"
        case .decodingFailed:
            return "Received an unexpected response while loading available classes."
        case .noClassesAvailable:
            return "No selectable classes were returned for the current task."
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
    @IBOutlet private weak var classSelectionSummaryField: NSTextField!
    @IBOutlet private weak var classSelectionButton: NSButton!

    private enum MenuAction: String {
        case showSettings = "TotalSegmentator Settings"
        case runSegmentation = "Run TotalSegmentator"
    }

    private let preferences = SegmentationPreferences()
    private var progressWindowController: SegmentationProgressWindowController?
    private var setupProgressWindowController: SegmentationProgressWindowController?
    private let auditQueue = DispatchQueue(label: "org.totalsegmentator.horos.audit", qos: .utility)
    private var classSelectionController: ClassSelectionWindowController?
    private var availableClassOptionsCache: [String: [String]] = [:]
    private var selectedClassNames: Set<String> = [] {
        didSet { updateClassSelectionSummary() }
    }

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
        panel.title = "Select Python interpreter or TotalSegmentator executable"
        panel.prompt = "Choose"

        if let existingPath = executablePathField?.stringValue,
           !existingPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (existingPath as NSString).deletingLastPathComponent)
        }

        if panel.runModal() == .OK, let url = panel.url {
            executablePathField?.stringValue = url.path
        }
    }

    @IBAction private func selectClasses(_ sender: Any) {
        guard let settingsWindow = settingsWindow else { return }

        let storedPreferences = self.preferences.effectivePreferences()
        var effectivePreferences = storedPreferences

        if let pathValue = executablePathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !pathValue.isEmpty {
            effectivePreferences.executablePath = pathValue
        }

        if let taskValue = taskPopupButton?.selectedItem?.representedObject as? String {
            effectivePreferences.task = taskValue
        }

        let normalizedTask = effectivePreferences.task?.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskKey = (normalizedTask?.isEmpty == false ? normalizedTask! : "__default__")

        if let cached = availableClassOptionsCache[taskKey] {
            presentClassSelectionWindow(with: cached, preselected: selectedClassNames)
            return
        }

        classSelectionButton?.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            guard let executableResolution = self.resolvePythonInterpreter(using: effectivePreferences) else {
                DispatchQueue.main.async {
                    self.classSelectionButton?.isEnabled = true
                    self.presentAlert(
                        title: "TotalSegmentator",
                        message: "Unable to locate a Python interpreter. Please verify the executable path before selecting classes."
                    )
                }
                return
            }

            do {
                let options = try self.loadClassOptions(
                    for: normalizedTask,
                    executable: executableResolution
                )
                self.availableClassOptionsCache[taskKey] = options

                DispatchQueue.main.async {
                    self.classSelectionButton?.isEnabled = true
                    self.presentClassSelectionWindow(with: options, preselected: self.selectedClassNames)
                }
            } catch {
                DispatchQueue.main.async {
                    self.classSelectionButton?.isEnabled = true
                    self.presentAlert(
                        title: "TotalSegmentator",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func presentClassSelectionWindow(with options: [String], preselected: Set<String>) {
        guard let settingsWindow = settingsWindow else { return }

        let preselectedArray = Array(preselected.intersection(Set(options)))
        let controller = ClassSelectionWindowController(
            availableClasses: options,
            preselected: preselectedArray
        )

        controller.onSelectionConfirmed = { [weak self] selection in
            guard let self = self else { return }
            self.selectedClassNames = Set(selection)
            self.classSelectionController = nil
            self.persistPreferencesFromUI()
        }

        controller.onSelectionCancelled = { [weak self] in
            self?.classSelectionController = nil
        }

        classSelectionController = controller
        settingsWindow.beginSheet(controller.window!, completionHandler: nil)
    }


    private func loadClassOptions(for task: String?, executable: ExecutableResolution) throws -> [String] {
        let taskLiteral: String
        if let rawTask = task?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTask.isEmpty {
            let escaped = rawTask
                .replacingOccurrences(of: "\", with: "\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            taskLiteral = "\"" + escaped + "\""
        } else {
            taskLiteral = "None"
        }

        let scriptTemplate = """
import json
from totalsegmentator.map_to_binary import class_map

task = <<TASK>>
candidates = []

if isinstance(task, str) and task.strip():
    normalized = task.strip()
    candidates.append(normalized)
    if normalized.endswith("_fast"):
        candidates.append(normalized[:-5])
    if normalized.endswith("_mr"):
        candidates.append(normalized[:-3])
    if normalized.startswith("total"):
        candidates.append("total")
else:
    candidates.extend(["total", "total_mr"])

fallbacks = ["total", "total_mr"]
for candidate in fallbacks:
    if candidate not in candidates:
        candidates.append(candidate)

mapping = None
for candidate in candidates:
    if candidate in class_map:
        mapping = class_map[candidate]
        break

if mapping is None:
    print(json.dumps({"error": "unavailable"}))
else:
    names = sorted(set(str(value) for value in mapping.values()))
    print(json.dumps({"names": names}))
"""

        let script = scriptTemplate.replacingOccurrences(of: "<<TASK>>", with: taskLiteral)

        let process = Process()
        process.executableURL = executable.executableURL
        process.arguments = executable.leadingArguments + ["-c", script]
        process.environment = executable.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ClassSelectionError.retrievalFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let combinedData = outputData + errorData
            let combinedMessage = String(data: combinedData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallbackMessage = "Python process exited with status \(process.terminationStatus)"
            let message = combinedMessage.isEmpty ? fallbackMessage : combinedMessage
            throw ClassSelectionError.retrievalFailed(message)
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: outputData, options: []),
              let dictionary = jsonObject as? [String: Any] else {
            throw ClassSelectionError.decodingFailed
        }

        if let errorMessage = dictionary["error"] as? String {
            throw ClassSelectionError.retrievalFailed(errorMessage)
        }

        guard let names = dictionary["names"] as? [String], !names.isEmpty else {
            throw ClassSelectionError.noClassesAvailable
        }

        return names
    }


    private func updateClassSelectionSummary() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let summaryField = self.classSelectionSummaryField else { return }

            let names = Array(self.selectedClassNames).sorted()
            let summaryText: String
            if names.isEmpty {
                summaryText = NSLocalizedString("All classes", comment: "Summary shown when all classes are selected")
                summaryField.toolTip = nil
            } else if names.count <= 3 {
                summaryText = names.joined(separator: ", ")
                summaryField.toolTip = summaryText
            } else {
                summaryText = String(format: NSLocalizedString("%d classes selected", comment: "Summary with number of selected classes"), names.count)
                summaryField.toolTip = names.joined(separator: ", ")
            }

            summaryField.stringValue = summaryText
        }
    }

    private func supportsClassSelection(for task: String?) -> Bool {
        guard let normalized = task?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return true
        }

        return normalized.hasPrefix("total")
    }

    private func performInitialSetupIfNeeded() {
        autoreleasepool {
            var preferencesState = preferences.effectivePreferences()
            var updatedPreferences = preferencesState

            guard var executableResolution = resolvePythonInterpreter(using: preferencesState) else {
                presentEnvironmentSetupFailureInstructions()
                return
            }

            if !pythonModuleAvailable("totalsegmentator", using: executableResolution) {
                logToConsole("TotalSegmentator module not found. Attempting to create a managed virtual environment.")

                if let managed = bootstrapManagedPythonEnvironment(baseResolution: executableResolution) {
                    executableResolution = managed.resolution
                    updatedPreferences.executablePath = managed.pythonPath
                    preferences.store(updatedPreferences)
                    preferencesState = updatedPreferences

                    DispatchQueue.main.async { [weak self] in
                        self?.executablePathField?.stringValue = managed.pythonPath
                    }
                } else {
                    finishSetupProgress(with: nil)
                    presentEnvironmentSetupFailureInstructions()
                    return
                }
            }

            guard pythonModuleAvailable("totalsegmentator", using: executableResolution) else {
                finishSetupProgress(with: nil)
                presentEnvironmentSetupFailureInstructions()
                return
            }

            let setupSucceeded = ensureTotalSegmentatorSetup(using: executableResolution)
            if !setupSucceeded {
                finishSetupProgress(with: "TotalSegmentator setup encountered issues. Please review the log output.")
                return
            }

            guard let dcm2niixPath = ensureDcm2Niix(using: executableResolution) else {
                finishSetupProgress(with: "Unable to prepare dcm2niix. Please review the displayed instructions.")
                return
            }

            if updatedPreferences.dcm2niixPath != dcm2niixPath {
                updatedPreferences.dcm2niixPath = dcm2niixPath
                preferences.store(updatedPreferences)
            }

            finishSetupProgress(with: "Initial setup complete.")
        }
    }

    private func presentSetupProgressWindowIfNeeded(initialMessage: String? = nil) -> SegmentationProgressWindowController {
        if let controller = setupProgressWindowController {
            if let message = initialMessage {
                DispatchQueue.main.async {
                    controller.append(message)
                }
            }
            return controller
        }

        let controller = SegmentationProgressWindowController()
        setupProgressWindowController = controller

        DispatchQueue.main.async {
            controller.showWindow(nil)
            controller.start()
            if let message = initialMessage {
                controller.append(message)
            } else {
                controller.append("Preparing TotalSegmentator environment…")
            }
        }

        return controller
    }

    private func finishSetupProgress(with message: String?) {
        guard let controller = setupProgressWindowController else { return }

        DispatchQueue.main.async {
            if let message = message, !message.isEmpty {
                controller.append(message)
            }
            controller.markProcessFinished()
            controller.close(after: 2.0)
        }

        setupProgressWindowController = nil
    }

    private func pythonModuleAvailable(_ moduleName: String, using resolution: ExecutableResolution) -> Bool {
        let script = """
import importlib.util
import sys

module = sys.argv[1]
spec = importlib.util.find_spec(module)
sys.exit(0 if spec is not None else 1)
"""

        let result = runPythonProcess(
            using: resolution,
            arguments: ["-c", script, moduleName],
            progressController: nil
        )

        if let error = result.error {
            logToConsole("Python execution failed while probing module '\(moduleName)': \(error.localizedDescription)")
            return false
        }

        return result.terminationStatus == 0
    }

    private func runPythonProcess(
        using resolution: ExecutableResolution,
        arguments: [String],
        environment customEnvironment: [String: String]? = nil,
        progressController: SegmentationProgressWindowController?
    ) -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = resolution.executableURL
        process.arguments = resolution.leadingArguments + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"

        if let baseEnvironment = resolution.environment {
            environment.merge(baseEnvironment) { _, new in new }
        }

        if let custom = customEnvironment {
            environment.merge(custom) { _, new in new }
        }

        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var capturedStdout = Data()
        var capturedStderr = Data()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self, weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            capturedStdout.append(data)

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
            capturedStderr.append(data)

            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                DispatchQueue.main.async {
                    progressController?.append(message)
                    self?.logToConsole(message)
                }
            }
        }

        var launchError: Error?

        do {
            try process.run()
        } catch {
            launchError = error
        }

        if let error = launchError {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            return ProcessExecutionResult(terminationStatus: -1, stdout: capturedStdout, stderr: capturedStderr, error: error)
        }

        process.waitUntilExit()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        capturedStdout.append(stdoutHandle.readDataToEndOfFile())
        capturedStderr.append(stderrHandle.readDataToEndOfFile())

        return ProcessExecutionResult(
            terminationStatus: process.terminationStatus,
            stdout: capturedStdout,
            stderr: capturedStderr,
            error: nil
        )
    }

    private func bootstrapManagedPythonEnvironment(
        baseResolution: ExecutableResolution
    ) -> (resolution: ExecutableResolution, pythonPath: String)? {
        guard let environmentDirectory = managedEnvironmentDirectory() else {
            logToConsole("Failed to resolve a location for the managed Python environment.")
            return nil
        }

        let binDirectory = environmentDirectory.appendingPathComponent("bin", isDirectory: true)
        let python3URL = binDirectory.appendingPathComponent("python3", isDirectory: false)
        let pythonURL = binDirectory.appendingPathComponent("python", isDirectory: false)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: python3URL.path) && !fileManager.fileExists(atPath: pythonURL.path) {
            let controller = presentSetupProgressWindowIfNeeded(initialMessage: "Creating managed Python environment…")
            let result = runPythonProcess(
                using: baseResolution,
                arguments: ["-m", "venv", environmentDirectory.path],
                progressController: controller
            )

            if result.terminationStatus != 0 || result.error != nil {
                DispatchQueue.main.async {
                    controller.append("Failed to create the virtual environment. Please review the console output.")
                }
                logToConsole("Failed to create virtual environment: status=\(result.terminationStatus)")
                return nil
            }
        }

        let pythonBinary: URL
        if fileManager.isExecutableFile(atPath: python3URL.path) {
            pythonBinary = python3URL
        } else if fileManager.isExecutableFile(atPath: pythonURL.path) {
            pythonBinary = pythonURL
        } else {
            logToConsole("Managed Python environment exists but no executable interpreter was found.")
            return nil
        }

        var environment = baseResolution.environment ?? [:]
        var existingPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let binPath = binDirectory.path
        let pathComponents = existingPath.split(separator: ":").map(String.init)
        if !pathComponents.contains(binPath) {
            existingPath = binPath + (existingPath.isEmpty ? "" : ":" + existingPath)
        }
        environment["PATH"] = existingPath
        environment["VIRTUAL_ENV"] = environmentDirectory.path

        let managedResolution: ExecutableResolution = (pythonBinary, [], environment)

        if !pythonModuleAvailable("totalsegmentator", using: managedResolution) {
            let controller = presentSetupProgressWindowIfNeeded(initialMessage: "Installing TotalSegmentator into managed environment…")

            _ = runPythonProcess(
                using: managedResolution,
                arguments: ["-m", "pip", "install", "--upgrade", "pip"],
                progressController: controller
            )

            let installResult = runPythonProcess(
                using: managedResolution,
                arguments: ["-m", "pip", "install", "--upgrade", "TotalSegmentator"],
                progressController: controller
            )

            if installResult.terminationStatus != 0 || installResult.error != nil {
                logToConsole("Failed to install TotalSegmentator into managed environment: status=\(installResult.terminationStatus)")
                return nil
            }
        }

        guard pythonModuleAvailable("totalsegmentator", using: managedResolution) else {
            logToConsole("Managed environment was created but TotalSegmentator is still unavailable.")
            return nil
        }

        return (managedResolution, pythonBinary.path)
    }

    private func managedEnvironmentDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let pluginDirectory = supportDirectory.appendingPathComponent("TotalSegmentatorHorosPlugin", isDirectory: true)
        let environmentDirectory = pluginDirectory.appendingPathComponent("PythonEnvironment", isDirectory: true)

        do {
            try fileManager.createDirectory(at: environmentDirectory, withIntermediateDirectories: true)
        } catch {
            logToConsole("Failed to create managed environment directory: \(error.localizedDescription)")
            return nil
        }

        return environmentDirectory
    }

    private func ensureTotalSegmentatorSetup(using resolution: ExecutableResolution) -> Bool {
        let controller = presentSetupProgressWindowIfNeeded(initialMessage: "Ensuring TotalSegmentator configuration and weights are available…")

        let script = """
import json
from totalsegmentator.python_api import setup_totalseg, setup_nnunet

setup_totalseg()
setup_nnunet()
print("__RESULT__" + json.dumps({"status": "ok"}))
"""

        let result = runPythonProcess(
            using: resolution,
            arguments: ["-c", script],
            progressController: controller
        )

        if let error = result.error {
            logToConsole("Failed to execute TotalSegmentator setup: \(error.localizedDescription)")
            return false
        }

        guard result.terminationStatus == 0 else {
            logToConsole("TotalSegmentator setup script exited with status \(result.terminationStatus)")
            return false
        }

        if let dictionary = extractResultDictionary(from: result.stdout), dictionary["status"] as? String == "ok" {
            DispatchQueue.main.async {
                controller.append("TotalSegmentator setup finished successfully.")
            }
        } else {
            DispatchQueue.main.async {
                controller.append("TotalSegmentator setup finished.")
            }
        }

        return true
    }

    private func ensureDcm2Niix(using resolution: ExecutableResolution) -> String? {
        let controller = presentSetupProgressWindowIfNeeded(initialMessage: "Checking for dcm2niix availability…")

        let script = """
import json
import platform
import shutil
import sys

from pathlib import Path

from totalsegmentator.dicom_io import download_dcm2niix
from totalsegmentator.config import get_weights_dir


def locate():
    path = shutil.which("dcm2niix")
    if path:
        return path

    weights = Path(get_weights_dir())
    if platform.system().lower().startswith("win"):
        candidate = weights / "dcm2niix.exe"
    else:
        candidate = weights / "dcm2niix"

    if candidate.exists():
        return str(candidate)

    return None


result = locate()
if result is None:
    download_dcm2niix()
    result = locate()

if result is None:
    print("__RESULT__" + json.dumps({"path": None}))
    sys.exit(1)

print("__RESULT__" + json.dumps({"path": result}))
"""

        let result = runPythonProcess(
            using: resolution,
            arguments: ["-c", script],
            progressController: controller
        )

        if let error = result.error {
            logToConsole("Failed to verify dcm2niix availability: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "Unable to verify or download dcm2niix. Please install it manually and update your PATH."
                )
            }
            return nil
        }

        guard result.terminationStatus == 0,
              let dictionary = extractResultDictionary(from: result.stdout),
              let path = dictionary["path"] as? String,
              !path.isEmpty else {
            DispatchQueue.main.async {
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "dcm2niix could not be downloaded automatically. Please install it manually and ensure it is on the PATH."
                )
            }
            return nil
        }

        DispatchQueue.main.async {
            controller.append("dcm2niix available at: \(path)")
        }

        return path
    }

    private func extractResultDictionary(from data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(whereSeparator: { $0.isNewline }) {
            if line.hasPrefix("__RESULT__") {
                let payloadString = String(line.dropFirst("__RESULT__".count))
                if let payloadData = payloadString.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: payloadData, options: []),
                   let dictionary = object as? [String: Any] {
                    return dictionary
                }
            }
        }

        return nil
    }

    private func pipInstallInstruction(for module: String, using resolution: ExecutableResolution) -> String {
        let components = [resolution.executableURL.path] + resolution.leadingArguments + ["-m", "pip", "install", module]
        return components.map { component -> String in
            if component.contains(" ") {
                return "\"\(component)\""
            }
            return component
        }.joined(separator: " ")
    }

    private func presentEnvironmentSetupFailureInstructions() {
        let message = """
Unable to prepare a Python environment with TotalSegmentator installed.

Please install TotalSegmentator manually, for example:
  python3 -m venv ~/totalseg-env
  ~/totalseg-env/bin/python3 -m pip install --upgrade pip TotalSegmentator

Then update the plugin settings to point to the Python interpreter in that environment.
"""

        DispatchQueue.main.async {
            self.presentAlert(title: "TotalSegmentator", message: message)
        }
    }

    private func ensureRtUtilsAvailable(using resolution: ExecutableResolution) -> Bool {
        if pythonModuleAvailable("rt_utils", using: resolution) {
            return true
        }

        logToConsole("The configured Python environment is missing the optional 'rt_utils' package.")
        let command = pipInstallInstruction(for: "rt_utils", using: resolution)
        let message = """
The optional 'rt_utils' package is required to export DICOM RT-Struct files.

Install it by running:
  \(command)

After installing the package, re-run the segmentation.
"""

        DispatchQueue.main.async {
            self.presentAlert(title: "TotalSegmentator", message: message)
        }

        return false
    }

    override func initPlugin() {
        let bundle = Bundle(identifier: "com.totalsegmentator.horosplugin")
        bundle?.loadNibNamed("Settings", owner: self, topLevelObjects: nil)
        settingsWindow?.delegate = self
        configureSettingsInterfaceIfNeeded()
        NSLog("TotalSegmentatorHorosPlugin loaded and ready.")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performInitialSetupIfNeeded()
        }
    }

    private func startSegmentationFlow() {
        guard let viewer = ViewerController.frontMostDisplayed2DViewer() else {
            presentAlert(title: "TotalSegmentator", message: "No active viewer is available.")
            return
        }

        let exportResult: ExportResult
        do {
            exportResult = try exportActiveSeries(from: viewer)
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
        defer { cleanupTemporaryDirectory(exportResult.directory) }

        let currentPreferences = preferences.effectivePreferences()

        guard let executableResolution = resolvePythonInterpreter(using: currentPreferences) else {
            DispatchQueue.main.async {
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "Unable to locate a Python interpreter with TotalSegmentator installed. Please verify the path in the plugin settings."
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
        let sanitizedAdditionalTokens = removeROISubsetTokens(from: outputDetection.remainingTokens)
        let effectiveOutputType: SegmentationOutputType = .dicom
        if outputDetection.type != .dicom {
            logToConsole("Overriding requested output type '\(outputDetection.type.description)' with 'dicom' to ensure RT Struct overlays are generated.")
        }

        if effectiveOutputType == .dicom {
            guard ensureRtUtilsAvailable(using: executableResolution) else {
                return
            }
        }

        var totalSegmentatorArguments: [String] = []
        if let task = currentPreferences.task, !task.isEmpty {
            totalSegmentatorArguments.append(contentsOf: ["--task", task])
        }

        if currentPreferences.useFast {
            totalSegmentatorArguments.append("--fast")
        }

        if let device = currentPreferences.device, !device.isEmpty {
            totalSegmentatorArguments.append(contentsOf: ["--device", device])
        }

        if !sanitizedAdditionalTokens.isEmpty {
            totalSegmentatorArguments.append(contentsOf: sanitizedAdditionalTokens)
        }

        let configuredClassSelection = currentPreferences.selectedClassNames
        if !configuredClassSelection.isEmpty {
            if supportsClassSelection(for: currentPreferences.task) {
                totalSegmentatorArguments.append("--roi_subset")
                totalSegmentatorArguments.append(contentsOf: configuredClassSelection)
            } else {
                logToConsole("Ignoring configured class selection because the current task does not support ROI subsets.")
            }
        }

        guard let primarySeries = exportResult.series.first else {
            DispatchQueue.main.async {
                self.presentAlert(
                    title: "TotalSegmentator",
                    message: "No exported DICOM series was found for segmentation."
                )
            }
            return
        }

        let bridgeScriptURL: URL
        let configurationURL: URL

        do {
            bridgeScriptURL = try prepareBridgeScript(at: exportResult.directory)
            configurationURL = try writeBridgeConfiguration(
                to: exportResult.directory,
                dicomDirectory: primarySeries.exportedDirectory,
                outputDirectory: output,
                outputType: effectiveOutputType.description,
                totalsegmentatorArguments: totalSegmentatorArguments
            )
        } catch {
            DispatchQueue.main.async {
                self.presentAlert(title: "TotalSegmentator", message: error.localizedDescription)
            }
            return
        }

        let process = Process()
        process.executableURL = executableResolution.executableURL
        process.arguments = executableResolution.leadingArguments + [bridgeScriptURL.path, "--config", configurationURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        if let customEnvironment = executableResolution.environment {
            environment.merge(customEnvironment) { _, new in new }
        }
        if let dcm2niixPath = currentPreferences.dcm2niixPath, !dcm2niixPath.isEmpty {
            let binaryURL = URL(fileURLWithPath: dcm2niixPath)
            let directoryPath = binaryURL.deletingLastPathComponent().path
            var pathVariable = environment["PATH"] ?? ""
            let existingComponents = pathVariable.split(separator: ":").map(String.init)
            if !existingComponents.contains(directoryPath) {
                pathVariable = directoryPath + (pathVariable.isEmpty ? "" : ":" + pathVariable)
            }
            environment["PATH"] = pathVariable
            environment["TOTALSEGMENTATOR_DCM2NIIX"] = dcm2niixPath
        }
        process.environment = environment

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

    private func exportActiveSeries(from viewer: ViewerController) throws -> ExportResult {
        enum ActiveSeriesExportError: LocalizedError {
            case missingSeries
            case unsupportedModality(String?)
            case missingSlices
            case exportFailed(underlying: Error)

            var errorDescription: String? {
                switch self {
                case .missingSeries:
                    return "The active viewer does not reference a DICOM series."
                case .unsupportedModality(let value):
                    if let value = value, !value.isEmpty {
                        return "The active series modality '\(value)' is not supported by TotalSegmentator."
                    }
                    return "The active series modality is not supported by TotalSegmentator."
                case .missingSlices:
                    return "Unable to locate the DICOM slices for the active series."
                case .exportFailed(let underlying):
                    return "Failed to export the active DICOM series: \(underlying.localizedDescription)"
                }
            }
        }

        let supportedModalities: Set<String> = ["CT", "MR"]

        guard let series = viewer.seriesObj else {
            throw ActiveSeriesExportError.missingSeries
        }

        let rawModality = series.modality ?? (series.value(forKey: "modality") as? String)
        let normalizedModality = rawModality?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard let modality = normalizedModality, supportedModalities.contains(modality) else {
            throw ActiveSeriesExportError.unsupportedModality(normalizedModality)
        }

        let paths = normalizePaths(from: series.paths())
        guard !paths.isEmpty else {
            throw ActiveSeriesExportError.missingSlices
        }

        let exportDirectory = try makeExportDirectory()
        let seriesIdentifierSource = series.seriesInstanceUID
            ?? (series.value(forKey: "seriesInstanceUID") as? String)
        let seriesIdentifier = seriesIdentifierSource.map { sanitizePathComponent($0) } ?? UUID().uuidString

        let seriesDirectory = exportDirectory.appendingPathComponent(seriesIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: seriesDirectory, withIntermediateDirectories: true)

        var copiedFiles: [URL] = []

        do {
            for path in paths {
                let sourceURL = URL(fileURLWithPath: path)
                let destinationURL = seriesDirectory.appendingPathComponent(sourceURL.lastPathComponent)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    copiedFiles.append(destinationURL)
                    continue
                }

                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                copiedFiles.append(destinationURL)
            }
        } catch {
            throw ActiveSeriesExportError.exportFailed(underlying: error)
        }

        guard !copiedFiles.isEmpty else {
            throw ActiveSeriesExportError.missingSlices
        }

        let exportedSeries = ExportedSeries(
            series: series,
            modality: modality,
            exportedDirectory: seriesDirectory,
            exportedFiles: copiedFiles,
            seriesInstanceUID: seriesIdentifierSource,
            studyInstanceUID: series.study?.studyInstanceUID
        )

        return ExportResult(directory: exportDirectory, series: [exportedSeries])
    }

    private func exportCompatibleSeries(from study: DicomStudy) throws -> ExportResult {
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
        let seriesArray = normalizeSeriesCollection(seriesCollection)

        guard !seriesArray.isEmpty else {
            throw ExportError.noSeries
        }

        let compatibleSeries = seriesArray.compactMap { series -> (series: DicomSeries, modality: String, paths: [String])? in
            let rawModality = series.modality ?? (series.value(forKey: "modality") as? String)
            let normalizedModality = rawModality?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

            guard let modality = normalizedModality, supportedModalities.contains(modality) else {
                return nil
            }

            let paths = normalizePaths(from: series.paths())

            guard !paths.isEmpty else {
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
                let identifierSource = entry.series.seriesInstanceUID
                    ?? (entry.series.value(forKey: "seriesInstanceUID") as? String)
                let seriesIdentifier = identifierSource.map { sanitizePathComponent($0) } ?? UUID().uuidString

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

                guard !copiedFiles.isEmpty else { continue }

                let seriesInfo = ExportedSeries(
                    series: entry.series,
                    modality: entry.modality,
                    exportedDirectory: seriesDirectory,
                    exportedFiles: copiedFiles,
                    seriesInstanceUID: entry.series.seriesInstanceUID
                        ?? (entry.series.value(forKey: "seriesInstanceUID") as? String),
                    studyInstanceUID: entry.series.study?.studyInstanceUID ?? study.studyInstanceUID
                )
                exportedSeries.append(seriesInfo)
            }
        } catch {
            throw ExportError.exportFailed(underlying: error)
        }

        guard exportedFiles > 0 else {
            throw ExportError.noCompatibleSeries
        }

        guard !exportedSeries.isEmpty else {
            throw ExportError.noCompatibleSeries
        }

        return ExportResult(directory: exportDirectory, series: exportedSeries)
    }

    private func prepareBridgeScript(at directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("TotalSegmentatorBridge.py", isDirectory: false)
        let scriptContents = """
import argparse
import json
import subprocess
import sys
import traceback
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Bridge script for the Horos TotalSegmentator plugin")
    parser.add_argument("--config", required=True, help="Path to the configuration JSON file")
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    dicom_dir = Path(config["dicom_dir"]).expanduser()
    output_dir = Path(config["output_dir"]).expanduser()
    output_type = config.get("output_type", "dicom")

    output_dir.mkdir(parents=True, exist_ok=True)

    command = [
        sys.executable,
        "-m",
        "totalsegmentator.bin.TotalSegmentator",
        "-i",
        str(dicom_dir),
        "-o",
        str(output_dir),
        "--output_type",
        output_type,
    ]
    command.extend(config.get("totalseg_args", []))

    print("[TotalSegmentatorBridge] Executing: " + " ".join(command), flush=True)

    try:
        result = subprocess.run(command, check=False)
    except Exception:
        print("[TotalSegmentatorBridge] Failed to execute TotalSegmentator:", file=sys.stderr, flush=True)
        traceback.print_exc()
        return 1

    if result.returncode != 0:
        print(f"[TotalSegmentatorBridge] TotalSegmentator exited with status {result.returncode}", file=sys.stderr, flush=True)

    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
"""

        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)

        return scriptURL
    }

    private func writeBridgeConfiguration(
        to directory: URL,
        dicomDirectory: URL,
        outputDirectory: URL,
        outputType: String,
        totalsegmentatorArguments: [String]
    ) throws -> URL {
        let configurationURL = directory.appendingPathComponent("TotalSegmentatorBridgeConfiguration.json", isDirectory: false)

        let payload: [String: Any] = [
            "dicom_dir": dicomDirectory.path,
            "output_dir": outputDirectory.path,
            "output_type": outputType,
            "totalseg_args": totalsegmentatorArguments
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configurationURL, options: .atomic)

        return configurationURL
    }

    private func normalizeSeriesCollection(_ value: Any?) -> [DicomSeries] {
        if let series = value as? [DicomSeries] {
            return series
        }

        if let series = value as? [Any] {
            return series.compactMap { $0 as? DicomSeries }
        }

        if let orderedSet = value as? NSOrderedSet {
            return orderedSet.array.compactMap { $0 as? DicomSeries }
        }

        if let nsSet = value as? NSSet {
            return nsSet.allObjects.compactMap { $0 as? DicomSeries }
        }

        if let set = value as? Set<DicomSeries> {
            return Array(set)
        }

        if let set = value as? Set<AnyHashable> {
            return set.compactMap { $0.base as? DicomSeries }
        }

        if let single = value as? DicomSeries {
            return [single]
        }

        return []
    }

    private func normalizePaths(from value: Any?) -> [String] {
        if let paths = value as? [String] {
            return paths
        }

        if let paths = value as? [Any] {
            return paths.compactMap { $0 as? String }
        }

        if let orderedSet = value as? NSOrderedSet {
            return orderedSet.array.compactMap { $0 as? String }
        }

        if let nsSet = value as? NSSet {
            return nsSet.allObjects.compactMap { $0 as? String }
        }

        if let set = value as? Set<String> {
            return Array(set)
        }

        if let set = value as? Set<AnyHashable> {
            return set.compactMap { $0.base as? String }
        }

        if let single = value as? String {
            return [single]
        }

        return []
    }

    private func makeExportDirectory() throws -> URL {
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TotalSegmentator", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let exportDirectory = baseDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        return exportDirectory
    }

    private func cleanupTemporaryDirectory(_ url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            NSLog("[TotalSegmentator] Failed to clean temporary directory %@: %@", url.path, error.localizedDescription)
        }
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
        classSelectionSummaryField?.isEditable = false
        classSelectionSummaryField?.isSelectable = false
        classSelectionSummaryField?.usesSingleLineMode = true
        classSelectionSummaryField?.lineBreakMode = .byTruncatingTail
        classSelectionSummaryField?.placeholderString = NSLocalizedString("All classes", comment: "Placeholder for class selection summary")
        classSelectionButton?.title = NSLocalizedString("Select Classes…", comment: "Button title for class selection")
        updateClassSelectionSummary()
    }

    private func populateSettingsUI() {
        let current = preferences.effectivePreferences()
        executablePathField?.stringValue = current.executablePath ?? ""
        additionalArgumentsField?.stringValue = current.additionalArguments ?? ""
        fastModeCheckbox?.state = current.useFast ? .on : .off
        selectedClassNames = Set(current.selectedClassNames)

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
        updated.selectedClassNames = Array(selectedClassNames).sorted()

        preferences.store(updated)
    }

    private func resolvePythonInterpreter(using preferences: SegmentationPreferences.State) -> ExecutableResolution? {
        if let explicitPath = preferences.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty,
           let resolution = interpreterResolution(for: explicitPath) {
            return resolution
        }

        if let defaultExecutable = try? preferences.defaultExecutableURL(),
           let resolution = interpreterResolution(for: defaultExecutable.path) {
            return resolution
        }

        return (
            URL(fileURLWithPath: "/usr/bin/env"),
            ["python3"],
            nil
        )
    }

    private func interpreterResolution(for path: String) -> ExecutableResolution? {
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)

            if isPythonExecutable(url) {
                return (url, [], nil)
            }

            if let shebang = shebangResolution(for: url) {
                return shebang
            }

            if url.pathExtension.lowercased() == "py" {
                return (
                    URL(fileURLWithPath: "/usr/bin/env"),
                    ["python3", url.path],
                    nil
                )
            }

            return nil
        } else {
            if path.lowercased().contains("python") {
                return (
                    URL(fileURLWithPath: "/usr/bin/env"),
                    [path],
                    nil
                )
            }

            if let located = locateExecutableInPATH(named: path) {
                if isPythonExecutable(located) {
                    return (located, [], nil)
                }

                if let shebang = shebangResolution(for: located) {
                    return shebang
                }
            }

            return nil
        }
    }

    private func locateExecutableInPATH(named command: String) -> URL? {
        let fileManager = FileManager.default
        let pathVariable = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in pathVariable.split(separator: ":") {
            let directory = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !directory.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func isPythonExecutable(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "python" || name == "python3" || name.hasPrefix("python3") || name.hasPrefix("python")
    }

    private func shebangResolution(for url: URL) -> ExecutableResolution? {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 256)
        guard let contents = String(data: data, encoding: .utf8) else { return nil }
        guard let firstLine = contents.components(separatedBy: .newlines).first, firstLine.hasPrefix("#!") else {
            return nil
        }

        let shebangBody = firstLine.dropFirst(2)
        let components = shebangBody.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }

        let executablePath = components[0]
        let arguments = Array(components.dropFirst())

        let executableURL = URL(fileURLWithPath: executablePath)
        return (executableURL, arguments, nil)
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

    private func detectOutputType(from tokens: [String]) -> (type: SegmentationOutputType, remainingTokens: [String]) {
        var detectedType: SegmentationOutputType = .dicom
        var remainingTokens: [String] = []

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            if token == "--output_type" {
                let nextIndex = index + 1
                if nextIndex < tokens.count {
                    let valueCandidate = tokens[nextIndex]
                    if valueCandidate.hasPrefix("--") {
                        detectedType = .dicom
                        index += 1
                        continue
                    }

                    detectedType = SegmentationOutputType(argumentValue: valueCandidate)
                    index += 2
                    continue
                }

                detectedType = .dicom
                index += 1
                continue
            }

            if token.hasPrefix("--output_type=") {
                let value = String(token.dropFirst("--output_type=".count))
                detectedType = SegmentationOutputType(argumentValue: value)
                index += 1
                continue
            }

            remainingTokens.append(token)
            index += 1
        }

        return (detectedType, remainingTokens)
    }

    private func removeROISubsetTokens(from tokens: [String]) -> [String] {
        var filtered: [String] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            if token == "--roi_subset" {
                index += 1
                while index < tokens.count, !tokens[index].hasPrefix("--") {
                    index += 1
                }
                continue
            }

            if token.hasPrefix("--roi_subset=") {
                index += 1
                continue
            }

            filtered.append(token)
            index += 1
        }

        return filtered
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

            activeViewer.refresh()
            activeViewer.window?.makeKeyAndOrderFront(nil)
            activeViewer.needsDisplayUpdate()
            progressController?.append("Applied \(importResult.rtStructPaths.count) RT Struct overlay(s) to the active viewer.")
        }
    }

    private func openViewer(for exportContext: ExportResult, browser: BrowserController) -> ViewerController? {
        for exportedSeries in exportContext.series {
            if let viewer = browser.loadSeries(exportedSeries.series, viewer: nil, firstViewer: true, keyImagesOnly: false) {
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
        process.arguments = executable.leadingArguments + ["-m", "totalsegmentator.bin.TotalSegmentator", "--version"]
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
            var selectedClassNames: [String]
            var dcm2niixPath: String?
        }

        private enum Keys {
            static let executablePath = "TotalSegmentatorExecutablePath"
            static let task = "TotalSegmentatorTask"
            static let fastMode = "TotalSegmentatorFastMode"
            static let device = "TotalSegmentatorDevice"
            static let additionalArguments = "TotalSegmentatorAdditionalArguments"
            static let selectedClasses = "TotalSegmentatorSelectedClasses"
            static let dcm2niixPath = "TotalSegmentatorDcm2NiixPath"
        }

        private let defaults = UserDefaults.standard

        func effectivePreferences() -> State {
            State(
                executablePath: defaults.string(forKey: Keys.executablePath),
                task: defaults.string(forKey: Keys.task),
                useFast: defaults.bool(forKey: Keys.fastMode),
                device: defaults.string(forKey: Keys.device),
                additionalArguments: defaults.string(forKey: Keys.additionalArguments),
                selectedClassNames: defaults.stringArray(forKey: Keys.selectedClasses) ?? [],
                dcm2niixPath: defaults.string(forKey: Keys.dcm2niixPath)
            )
        }

        func store(_ state: State) {
            defaults.setValue(state.executablePath, forKey: Keys.executablePath)
            defaults.setValue(state.task, forKey: Keys.task)
            defaults.setValue(state.useFast, forKey: Keys.fastMode)
            defaults.setValue(state.device, forKey: Keys.device)
            defaults.setValue(state.additionalArguments, forKey: Keys.additionalArguments)
            defaults.setValue(state.selectedClassNames, forKey: Keys.selectedClasses)
            defaults.setValue(state.dcm2niixPath, forKey: Keys.dcm2niixPath)
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
