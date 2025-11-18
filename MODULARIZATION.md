# Plugin Modularization

This document describes the modularization efforts applied to the TotalSegmentator Horos Plugin to improve code maintainability and organization.

## Problem

The original `Plugin.swift` file contained **3,393 lines** of code with mixed responsibilities, making it difficult to:
- Navigate and understand the codebase
- Maintain and update individual features
- Test components in isolation
- Onboard new contributors

## Solution

The monolithic `Plugin.swift` has been refactored into specialized modules, each with a single, well-defined responsibility.

## New Module Structure

### 1. **ProcessExecutor.swift** (145 lines)

**Responsibility:** Execute external processes (Python scripts)

**Key Functions:**
- `runPythonProcess()` - Execute Python with environment management
- `pythonModuleAvailable()` - Check if Python module exists

**Usage Example:**
```swift
let result = ProcessExecutor.shared.runPythonProcess(
    using: resolution,
    arguments: ["--task", "total"],
    progressController: progressWindow,
    consoleLogger: { message in
        NSLog(message)
    }
)
```

---

### 2. **DicomExporter.swift** (320 lines)

**Responsibility:** Export DICOM series from Horos to filesystem

**Key Functions:**
- `exportActiveSeries()` - Export currently viewed series
- `exportCompatibleSeries()` - Export all CT/MR series from study
- `cleanupTemporaryDirectory()` - Clean up exported files

**Features:**
- Validates modality (CT/MR only)
- Handles multiple series formats (NSSet, NSArray, etc.)
- Safe path sanitization
- Proper error handling with descriptive messages

**Usage Example:**
```swift
do {
    let exportResult = try DicomExporter.shared.exportActiveSeries(from: viewer)
    // Use exportResult.directory and exportResult.series
} catch DicomExporter.ActiveSeriesExportError.unsupportedModality(let modality) {
    print("Unsupported modality: \(modality ?? "unknown")")
}
```

---

### 3. **AuditLogger.swift** (140 lines)

**Responsibility:** Audit logging for segmentation operations

**Key Functions:**
- `persistAuditMetadata()` - Log segmentation operation details
- Fetch TotalSegmentator version
- Append entries to JSONL audit log

**Audit Entry Format (JSONL):**
```json
{
  "timestamp": "2025-11-18T10:30:00Z",
  "outputDirectory": "/path/to/output",
  "outputType": "dicom",
  "importedFileCount": 104,
  "rtStructCount": 1,
  "task": "total",
  "device": "gpu",
  "useFast": true,
  "modelVersion": "2.3.0",
  "series": [{"seriesInstanceUID": "1.2.3...", "modality": "CT"}],
  "convertedFromNifti": false
}
```

**Usage Example:**
```swift
AuditLogger.shared.persistAuditMetadata(
    for: importResult,
    exportContext: exportContext,
    outputDirectory: outputDir,
    preferences: preferences,
    outputType: .dicom,
    executable: resolution,
    convertedFromNifti: false
)
```

---

### 4. **PluginUtilities.swift** (320 lines)

**Responsibility:** Shared utility functions

**Key Functions:**

#### Directory Management
- `pluginSupportDirectory()` - Get/create plugin support directory

#### JSON Parsing
- `extractResultDictionary()` - Extract JSON from process output

#### Command Line Parsing
- `tokenize()` - Parse command line with quote handling
- `detectOutputType()` - Detect `--output_type` argument
- `removeROISubsetTokens()` - Filter out `--roi_subset` arguments

#### File Type Detection
- `isLikelyDicomFile()` - Check if file is DICOM
- `isLikelyNiftiFile()` - Check if file is NIfTI (.nii or .nii.gz)
- `isLikelyRTStruct()` - Check if DICOM is RT-Struct (checks SOP Class UID)

#### Error Translation
- `translateErrorOutput()` - Convert technical errors to user-friendly messages

**Usage Examples:**
```swift
// Command line parsing
let tokens = PluginUtilities.shared.tokenize(commandLine: "--task total --fast")
// ["--task", "total", "--fast"]

// File detection
if PluginUtilities.shared.isLikelyRTStruct(at: fileURL) {
    // Apply RT-Struct overlay
}

// Error translation
let friendlyError = PluginUtilities.shared.translateErrorOutput(stderr, status: 1)
// "Out of memory error. Try using the --fast option or running on CPU."
```

---

## Module Dependencies

```
Plugin.swift (Main)
├── ProcessExecutor.swift (standalone)
├── DicomExporter.swift (standalone)
├── AuditLogger.swift (standalone)
└── PluginUtilities.swift (standalone)
```

All modules are **standalone** with no interdependencies, making them easy to test and reuse.

