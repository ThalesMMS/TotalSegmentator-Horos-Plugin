//
// TotalSegmentatorHorosPlugin+Import.swift
// TotalSegmentator
//

import Cocoa
import CoreData

extension TotalSegmentatorHorosPlugin {
    func integrateSegmentationOutput(
        at url: URL,
        outputType: SegmentationOutputType,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        progressController: SegmentationProgressWindowController?
    ) throws -> SegmentationImportResult {
        let normalizedOutput = outputType.description.uppercased()
        progressController?.append("Importing TotalSegmentator outputs (\(normalizedOutput))…")
        let importResult: SegmentationImportResult
        let auditOutputType: SegmentationOutputType
        let convertedFromNifti: Bool

        switch outputType {
        case .dicom:
            importResult = try importDicomOutputs(from: url)
            auditOutputType = .dicom
            convertedFromNifti = false
        case .nifti:
            let convertedDirectory = try convertNiftiOutputsToDicom(
                from: url,
                exportContext: exportContext,
                preferences: preferences,
                executable: executable,
                progressController: progressController
            )
            importResult = try importDicomOutputs(from: convertedDirectory)
            auditOutputType = .dicom
            convertedFromNifti = true
        case .other(let value):
            throw SegmentationPostProcessingError.unsupportedOutputType(value)
        }

        progressController?.append("Preparing ROI overlays for visualization…")
        updateVisualization(
            with: importResult,
            exportContext: exportContext,
            preferences: preferences,
            progressController: progressController
        )
        persistAuditMetadata(
            for: importResult,
            exportContext: exportContext,
            outputDirectory: url,
            preferences: preferences,
            outputType: auditOutputType,
            executable: executable,
            convertedFromNifti: convertedFromNifti
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
        var importedIDSet = Set<NSManagedObjectID>()
        var importError: Error?

        DispatchQueue.main.sync {
            guard let database = BrowserController.currentBrowser()?.database else {
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
                importedIDSet.formUnion(result)
            }

            if !rtStructPaths.isEmpty,
               let additionalIDs = database.addFiles(
                   atPaths: rtStructPaths,
                   postNotifications: true,
                   dicomOnly: true,
                   rereadExistingItems: true,
                   generatedByOsiriX: true,
                   returnArray: true
               ) as? [NSManagedObjectID] {
                for identifier in additionalIDs where !importedIDSet.contains(identifier) {
                    importedObjectIDs.append(identifier)
                    importedIDSet.insert(identifier)
                }
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

    private struct NiftiConversionManifest: Decodable {
        let rtStructPaths: [String]
        let dicomSeriesDirectories: [String]
    }

    private func convertNiftiOutputsToDicom(
        from directory: URL,
        exportContext: ExportResult,
        preferences: SegmentationPreferences.State,
        executable: ExecutableResolution,
        progressController: SegmentationProgressWindowController?
    ) throws -> URL {
        guard let referenceSeries = exportContext.series.first else {
            throw NiftiConversionError.missingReferenceSeries
        }

        let fileManager = FileManager.default
        let conversionDirectory = directory.appendingPathComponent("dicom_conversion", isDirectory: true)

        if !fileManager.fileExists(atPath: conversionDirectory.path) {
            try fileManager.createDirectory(at: conversionDirectory, withIntermediateDirectories: true)
        }

        let scriptURL = try prepareNiftiConversionScript(at: directory)
        let configurationURL = try writeNiftiConversionConfiguration(
            to: directory,
            niftiDirectory: directory,
            referenceDirectory: referenceSeries.exportedDirectory,
            outputDirectory: conversionDirectory,
            preferences: preferences
        )

        let result = runPythonProcess(
            using: executable,
            arguments: [scriptURL.path, "--config", configurationURL.path],
            progressController: progressController
        )

        if let error = result.error {
            throw error
        }

        if result.terminationStatus != 0 {
            let stderrString = String(data: result.stderr, encoding: .utf8) ?? ""
            throw NiftiConversionError.scriptFailed(
                status: result.terminationStatus,
                stderr: stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard let stdoutString = String(data: result.stdout, encoding: .utf8) else {
            throw NiftiConversionError.responseParsingFailed
        }

        let meaningfulLines = stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let lastLine = meaningfulLines.last,
              let manifestData = lastLine.data(using: .utf8) else {
            throw NiftiConversionError.responseParsingFailed
        }

        let manifest = try JSONDecoder().decode(NiftiConversionManifest.self, from: manifestData)

        if manifest.rtStructPaths.isEmpty && manifest.dicomSeriesDirectories.isEmpty {
            throw NiftiConversionError.noOutputsProduced
        }

        progressController?.append("Converted NIfTI segmentation output to DICOM-compatible artifacts.")
        logToConsole("Converted NIfTI segmentation output to DICOM-compatible artifacts at \(conversionDirectory.path)")

        return conversionDirectory
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
            guard let database = BrowserController.currentBrowser()?.database else {
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
        preferences: SegmentationPreferences.State,
        progressController: SegmentationProgressWindowController?
    ) {
        guard importResult.outputType == .dicom, !importResult.rtStructPaths.isEmpty else {
            return
        }

        if preferences.hideROIs {
            DispatchQueue.main.async {
                progressController?.append("Skipping ROI overlay display per preferences.")
            }
            return
        }

        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            progressController?.append("Applying RT Struct overlays to the active viewer…")

            guard let browser = BrowserController.currentBrowser() else {
                progressController?.append("Unable to locate the Horos browser to update the viewer.")
                semaphore.signal()
                return
            }

            let viewer = ViewerController.frontMostDisplayed2DViewer() ?? self.openViewer(for: exportContext, browser: browser)

            guard let activeViewer = viewer else {
                progressController?.append("Unable to open a viewer for RT Struct overlay.")
                semaphore.signal()
                return
            }

            var appliedOverlayCount = 0
            for path in importResult.rtStructPaths {
                if self.applyRTStructOverlay(from: path, to: activeViewer) {
                    appliedOverlayCount += 1
                } else {
                    let filename = URL(fileURLWithPath: path).lastPathComponent
                    progressController?.append("Failed to apply RT Struct overlay from \(filename).")
                    self.logToConsole("Failed to apply RT Struct overlay from \(path)")
                }
            }

            if appliedOverlayCount == 0 {
                progressController?.append("No RT Struct overlays could be applied to the active viewer.")
                semaphore.signal()
                return
            }

            progressController?.append("Waiting for Horos to finish converting RT Struct overlays into ROIs…")
            let importedObjectIDs = importResult.importedObjectIDs

            DispatchQueue.global(qos: .userInitiated).async {
                let conversionCompleted = self.waitForRTStructConversionsToFinish(progressController: progressController)

                DispatchQueue.main.async {
                    if conversionCompleted {
                        self.reloadROIs(in: activeViewer)
                        self.persistROIs(from: activeViewer)

                        if let database = browser.database,
                           let importedObjects = database.objects(withIDs: importedObjectIDs) as? [NSManagedObject] {
                            let importedSeries = importedObjects.compactMap { $0 as? DicomSeries }
                            let targetSeries = importedSeries.first { series in
                                guard let modality = series.modality else { return false }
                                return modality.uppercased() == "RTSTRUCT"
                            } ?? importedSeries.first

                            if let series = targetSeries, let study = series.study {
                                browser.selectStudy(with: study.objectID)
                            }
                        }

                        activeViewer.refresh()
                        activeViewer.window?.makeKeyAndOrderFront(nil)
                        activeViewer.needsDisplayUpdate()
                        progressController?.append("Applied \(appliedOverlayCount) RT Struct overlay(s) and stored the corresponding ROIs in Horos.")
                    } else {
                        progressController?.append("Timed out while waiting for Horos to finish converting RT Struct overlays.")
                        self.logToConsole("Timed out while waiting for Horos to convert RT Struct overlays.")
                    }

                    semaphore.signal()
                }
            }
        }

        semaphore.wait()
    }

    private func openViewer(for exportContext: ExportResult, browser: BrowserController) -> ViewerController? {
        for exportedSeries in exportContext.series {
            if let viewer = browser.loadSeries(exportedSeries.series, nil, true, keyImagesOnly: false) {
                return viewer
            }
        }

        return nil
    }

    private func applyRTStructOverlay(from path: String, to viewer: ViewerController) -> Bool {
        guard let dcmObject = DCMObject(contentsOfFile: path, decodingPixelData: false) else {
            return false
        }

        if let currentPix = viewer.imageView()?.curDCM {
            currentPix.createROIs(fromRTSTRUCT: dcmObject)
            return true
        }

        if let pixList = viewer.pixList() {
            for case let pix as DCMPix in pixList {
                pix.createROIs(fromRTSTRUCT: dcmObject)
                return true
            }
        }

        let movieCount = Int(viewer.maxMovieIndex())
        if movieCount >= 0 {
            for index in 0...movieCount {
                if let pixList = viewer.pixList(index) {
                    for case let pix as DCMPix in pixList {
                        pix.createROIs(fromRTSTRUCT: dcmObject)
                        return true
                    }
                }
            }
        }

        return false
    }

    private func reloadROIs(in viewer: ViewerController) {
        let maxIndex = Int(viewer.maxMovieIndex())
        if maxIndex >= 0 {
            for index in 0...maxIndex {
                viewer.loadROI(Int(index))
            }
        } else {
            viewer.loadROI(Int(viewer.curMovieIndex()))
        }
    }

    private func waitForRTStructConversionsToFinish(
        progressController: SegmentationProgressWindowController?,
        timeout: TimeInterval = 120
    ) -> Bool {
        guard let manager = ThreadsManager.`default`() else {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let threadObjects = manager.threads() ?? []
            let hasConversion = threadObjects.contains { element in
                guard let thread = element as? Thread, let name = thread.name else { return false }
                return name.contains("Converting RTSTRUCT in ROIs")
            }

            if !hasConversion {
                progressController?.append("ROI conversion completed.")
                return true
            }

            Thread.sleep(forTimeInterval: 0.25)
        }

        return false
    }

    private func persistROIs(from viewer: ViewerController) {
        let maxIndex = Int(viewer.maxMovieIndex())
        if maxIndex >= 0 {
            for index in 0...maxIndex {
                viewer.saveROI(Int(index))
            }
        } else {
            viewer.saveROI(Int(viewer.curMovieIndex()))
        }
    }

    func validateSegmentationOutput(at url: URL) throws {
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

    func translateErrorOutput(_ output: String, status: Int32) -> String {
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
}
