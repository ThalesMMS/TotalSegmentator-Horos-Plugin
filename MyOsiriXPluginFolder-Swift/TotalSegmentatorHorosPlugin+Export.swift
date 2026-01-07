//
// TotalSegmentatorHorosPlugin+Export.swift
// TotalSegmentator
//

import Cocoa

extension TotalSegmentatorHorosPlugin {
    func exportActiveSeries(from viewer: ViewerController) throws -> ExportResult {
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

        guard let series = viewer.imageView()?.seriesObj() as? DicomSeries else {
            throw ActiveSeriesExportError.missingSeries
        }

        let rawModality = (series.modality as String?) ?? (series.value(forKey: "modality") as? String)
        let normalizedModality = rawModality?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased()

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

    func cleanupTemporaryDirectory(_ url: URL) {
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
}
