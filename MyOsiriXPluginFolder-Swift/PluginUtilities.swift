import Foundation

// MARK: - Plugin Utilities Module

/// Utility functions for the TotalSegmentator plugin.
final class PluginUtilities {

    // MARK: - Singleton

    static let shared = PluginUtilities()

    private init() {}

    // MARK: - Directory Management

    /// Get the plugin support directory, creating it if necessary.
    func pluginSupportDirectory() -> URL? {
        guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = supportDir.appendingPathComponent("TotalSegmentatorHorosPlugin", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                NSLog("[TotalSegmentator] Failed to create plugin support directory: \(error.localizedDescription)")
                return nil
            }
        }
        return directory
    }

    // MARK: - JSON Parsing

    /// Extract a result dictionary from process output data.
    ///
    /// Looks for lines starting with `__RESULT__` followed by JSON data.
    ///
    /// - Parameter data: Output data from a process
    /// - Returns: Parsed dictionary if found, nil otherwise
    func extractResultDictionary(from data: Data) -> [String: Any]? {
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

    // MARK: - Command Line Parsing

    /// Tokenize a command line string, respecting quotes and escapes.
    ///
    /// - Parameter commandLine: Command line string to tokenize
    /// - Returns: Array of tokens
    func tokenize(commandLine: String) -> [String] {
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

    /// Detect output type from command line tokens.
    ///
    /// - Parameter tokens: Command line tokens
    /// - Returns: Tuple with detected type and remaining tokens
    func detectOutputType(from tokens: [String]) -> (type: SegmentationOutputType, remainingTokens: [String]) {
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

    /// Remove ROI subset tokens from command line tokens.
    ///
    /// - Parameter tokens: Command line tokens
    /// - Returns: Filtered tokens without --roi_subset arguments
    func removeROISubsetTokens(from tokens: [String]) -> [String] {
        var filtered: [String] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            if token == "--roi_subset" {
                let nextIndex = index + 1
                if nextIndex < tokens.count && !tokens[nextIndex].hasPrefix("--") {
                    index += 2
                    continue
                }

                index += 1
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

    // MARK: - File Type Detection

    /// Check if a file is likely a DICOM file.
    ///
    /// - Parameter url: URL of the file to check
    /// - Returns: True if file is likely DICOM
    func isLikelyDicomFile(at url: URL) -> Bool {
        if DicomFile.isDICOMFile(url.path) {
            return true
        }

        let ext = url.pathExtension.lowercased()
        return ext == "dcm" || ext == "dicom"
    }

    /// Check if a file is likely a NIfTI file.
    ///
    /// - Parameter url: URL of the file to check
    /// - Returns: True if file is likely NIfTI
    func isLikelyNiftiFile(at url: URL) -> Bool {
        if DicomFile.isNIfTIFile(url.path) {
            return true
        }

        let lowercased = url.lastPathComponent.lowercased()
        return lowercased.hasSuffix(".nii") || lowercased.hasSuffix(".nii.gz")
    }

    /// Check if a DICOM file is likely an RT-Struct.
    ///
    /// - Parameter url: URL of the DICOM file
    /// - Returns: True if file is likely an RT-Struct
    func isLikelyRTStruct(at url: URL) -> Bool {
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

            // Check SOP Class UID for RT Structure Set
            if let sopClassUID = elements["SOPClassUID"] as? String,
               sopClassUID == "1.2.840.10008.5.1.4.1.1.481.3" {
                return true
            }

            // Check modality
            if let modality = (elements["Modality"] ?? elements["modality"]) as? String,
               modality.uppercased() == "RTSTRUCT" {
                return true
            }

            // Check series description
            if let description = (elements["SeriesDescription"] ?? elements["seriesDescription"]) as? String {
                let normalized = description.lowercased()
                if normalized.contains("rtstruct") || normalized.contains("rt struct") {
                    return true
                }
            }

            return false
        })

        return dicomIndicatesRTStruct
    }

    // MARK: - Error Translation

    /// Translate TotalSegmentator error output into user-friendly messages.
    ///
    /// - Parameters:
    ///   - output: Error output from TotalSegmentator
    ///   - status: Process termination status
    /// - Returns: Translated error message
    func translateErrorOutput(_ output: String, status: Int32) -> String {
        let lowercased = output.lowercased()

        if lowercased.contains("no such file or directory") || lowercased.contains("filenotfounderror") {
            return "A required file or directory was not found. Please check your input data and TotalSegmentator installation."
        }

        if lowercased.contains("permission denied") {
            return "Permission denied while accessing files. Please check file permissions."
        }

        if lowercased.contains("out of memory") || lowercased.contains("cuda out of memory") {
            return "Out of memory error. Try using the --fast option or running on CPU."
        }

        if lowercased.contains("no module named") {
            let moduleName = extractModuleName(from: output)
            return "Python module '\(moduleName ?? "unknown")' not found. Please ensure TotalSegmentator is properly installed."
        }

        if lowercased.contains("license") {
            return "License error. Some TotalSegmentator tasks require a valid license. Visit https://backend.totalsegmentator.com/license-academic/ for more information."
        }

        if status == -1 {
            return "Failed to start the TotalSegmentator process. Please check your Python installation."
        }

        return output
    }

    // MARK: - Logging

    /// Log a message to the console.
    ///
    /// - Parameter message: Message to log
    func logToConsole(_ message: String) {
        NSLog("[TotalSegmentator] %@", message)
    }

    // MARK: - Private Helpers

    /// Extract module name from Python import error.
    private func extractModuleName(from error: String) -> String? {
        let pattern = "No module named ['\"]([^'\"]+)['\"]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsString = error as NSString
        let results = regex.matches(in: error, options: [], range: NSRange(location: 0, length: nsString.length))

        guard let match = results.first, match.numberOfRanges > 1 else {
            return nil
        }

        let range = match.range(at: 1)
        return nsString.substring(with: range)
    }
}