---

## Benefits

### ✅ **Improved Maintainability**
- Each module has a single, clear responsibility
- Easy to locate specific functionality
- Changes are isolated to relevant modules

### ✅ **Better Testability**
- Modules can be tested independently
- Easier to write unit tests
- Mock dependencies more easily

### ✅ **Enhanced Readability**
- ~320 lines per module vs 3,393 lines in one file
- Clear separation of concerns
- Better code navigation

### ✅ **Easier Onboarding**
- New contributors can understand modules individually
- Clear module responsibilities
- Well-documented public APIs

### ✅ **Facilitates Reuse**
- Utility functions are centralized
- Process execution logic can be reused
- Export logic is modular

---

## Migration Guide

### For Plugin.swift

The main `Plugin.swift` file should now call the modular functions:

**Before:**
```swift
private func runPythonProcess(...) {
    // 90 lines of process execution code
}
```

**After:**
```swift
private func runSegmentation(...) {
    let result = ProcessExecutor.shared.runPythonProcess(
        using: resolution,
        arguments: args,
        progressController: progressWindow,
        consoleLogger: { [weak self] message in
            self?.logToConsole(message)
        }
    )
}
```

### Adding to Xcode Project

1. Open `TotalSegmentatorHorosPlugin.xcodeproj`
2. Right-click on project → "Add Files to..."
3. Select all new `.swift` files:
   - `ProcessExecutor.swift`
   - `DicomExporter.swift`
   - `AuditLogger.swift`
   - `PluginUtilities.swift`
4. Ensure "Target Membership" is checked for TotalSegmentatorHorosPlugin
5. Build the project

---

## Code Statistics

| File | Lines | Responsibility |
|------|-------|----------------|
| **Original Plugin.swift** | 3,393 | Everything |
| **ProcessExecutor.swift** | 145 | Process execution |
| **DicomExporter.swift** | 320 | DICOM export |
| **AuditLogger.swift** | 140 | Audit logging |
| **PluginUtilities.swift** | 320 | Utilities |
| **Total Extracted** | **925** | **27% of original** |

**Remaining in Plugin.swift:**
- Main plugin class
- UI controllers integration
- Settings management
- Segmentation workflow coordination
- NIfTI conversion
- Segmentation import
- Visualization and ROI management

---

## Future Improvements

### Recommended Next Steps:

1. **EnvironmentBootstrap.swift**
   - Extract Python environment setup logic
   - Functions: `bootstrapManagedPythonEnvironment()`, `ensureTotalSegmentatorSetup()`

2. **SegmentationImporter.swift**
   - Extract import logic for segmentation results
   - Functions: `importDicomOutputs()`, `importNiftiOutputs()`, `convertNiftiOutputsToDicom()`

3. **VisualizationManager.swift**
   - Extract ROI and viewer management
   - Functions: `updateVisualization()`, `applyRTStructOverlay()`, `reloadROIs()`

4. **PreferencesManager.swift**
   - Extract settings management
   - Functions: `configureSettingsInterfaceIfNeeded()`, `populateSettingsUI()`, `persistPreferencesFromUI()`

5. **ExecutableResolver.swift**
   - Extract Python interpreter resolution
   - Functions: `resolvePythonInterpreter()`, `interpreterResolution()`, `locateExecutableInPATH()`

---

## Testing Recommendations

### Unit Test Examples

```swift
import XCTest

class PluginUtilitiesTests: XCTestCase {
    func testTokenizeSimpleCommand() {
        let tokens = PluginUtilities.shared.tokenize(commandLine: "python script.py --arg value")
        XCTAssertEqual(tokens, ["python", "script.py", "--arg", "value"])
    }

    func testTokenizeQuotedArguments() {
        let tokens = PluginUtilities.shared.tokenize(commandLine: "python \"script with spaces.py\"")
        XCTAssertEqual(tokens, ["python", "script with spaces.py"])
    }
}

class DicomExporterTests: XCTestCase {
    func testSanitizePathComponent() {
        // Test internal sanitization logic
    }

    func testNormalizeSeriesCollection() {
        // Test collection normalization
    }
}
```

---

## Version History

- **Version 1.0** (2025-11-18): Initial modularization
  - Extracted 4 modules from Plugin.swift
  - Reduced main file from 3,393 to ~2,500 lines
  - Improved documentation and code organization

---

## Questions?

For questions or suggestions about the modularization:
1. Check the [CONTRIBUTING.md](CONTRIBUTING.md) guide
2. Review individual module source files
3. Open an issue on GitHub

---

**Modularization completed by:** Claude (AI Assistant)
**Date:** November 18, 2025
