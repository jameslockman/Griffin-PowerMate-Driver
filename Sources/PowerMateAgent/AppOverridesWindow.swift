import Foundation
import AppKit

// MARK: - Configure Applications window
//
// Lets the user add specific applications and give each one its own fully independent
// settings (mode + the behavior details within that mode), overriding the global defaults
// only while that app is frontmost.

private let kAppCellIdentifier = NSUserInterfaceItemIdentifier("AppOverrideCell")

final class AppOverridesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var bundleIDs: [String] = []

    private let tableView   = NSTableView()
    private let addButton   = NSButton()
    private let removeButton = NSButton()

    private let appNameLabel = NSTextField(labelWithString: "Select an app, or click + to add one.")
    private let modeLabel    = NSTextField(labelWithString: "Mode:")
    private let modePopup    = NSPopUpButton()

    private let scrollReversedCheck    = NSButton(checkboxWithTitle: "Reverse scroll direction", target: nil, action: nil)
    private let fineScrollCheck        = NSButton(checkboxWithTitle: "Prefer fine scrolling", target: nil, action: nil)
    private let scrollAxesSwappedCheck = NSButton(checkboxWithTitle: "Default to horizontal scroll", target: nil, action: nil)

    private let audioStepSwappedCheck = NSButton(checkboxWithTitle: "Prefer fine volume", target: nil, action: nil)

    private let configureKeysButton = NSButton(title: "Configure Keys...", target: nil, action: nil)

    // Click, Double-click, and Long press are all orthogonal to mode, so they're always visible
    // (not hidden per-mode like the controls above). Presented as hierarchical pop-ups (Toggle
    // Mode and Custom Keypress are effectively "sub-actions"), matching the status-bar menu.
    private let clickActionLabel = NSTextField(labelWithString: "Click:")
    private let clickActionPopup = NSPopUpButton()
    private var clickActionMenuItems: [NSMenuItem] = []
    private var clickCustomMenuItem: NSMenuItem!

    private let doubleClickActionLabel = NSTextField(labelWithString: "Double-click:")
    private let doubleClickActionPopup = NSPopUpButton()
    private var doubleClickActionMenuItems: [NSMenuItem] = []
    private var doubleClickCustomMenuItem: NSMenuItem!

    private let longPressLabel = NSTextField(labelWithString: "Long press:")
    private let longPressPopup = NSPopUpButton()
    private var longPressMenuItems: [NSMenuItem] = []
    private var longPressCustomMenuItem: NSMenuItem!

    // Only shown when this app's long press is set to "Run Script" — lets this app run a
    // different script than the global default (set via the main "Configure Scripts...").
    private let configureScriptButton = NSButton(title: "Configure Script...", target: nil, action: nil)

    private let instructionsLabel = NSTextField(wrappingLabelWithString: "")
    private let noSelectionInstructions =
        "Add an app with the + button, or select one from the list, to configure its mode " +
        "and behavior."
    private let selectedAppInstructions =
        "Pick a mode above, then use the controls that appear for it (scroll options, " +
        "audio options, or key bindings) to configure that mode's behavior for this app. " +
        "Click, Double-click, and Long press apply the same regardless of mode. Long press " +
        "can optionally be set to \"Toggle Mode\" so you can swap between two modes on the " +
        "fly, without reopening this window."

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Configure Applications for PowerMate"
        window.minSize = NSSize(width: 540, height: 480)
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
        reloadList()
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Left column: app list + add/remove.
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 48, width: 200, height: 496))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.borderType          = .bezelBorder
        scrollView.autoresizingMask    = [.height]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("App"))
        column.width = 180
        tableView.addTableColumn(column)
        tableView.headerView   = nil
        tableView.dataSource   = self
        tableView.delegate     = self
        tableView.rowHeight    = 22
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        addButton.frame  = NSRect(x: 16, y: 16, width: 28, height: 24)
        addButton.title  = "+"
        addButton.target = self
        addButton.action = #selector(addApp)
        contentView.addSubview(addButton)

        removeButton.frame  = NSRect(x: 46, y: 16, width: 28, height: 24)
        removeButton.title  = "–"
        removeButton.target = self
        removeButton.action = #selector(removeApp)
        contentView.addSubview(removeButton)

        // Right column: selected app's settings.
        let rightX: CGFloat = 232
        let rightW: CGFloat = 392

        appNameLabel.font  = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        appNameLabel.frame = NSRect(x: rightX, y: 525, width: rightW, height: 20)
        appNameLabel.autoresizingMask = [.width]
        contentView.addSubview(appNameLabel)

        modeLabel.frame = NSRect(x: rightX, y: 487, width: 44, height: 24)
        contentView.addSubview(modeLabel)

        modePopup.frame = NSRect(x: rightX + 48, y: 485, width: 150, height: 26)
        for mode in RotationMode.allCases {
            modePopup.addItem(withTitle: title(for: mode))
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        contentView.addSubview(modePopup)

        let separator = NSBox(frame: NSRect(x: rightX, y: 472, width: rightW, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        contentView.addSubview(separator)

        // Scroll-mode controls.
        scrollReversedCheck.frame    = NSRect(x: rightX, y: 434, width: rightW, height: 20)
        fineScrollCheck.frame        = NSRect(x: rightX, y: 406, width: rightW, height: 20)
        scrollAxesSwappedCheck.frame = NSRect(x: rightX, y: 378, width: rightW, height: 20)
        for c in [scrollReversedCheck, fineScrollCheck, scrollAxesSwappedCheck] {
            c.target = self
            c.action = #selector(settingChanged)
            contentView.addSubview(c)
        }

        // Audio-mode controls. (Click is no longer audio-specific — see the always-visible
        // Click/Double-click section below.)
        audioStepSwappedCheck.frame = NSRect(x: rightX, y: 434, width: rightW, height: 20)
        audioStepSwappedCheck.target = self
        audioStepSwappedCheck.action = #selector(settingChanged)
        contentView.addSubview(audioStepSwappedCheck)

        // Keypress-mode controls.
        configureKeysButton.frame  = NSRect(x: rightX, y: 434, width: 150, height: 24)
        configureKeysButton.target = self
        configureKeysButton.action = #selector(configureKeys)
        contentView.addSubview(configureKeysButton)

        // Click/Double-click (always visible, independent of mode).
        let clickActionsSeparator = NSBox(frame: NSRect(x: rightX, y: 357, width: rightW, height: 1))
        clickActionsSeparator.boxType = .separator
        clickActionsSeparator.autoresizingMask = [.width]
        contentView.addSubview(clickActionsSeparator)

        let clickLabelWidth: CGFloat = 100
        let clickPopupX = rightX + clickLabelWidth + 8

        clickActionLabel.frame = NSRect(x: rightX, y: 319, width: clickLabelWidth, height: 24)
        contentView.addSubview(clickActionLabel)

        clickActionPopup.frame = NSRect(x: clickPopupX, y: 317, width: rightX + rightW - clickPopupX, height: 26)
        clickActionPopup.menu = buildClickActionMenu()
        clickActionPopup.target = self
        clickActionPopup.action = #selector(clickActionChanged)
        contentView.addSubview(clickActionPopup)

        doubleClickActionLabel.frame = NSRect(x: rightX, y: 283, width: clickLabelWidth, height: 24)
        contentView.addSubview(doubleClickActionLabel)

        doubleClickActionPopup.frame = NSRect(x: clickPopupX, y: 281, width: rightX + rightW - clickPopupX, height: 26)
        doubleClickActionPopup.menu = buildDoubleClickActionMenu()
        doubleClickActionPopup.target = self
        doubleClickActionPopup.action = #selector(doubleClickActionChanged)
        contentView.addSubview(doubleClickActionPopup)

        // Long press (always visible, independent of mode).
        let longPressSeparator = NSBox(frame: NSRect(x: rightX, y: 266, width: rightW, height: 1))
        longPressSeparator.boxType = .separator
        longPressSeparator.autoresizingMask = [.width]
        contentView.addSubview(longPressSeparator)

        longPressLabel.frame = NSRect(x: rightX, y: 232, width: 80, height: 24)
        contentView.addSubview(longPressLabel)

        longPressPopup.frame = NSRect(x: rightX, y: 202, width: rightW, height: 26)
        longPressPopup.menu = buildLongPressMenu()
        // Target/action on the button itself (not on individual items) so NSPopUpButton's
        // own selection tracking updates the displayed title — same pattern as modePopup.
        longPressPopup.target = self
        longPressPopup.action = #selector(longPressChanged)
        contentView.addSubview(longPressPopup)

        // Only visible when this app's long press is "Run Script" — see updateDetailPane.
        configureScriptButton.frame = NSRect(x: rightX, y: 174, width: 220, height: 24)
        configureScriptButton.target = self
        configureScriptButton.action = #selector(configureAppScript)
        contentView.addSubview(configureScriptButton)

        // Instructions (always visible — a quick reminder of how mode + long press interact).
        let instructionsSeparator = NSBox(frame: NSRect(x: rightX, y: 170, width: rightW, height: 1))
        instructionsSeparator.boxType = .separator
        instructionsSeparator.autoresizingMask = [.width]
        contentView.addSubview(instructionsSeparator)

        instructionsLabel.frame = NSRect(x: rightX, y: 16, width: rightW, height: 146)
        instructionsLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        instructionsLabel.textColor = .secondaryLabelColor
        instructionsLabel.autoresizingMask = [.width]
        contentView.addSubview(instructionsLabel)

        updateDetailPane()
    }

    /// Builds the Long press pop-up's menu. Flat (no nested submenu) — NSPopUpButton's
    /// automatic selection tracking, which is what keeps the button's displayed title in
    /// sync with the chosen item, isn't reliable for items inside a nested submenu. The
    /// main status-bar menu's "Long press" submenu (a real NSMenu, not a pop-up button) does
    /// use a nested "Toggle Mode" submenu, since that one doesn't have this limitation.
    private func buildLongPressMenu() -> NSMenu {
        let menu = NSMenu()
        addLongPressItem("Right-click", .rightClick, to: menu)
        addLongPressItem("Left-click", .leftClick, to: menu)
        addLongPressItem("Double-click", .doubleClick, to: menu)
        menu.addItem(.separator())
        addLongPressItem("Toggle Mode: \(ModeTogglePair.audioScroll.title)", .toggleMode(.audioScroll), to: menu)
        addLongPressItem("Toggle Mode: \(ModeTogglePair.audioKeypress.title)", .toggleMode(.audioKeypress), to: menu)
        addLongPressItem("Toggle Mode: \(ModeTogglePair.scrollKeypress.title)", .toggleMode(.scrollKeypress), to: menu)
        menu.addItem(.separator())
        addLongPressItem("Toggle fine/coarse scrolling", .toggleFineScroll, to: menu)
        addLongPressItem("Run Script", .runScript, to: menu)
        let custom = NSMenuItem(title: "Custom Keypress...", action: nil, keyEquivalent: "")
        // Placeholder binding: selecting this item always opens the capture dialog (see
        // longPressChanged), which replaces it with the actually-recorded key before saving.
        custom.representedObject = LongPressAction.custom(KeyBinding(keyCode: kReturnKey, label: ""))
        menu.addItem(custom)
        longPressMenuItems.append(custom)
        longPressCustomMenuItem = custom
        return menu
    }

    private func addLongPressItem(_ title: String, _ action: LongPressAction, to menu: NSMenu) {
        // No target/action here — see the note on longPressPopup.target above.
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = action
        menu.addItem(item)
        longPressMenuItems.append(item)
    }

    /// Same hierarchical pop-up pattern as buildLongPressMenu. "Custom Keypress..." uses a
    /// placeholder binding purely as a marker — clickActionChanged replaces it with the actually
    /// recorded key before saving.
    private func buildClickActionMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: ClickAction) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = action
            menu.addItem(item)
            clickActionMenuItems.append(item)
        }
        add("Left-click", .leftClick)
        add("Right-click", .rightClick)
        add("Mute/Unmute", .mute)
        add("Play/Pause", .playPause)
        let custom = NSMenuItem(title: "Custom Keypress...", action: nil, keyEquivalent: "")
        custom.representedObject = ClickAction.custom(KeyBinding(keyCode: kReturnKey, label: ""))
        menu.addItem(custom)
        clickActionMenuItems.append(custom)
        clickCustomMenuItem = custom
        return menu
    }

    /// Same as buildClickActionMenu, with an added "None" (disabled) option — double-click
    /// defaults to None so it adds no click-detection latency until configured.
    private func buildDoubleClickActionMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: ClickAction) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = action
            menu.addItem(item)
            doubleClickActionMenuItems.append(item)
        }
        add("None", .none)
        add("Left-click", .leftClick)
        add("Right-click", .rightClick)
        add("Mute/Unmute", .mute)
        add("Play/Pause", .playPause)
        let custom = NSMenuItem(title: "Custom Keypress...", action: nil, keyEquivalent: "")
        custom.representedObject = ClickAction.custom(KeyBinding(keyCode: kReturnKey, label: ""))
        menu.addItem(custom)
        doubleClickActionMenuItems.append(custom)
        doubleClickCustomMenuItem = custom
        return menu
    }

    private func title(for mode: RotationMode) -> String {
        switch mode {
        case .scroll:   return "Scroll"
        case .audio:    return "Audio"
        case .keypress: return "Keypress"
        }
    }

    // MARK: - List management

    private func reloadList(selecting bundleIDToSelect: String? = nil) {
        bundleIDs = perAppSettings.keys.sorted {
            displayName(forBundleID: $0).localizedCaseInsensitiveCompare(displayName(forBundleID: $1)) == .orderedAscending
        }
        tableView.reloadData()
        if let target = bundleIDToSelect, let index = bundleIDs.firstIndex(of: target) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateDetailPane()
    }

    private func selectedBundleID() -> String? {
        let row = tableView.selectedRow
        guard row >= 0, row < bundleIDs.count else { return nil }
        return bundleIDs[row]
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        if perAppSettings[bundleID] == nil {
            perAppSettings[bundleID] = AppSettings()
            savePerAppSettings()
        }
        reloadList(selecting: bundleID)
    }

    @objc private func removeApp() {
        guard let bundleID = selectedBundleID() else { return }
        perAppSettings.removeValue(forKey: bundleID)
        savePerAppSettings()
        reloadList()
    }

    // MARK: - Detail pane

    private func setScrollControlsHidden(_ hidden: Bool) {
        for v in [scrollReversedCheck, fineScrollCheck, scrollAxesSwappedCheck] { v.isHidden = hidden }
    }

    private func setAudioControlsHidden(_ hidden: Bool) {
        audioStepSwappedCheck.isHidden = hidden
    }

    private func setKeypressControlsHidden(_ hidden: Bool) {
        configureKeysButton.isHidden = hidden
    }

    private func updateModeSpecificVisibility(_ mode: RotationMode) {
        setScrollControlsHidden(mode != .scroll)
        setAudioControlsHidden(mode != .audio)
        setKeypressControlsHidden(mode != .keypress)
    }

    private func updateDetailPane() {
        guard let bundleID = selectedBundleID(), let settings = perAppSettings[bundleID] else {
            appNameLabel.stringValue = "Select an app, or click + to add one."
            modeLabel.isHidden  = true
            modePopup.isHidden  = true
            setScrollControlsHidden(true)
            setAudioControlsHidden(true)
            setKeypressControlsHidden(true)
            clickActionLabel.isHidden = true
            clickActionPopup.isHidden = true
            doubleClickActionLabel.isHidden = true
            doubleClickActionPopup.isHidden = true
            longPressLabel.isHidden = true
            longPressPopup.isHidden = true
            configureScriptButton.isHidden = true
            instructionsLabel.stringValue = noSelectionInstructions
            return
        }
        appNameLabel.stringValue = displayName(forBundleID: bundleID)
        modeLabel.isHidden = false
        modePopup.isHidden = false
        modePopup.selectItem(at: RotationMode.allCases.firstIndex(of: settings.mode) ?? 0)
        scrollReversedCheck.state    = settings.scrollReversed ? .on : .off
        fineScrollCheck.state        = settings.fineScrollEnabled ? .on : .off
        scrollAxesSwappedCheck.state = settings.scrollAxesSwapped ? .on : .off
        audioStepSwappedCheck.state  = settings.audioStepSwapped ? .on : .off
        updateModeSpecificVisibility(settings.mode)

        clickActionLabel.isHidden = false
        clickActionPopup.isHidden = false
        // clickCustomMenuItem is one shared NSMenuItem reused for every app in the list, so its
        // title must be refreshed for the app being displayed right now — even when that app's
        // action *isn't* custom, where it needs to fall back to the plain "Custom Keypress..."
        // label. Leaving this inside the `.custom` branch only (as before) meant the item kept
        // showing whichever other app's custom key was displayed most recently: e.g. selecting
        // Logic Pro (Custom Keypress: Space) and then Garage Band (Left-click) still showed
        // "Custom Keypress: Space" for Garage Band, even though Garage Band's real setting was
        // untouched — a purely cosmetic staleness bug, but one that looked exactly like Garage
        // Band's click had been silently overwritten with Logic's.
        clickCustomMenuItem.title = customKeypressTitle(settings.clickAction.customBinding)
        if case .custom = settings.clickAction {
            clickActionPopup.select(clickCustomMenuItem)
        } else if let match = clickActionMenuItems.first(where: { ($0.representedObject as? ClickAction) == settings.clickAction }) {
            clickActionPopup.select(match)
        }

        doubleClickActionLabel.isHidden = false
        doubleClickActionPopup.isHidden = false
        doubleClickCustomMenuItem.title = customKeypressTitle(settings.doubleClickAction.customBinding)
        if case .custom = settings.doubleClickAction {
            doubleClickActionPopup.select(doubleClickCustomMenuItem)
        } else if let match = doubleClickActionMenuItems.first(where: { ($0.representedObject as? ClickAction) == settings.doubleClickAction }) {
            doubleClickActionPopup.select(match)
        }

        longPressLabel.isHidden = false
        longPressPopup.isHidden = false
        longPressCustomMenuItem.title = customKeypressTitle(settings.longPressAction.customBinding)
        if case .custom = settings.longPressAction {
            longPressPopup.select(longPressCustomMenuItem)
        } else if let match = longPressMenuItems.first(where: { ($0.representedObject as? LongPressAction) == settings.longPressAction }) {
            longPressPopup.select(match)
        }
        configureScriptButton.isHidden = settings.longPressAction != .runScript
        configureScriptButton.title = (settings.script1 != nil || settings.script2 != nil)
            ? "Configure Script... (Custom)"
            : "Configure Script... (Default)"

        instructionsLabel.stringValue = selectedAppInstructions
    }

    // MARK: - Editing actions

    @objc private func modeChanged() {
        guard let bundleID = selectedBundleID() else { return }
        let mode = RotationMode.allCases[modePopup.indexOfSelectedItem]
        perAppSettings[bundleID]?.mode = mode
        savePerAppSettings()
        updateModeSpecificVisibility(mode)
    }

    @objc private func settingChanged() {
        guard let bundleID = selectedBundleID() else { return }
        perAppSettings[bundleID]?.scrollReversed    = scrollReversedCheck.state == .on
        perAppSettings[bundleID]?.fineScrollEnabled = fineScrollCheck.state == .on
        perAppSettings[bundleID]?.scrollAxesSwapped = scrollAxesSwappedCheck.state == .on
        perAppSettings[bundleID]?.audioStepSwapped  = audioStepSwappedCheck.state == .on
        savePerAppSettings()
    }

    @objc private func clickActionChanged() {
        guard let bundleID = selectedBundleID(),
              let action = clickActionPopup.selectedItem?.representedObject as? ClickAction else { return }
        if case .custom = action {
            // Selecting "Custom Keypress..." always opens the capture dialog; cancelling it
            // reverts the pop-up to whatever was actually selected before.
            guard let binding = showCaptureCustomKeypress(current: perAppSettings[bundleID]?.clickAction.customBinding) else {
                updateDetailPane()
                return
            }
            perAppSettings[bundleID]?.clickAction = .custom(binding)
        } else {
            perAppSettings[bundleID]?.clickAction = action
        }
        savePerAppSettings()
        updateDetailPane()
    }

    @objc private func doubleClickActionChanged() {
        guard let bundleID = selectedBundleID(),
              let action = doubleClickActionPopup.selectedItem?.representedObject as? ClickAction else { return }
        if case .custom = action {
            guard let binding = showCaptureCustomKeypress(current: perAppSettings[bundleID]?.doubleClickAction.customBinding) else {
                updateDetailPane()
                return
            }
            perAppSettings[bundleID]?.doubleClickAction = .custom(binding)
        } else {
            perAppSettings[bundleID]?.doubleClickAction = action
        }
        savePerAppSettings()
        updateDetailPane()
    }

    @objc private func longPressChanged() {
        guard let bundleID = selectedBundleID(),
              let action = longPressPopup.selectedItem?.representedObject as? LongPressAction else { return }
        if case .custom = action {
            guard let binding = showCaptureCustomKeypress(current: perAppSettings[bundleID]?.longPressAction.customBinding) else {
                updateDetailPane()
                return
            }
            perAppSettings[bundleID]?.longPressAction = .custom(binding)
        } else {
            perAppSettings[bundleID]?.longPressAction = action
        }
        savePerAppSettings()
        updateDetailPane()
    }

    @objc private func configureKeys() {
        guard let bundleID = selectedBundleID(), let settings = perAppSettings[bundleID] else { return }
        if let updated = showConfigureKeypressMode(for: settings) {
            perAppSettings[bundleID] = updated
            savePerAppSettings()
        }
    }

    @objc private func configureAppScript() {
        guard let bundleID = selectedBundleID(), let settings = perAppSettings[bundleID] else { return }
        guard let (script1, script2) = showConfigureAppScripts(current1: settings.script1, current2: settings.script2) else { return }
        perAppSettings[bundleID]?.script1 = script1
        perAppSettings[bundleID]?.script2 = script2
        savePerAppSettings()
        updateDetailPane()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { bundleIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bundleID = bundleIDs[row]
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: kAppCellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 180, height: 22))
            cell.identifier = kAppCellIdentifier
            let imageView = NSImageView(frame: NSRect(x: 2, y: 2, width: 18, height: 18))
            imageView.imageScaling = .scaleProportionallyDown
            let textField = NSTextField(labelWithString: "")
            textField.frame = NSRect(x: 24, y: 3, width: 154, height: 16)
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField
        }
        cell.textField?.stringValue = displayName(forBundleID: bundleID)
        cell.imageView?.image = icon(forBundleID: bundleID)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetailPane()
    }
}

private var appOverridesWindowController: AppOverridesWindowController?

func showAppOverridesWindow() {
    let controller = appOverridesWindowController ?? AppOverridesWindowController()
    appOverridesWindowController = controller
    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
}
