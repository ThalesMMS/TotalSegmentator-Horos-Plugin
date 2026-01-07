//
// Plugin.swift
// TotalSegmentator
//
// Main Horos plugin that exports DICOM series, runs the TotalSegmentator CLI, and imports masks back as overlays.
//
// Thales Matheus Mendonça Santos - November 2025
//

import Cocoa
import CoreData

// Plugin que faz a ponte entre o TotalSegmentator (CLI Python) e o Horos/OsiriX.
// Exporta as series DICOM abertas, executa o modelo e traz as mascaras de volta como overlays.

/// Implementacao principal do filtro Horos.
/// Orquestra exportacao DICOM, execucao do TotalSegmentator e reimportacao das mascaras.
@objc(TotalSegmentatorHorosPlugin)
class TotalSegmentatorHorosPlugin: PluginFilter {
    @IBOutlet weak var settingsWindow: NSWindow!
    @IBOutlet weak var executablePathField: NSTextField!
    @IBOutlet weak var taskPopupButton: NSPopUpButton!
    @IBOutlet weak var devicePopupButton: NSPopUpButton!
    @IBOutlet weak var fastModeCheckbox: NSButton!
    @IBOutlet weak var hideROIsCheckbox: NSButton!
    @IBOutlet weak var additionalArgumentsField: NSTextField!
    @IBOutlet weak var licenseKeyField: NSTextField!
    @IBOutlet weak var classSelectionSummaryField: NSTextField!
    @IBOutlet weak var classSelectionButton: NSButton!

    private enum MenuAction: String {
        case showSettings = "TotalSegmentator Settings"
        case runSegmentation = "Run TotalSegmentator"
    }

    let preferences = SegmentationPreferences()
    var progressWindowController: SegmentationProgressWindowController?
    var setupProgressWindowController: SegmentationProgressWindowController?
    let auditQueue = DispatchQueue(label: "org.totalsegmentator.horos.audit", qos: .utility)
    var classSelectionController: ClassSelectionWindowController?
    var runConfigurationController: RunSegmentationWindowController?
    var availableClassOptionsCache: [String: [String]] = [:]
    var selectedClassNames: Set<String> = [] {
        didSet { updateClassSelectionSummary() }
    }

    let taskOptions: [(title: String, value: String?)] = [
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

    let deviceOptions: [(title: String, value: String?)] = [
        (NSLocalizedString("Auto", comment: "Automatic device selection"), nil),
        ("cpu", "cpu"),
        ("gpu", "gpu"),
        ("mps", "mps")
    ]

    // Entrada principal chamada pelo Horos ao clicar nos itens de menu do plugin.
    override func filterImage(_ menuName: String!) -> Int {
        logToConsole("filterImage invoked for menu action: \(menuName ?? "nil")")
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

    override func initPlugin() {
        let bundle = Bundle(identifier: "com.totalsegmentator.horosplugin")
        bundle?.loadNibNamed("Settings", owner: self, topLevelObjects: nil)
        settingsWindow?.delegate = self
        configureSettingsInterfaceIfNeeded()

        let persistedSelection = Set(preferences.effectivePreferences().selectedClassNames)
        selectedClassNames = persistedSelection
        updateClassSelectionSummary()

        NSLog("TotalSegmentatorHorosPlugin loaded and ready.")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performInitialSetupIfNeeded()
        }
    }

    override func isCertifiedForMedicalImaging() -> Bool {
        return true
    }
}
