//
// TotalSegmentatorHorosPlugin+Audit.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    func persistAuditMetadata(
        for importResult: SegmentationImportResult,
        exportContext: ExportResult,
        outputDirectory: URL,
        preferences: SegmentationPreferences.State,
        outputType: SegmentationOutputType,
        executable: ExecutableResolution,
        convertedFromNifti: Bool
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
                series: seriesInfo,
                convertedFromNifti: convertedFromNifti
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
}
