import Foundation

// MARK: - Process Execution Module

/// Handles execution of external processes, particularly Python scripts.
final class ProcessExecutor {

    // MARK: - Singleton

    static let shared = ProcessExecutor()

    private init() {}

    // MARK: - Public Methods

    /// Execute a Python process with the given parameters.
    ///
    /// - Parameters:
    ///   - resolution: The executable resolution containing path and environment
    ///   - arguments: Command-line arguments to pass to the process
    ///   - customEnvironment: Additional environment variables
    ///   - progressController: Optional progress window to display output
    ///   - consoleLogger: Optional closure for logging to console
    /// - Returns: Result of the process execution
    func runPythonProcess(
        using resolution: ExecutableResolution,
        arguments: [String],
        environment customEnvironment: [String: String]? = nil,
        progressController: SegmentationProgressWindowController?,
        consoleLogger: ((String) -> Void)? = nil
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

        stdoutHandle.readabilityHandler = { [weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            capturedStdout.append(data)

            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                DispatchQueue.main.async {
                    progressController?.append(message)
                    consoleLogger?(message)
                }
            }
        }

        stderrHandle.readabilityHandler = { [weak progressController] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            capturedStderr.append(data)

            if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                DispatchQueue.main.async {
                    progressController?.append(message)
                    consoleLogger?(message)
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
            return ProcessExecutionResult(
                terminationStatus: -1,
                stdout: capturedStdout,
                stderr: capturedStderr,
                error: error
            )
        }

        process.waitUntilExit()
        progressController?.append("TotalSegmentator finished with status \(process.terminationStatus). Validating outputs…")

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

    /// Check if a Python module is available in the given environment.
    ///
    /// - Parameters:
    ///   - moduleName: Name of the Python module to check
    ///   - resolution: The executable resolution to use
    /// - Returns: True if the module is available
    func pythonModuleAvailable(_ moduleName: String, using resolution: ExecutableResolution) -> Bool {
        let process = Process()
        process.executableURL = resolution.executableURL
        process.arguments = resolution.leadingArguments + ["-c", "import \(moduleName)"]

        var environment = ProcessInfo.processInfo.environment
        if let baseEnvironment = resolution.environment {
            environment.merge(baseEnvironment) { _, new in new }
        }
        process.environment = environment

        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
