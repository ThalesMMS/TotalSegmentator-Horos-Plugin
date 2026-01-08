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
        case toolbarAction = "TotalSegmentator"  // Toolbar button uses this name
    }

    private static let toolbarIdentifier = "TotalSegmentatorToolbarItem"

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
        case .runSegmentation, .toolbarAction:
            startSegmentationFlow()
        }

        return 0
    }

    override func initPlugin() {
        let bundle = Bundle(for: type(of: self))
        bundle.loadNibNamed("Settings", owner: self, topLevelObjects: nil)
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

    // MARK: - Toolbar Support (for roiTool plugin type)

    override func toolbarAllowedIdentifiers(forViewer controller: Any!) -> [Any]! {
        return [Self.toolbarIdentifier]
    }

    override func toolbarItem(forItemIdentifier identifier: String!, forViewer controller: Any!) -> NSToolbarItem! {
        guard identifier == Self.toolbarIdentifier else { return nil }

        let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(identifier))
        item.label = "TotalSegmentator"
        item.paletteLabel = "TotalSegmentator"
        item.toolTip = "Run TotalSegmentator segmentation"
        item.target = self
        item.action = #selector(toolbarButtonClicked(_:))

        // Load icon from bundle
        let bundle = Bundle(for: type(of: self))
        if let iconPath = bundle.path(forResource: "TotalSegmentatorToolbar", ofType: "png"),
           let image = NSImage(contentsOfFile: iconPath) {
            image.size = NSSize(width: 32, height: 32)
            item.image = image
        }

        return item
    }

    @objc private func toolbarButtonClicked(_ sender: Any?) {
        _ = filterImage("TotalSegmentator")
    }
}
