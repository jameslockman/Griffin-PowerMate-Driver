import Foundation
import AppKit

// MARK: - MenuHandler

final class MenuHandler: NSObject, NSMenuDelegate {
    var reverseScrollItem: NSMenuItem!
    var fineScrollItem: NSMenuItem!
    var scrollAxesSwappedItem: NSMenuItem!
    var audioStepSwappedItem: NSMenuItem!
    var scrollModeItem: NSMenuItem!
    var audioControlItem: NSMenuItem!
    var keypressModeItem: NSMenuItem!
    var clickMuteItem: NSMenuItem!
    var clickPlayPauseItem: NSMenuItem!
    var vuMeterItem: NSMenuItem!
    var longPressRightItem: NSMenuItem!
    var longPressLeftItem: NSMenuItem!
    var longPressDoubleItem: NSMenuItem!
    var longPressToggleAudioScrollItem: NSMenuItem!
    var longPressToggleAudioKeypressItem: NSMenuItem!
    var longPressToggleScrollKeypressItem: NSMenuItem!
    var longPressFineScrollItem: NSMenuItem!
    var longPressRunScriptItem: NSMenuItem!

    func updateMenuState() {
        reverseScrollItem.state       = defaultSettings.scrollReversed ? .on : .off
        fineScrollItem.state          = defaultSettings.fineScrollEnabled ? .on : .off
        scrollAxesSwappedItem.state   = defaultSettings.scrollAxesSwapped ? .on : .off
        audioStepSwappedItem.state    = defaultSettings.audioStepSwapped ? .on : .off
        scrollModeItem.state          = defaultSettings.mode == .scroll ? .on : .off
        audioControlItem.state        = defaultSettings.mode == .audio ? .on : .off
        keypressModeItem.state        = defaultSettings.mode == .keypress ? .on : .off
        clickMuteItem.state           = (defaultSettings.clickAction == .mute) ? .on : .off
        clickPlayPauseItem.state      = (defaultSettings.clickAction == .playPause) ? .on : .off
        vuMeterItem.state             = vuMeterEnabled ? .on : .off
        longPressRightItem.state               = (defaultSettings.longPressAction == .rightClick) ? .on : .off
        longPressLeftItem.state                = (defaultSettings.longPressAction == .leftClick) ? .on : .off
        longPressDoubleItem.state              = (defaultSettings.longPressAction == .doubleClick) ? .on : .off
        longPressToggleAudioScrollItem.state    = (defaultSettings.longPressAction == .toggleMode(.audioScroll)) ? .on : .off
        longPressToggleAudioKeypressItem.state  = (defaultSettings.longPressAction == .toggleMode(.audioKeypress)) ? .on : .off
        longPressToggleScrollKeypressItem.state = (defaultSettings.longPressAction == .toggleMode(.scrollKeypress)) ? .on : .off
        longPressFineScrollItem.state           = (defaultSettings.longPressAction == .toggleFineScroll) ? .on : .off
        longPressRunScriptItem.state            = (defaultSettings.longPressAction == .runScript) ? .on : .off
        updateStatusIcon()
        updateDockIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }

    // MARK: - Toggle actions

    @objc func toggleScrollReversed() {
        defaultSettings.scrollReversed.toggle()
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func toggleFineScroll() {
        defaultSettings.fineScrollEnabled.toggle()
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func toggleScrollAxesSwapped() {
        defaultSettings.scrollAxesSwapped.toggle()
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func toggleAudioStepSwapped() {
        defaultSettings.audioStepSwapped.toggle()
        saveDefaultSettings()
        updateMenuState()
    }

    /// Switches the default mode. Scroll/Audio/Keypress are mutually exclusive, so entering
    /// one leaves whichever of the others was active (stopping the audio meter if it was on).
    private func setDefaultMode(_ mode: RotationMode) {
        guard defaultSettings.mode != mode else { return }
        if defaultSettings.mode == .audio { stopAudioMeter() }
        defaultSettings.mode = mode
        if mode == .audio, #available(macOS 14.2, *) { startAudioMeter() }
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func selectScrollMode() {
        let wasAudio = defaultSettings.mode == .audio
        setDefaultMode(.scroll)
        if wasAudio { signalModeChange(toAudio: false) }
    }

    @objc func toggleAudioControl() {
        let goingToAudio = defaultSettings.mode != .audio
        setDefaultMode(goingToAudio ? .audio : .scroll)
        signalModeChange(toAudio: goingToAudio)
    }

    @objc func toggleKeypressMode() {
        setDefaultMode(defaultSettings.mode == .keypress ? .scroll : .keypress)
    }

    @objc func configureKeypressMode() {
        if let updated = showConfigureKeypressMode(for: defaultSettings) {
            defaultSettings = updated
            saveDefaultSettings()
        }
    }

    @objc func configureApplications() {
        showAppOverridesWindow()
    }

    @objc func setClickMute() {
        defaultSettings.clickAction = .mute
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func setClickPlayPause() {
        defaultSettings.clickAction = .playPause
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func toggleVUMeter() {
        vuMeterEnabled.toggle()
        defaults.set(vuMeterEnabled, forKey: kVUMeter)
        if defaultSettings.mode == .audio {
            if vuMeterEnabled {
                if #available(macOS 14.2, *) { startAudioMeter() }
            } else {
                stopAudioMeter()
                setLEDOffMain(80)
            }
        }
        updateMenuState()
    }

    private func setLongPressAction(_ action: LongPressAction) {
        defaultSettings.longPressAction = action
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func setLongPressRightClick()          { setLongPressAction(.rightClick) }
    @objc func setLongPressLeftClick()           { setLongPressAction(.leftClick) }
    @objc func setLongPressDoubleClick()         { setLongPressAction(.doubleClick) }
    @objc func setLongPressToggleAudioScroll()    { setLongPressAction(.toggleMode(.audioScroll)) }
    @objc func setLongPressToggleAudioKeypress()  { setLongPressAction(.toggleMode(.audioKeypress)) }
    @objc func setLongPressToggleScrollKeypress() { setLongPressAction(.toggleMode(.scrollKeypress)) }
    @objc func setLongPressFineScroll()          { setLongPressAction(.toggleFineScroll) }
    @objc func setLongPressRunScript()           { setLongPressAction(.runScript) }

    @objc func configureScripts() {
        showConfigureScripts()
    }

    @objc func openReleasesPage() {
        if let url = URL(string: "https://github.com/jameslockman/Griffin-PowerMate-Driver/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Help dialog

    @objc func showHelp() {
        let lines: [(String, String)] = [
            ("", "PowerMate Agent runs in the background and turns the PowerMate into a scroll wheel or volume control.\n"),
            ("Scroll mode, Audio mode, Keypress mode", " – Mutually exclusive: pick one to set what turning the PowerMate does by default."),
            ("VU Meter", " – Pulse the blue LED in time with your audio stream."),
            ("Click in audio mode", " – Set the default action to Play/Pause or Mute/Unmute. Hold Shift to use the other action."),
            ("Prefer Fine volume in audio mode", " – Swap normal and fine volume steps in audio mode."),
            ("Reverse scroll direction", " – Reverses the scroll direction in scroll mode."),
            ("Prefer Fine scrolling", " – Scroll by single-pixel increments instead of the default coarse step for precise control."),
            ("Keypress mode", " – Turning sends a configured keystroke instead of scrolling (disables Audio mode). Configure the keys, including Shift/Option/Command/Press variants, via \"Configure Keypress Mode...\".\n"),
            ("Long press", " – Right-click, left-click, double-click, toggle between two modes (Audio/Scroll, Audio/Keypress, or Scroll/Keypress), toggle fine/coarse scrolling, or run a script. Configurable per app in \"Configure Applications...\".\n"),
            ("Modifiers:", ""),
            ("Fn + turn", " – Momentarily toggle between scroll and audio mode."),
            ("Shift + turn (audio mode)", " – Fine volume step (like Shift+Option+Volume keys)."),
            ("Shift + turn (scroll mode)", " – Scroll horizontally instead of vertically (swapped when \"Default to horizontal scroll\" is on)."),
            ("Option + turn (scroll mode)", " – Toggle between fine and coarse scrolling."),
            ("Shift + Option + turn (scroll mode)", " – Scroll on the alternate axis in fine mode."),
            ("Press + turn (audio or scroll mode)", " – Skip to next or previous track in the current media player."),
            ("Shift + click (audio mode)", " – Alternate between mute and play/pause.\n"),
            ("Configure Scripts", " – Sets shell commands for long press (and Shift+long press).\n"),
            ("Configure Applications", " – Override the mode and its settings for specific apps, independent of the defaults above. Add an app, then set its mode (Scroll/Audio/Keypress) and behavior.\n"),
            ("Feedback/bug report", " - Let us know if you have any issues or suggestions."),
        ]

        let normalFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let boldFont   = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let result     = NSMutableAttributedString()

        let centeredStyle = NSMutableParagraphStyle()
        centeredStyle.alignment = .center
        centeredStyle.paragraphSpacing = 12
        result.append(NSAttributedString(string: "PowerMate Agent\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: centeredStyle,
        ]))
        let versionStyle = NSMutableParagraphStyle()
        versionStyle.alignment = .center
        versionStyle.paragraphSpacing = 6
        result.append(NSAttributedString(string: "Version \(kCurrentVersion)\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: versionStyle,
        ]))

        for (bold, plain) in lines {
            if !bold.isEmpty {
                result.append(NSAttributedString(string: bold, attributes: [.font: boldFont]))
            }
            if !plain.isEmpty {
                result.append(NSAttributedString(string: plain, attributes: [.font: normalFont]))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: normalFont]))
        }

        // Make "Feedback/bug report" a clickable link.
        let full = result.string as NSString
        let linkRange = full.range(of: "Feedback/bug report")
        result.addAttribute(.link,
            value: "https://github.com/jameslockman/Griffin-PowerMate-Driver/issues",
            range: linkRange)

        let alert = NSAlert()
        alert.messageText = ""
        alert.informativeText = ""
        alert.addButton(withTitle: "OK")

        let tvWidth: CGFloat  = 450
        let tvHeight: CGFloat = 400
        alert.accessoryView = {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: tvWidth, height: tvHeight))
            let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: tvWidth, height: tvHeight))
            sv.hasVerticalScroller = true
            sv.autohidesScrollers  = true
            sv.borderType          = .noBorder
            sv.drawsBackground     = false
            let contentWidth = sv.contentSize.width
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: tvHeight))
            tv.minSize                            = NSSize(width: 0, height: tvHeight)
            tv.maxSize                            = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            tv.isVerticallyResizable              = true
            tv.isHorizontallyResizable            = false
            tv.autoresizingMask                   = .width
            tv.textContainer?.containerSize       = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = true
            tv.textStorage?.setAttributedString(result)
            tv.isEditable      = false
            tv.isSelectable    = true
            tv.drawsBackground = false
            sv.documentView = tv
            container.addSubview(sv)
            return container
        }()

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Status item and menu

let menuHandler = MenuHandler()
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
let menu = NSMenu()
let updateAvailableItem: NSMenuItem = {
    let item = NSMenuItem(title: "Update available", action: #selector(MenuHandler.openReleasesPage), keyEquivalent: "")
    item.target = menuHandler
    item.isHidden = true
    return item
}()

// MARK: - Menu construction

func buildMenu() {
    if let button = statusItem.button {
        button.toolTip = "PowerMate Agent — Audio and scroll controls"
    }
    updateStatusIcon()
    menu.delegate = menuHandler

    let audioItem = NSMenuItem(title: "Audio mode", action: #selector(MenuHandler.toggleAudioControl), keyEquivalent: "")
    audioItem.target = menuHandler
    menuHandler.audioControlItem = audioItem
    menu.addItem(audioItem)

    let vuMeterItem = NSMenuItem(title: "VU Meter", action: #selector(MenuHandler.toggleVUMeter), keyEquivalent: "")
    vuMeterItem.target = menuHandler
    menuHandler.vuMeterItem = vuMeterItem
    menu.addItem(vuMeterItem)

    let clickMenu = NSMenu()
    let clickMuteItem = NSMenuItem(title: "Mute/unmute", action: #selector(MenuHandler.setClickMute), keyEquivalent: "")
    clickMuteItem.target = menuHandler
    menuHandler.clickMuteItem = clickMuteItem
    clickMenu.addItem(clickMuteItem)
    let clickPlayPauseItem = NSMenuItem(title: "Play/Pause", action: #selector(MenuHandler.setClickPlayPause), keyEquivalent: "")
    clickPlayPauseItem.target = menuHandler
    menuHandler.clickPlayPauseItem = clickPlayPauseItem
    clickMenu.addItem(clickPlayPauseItem)
    let clickSub = NSMenuItem(title: "Click in audio mode", action: nil, keyEquivalent: "")
    clickSub.submenu = clickMenu
    menu.addItem(clickSub)

    let audioStepSwappedItem = NSMenuItem(title: "Prefer Fine volume in audio mode", action: #selector(MenuHandler.toggleAudioStepSwapped), keyEquivalent: "")
    audioStepSwappedItem.target = menuHandler
    menuHandler.audioStepSwappedItem = audioStepSwappedItem
    menu.addItem(audioStepSwappedItem)

    menu.addItem(NSMenuItem.separator())

    let keypressModeItem = NSMenuItem(title: "Keypress mode", action: #selector(MenuHandler.toggleKeypressMode), keyEquivalent: "")
    keypressModeItem.target = menuHandler
    menuHandler.keypressModeItem = keypressModeItem
    menu.addItem(keypressModeItem)

    let configKeypressItem = NSMenuItem(title: "Configure Keypress Mode...", action: #selector(MenuHandler.configureKeypressMode), keyEquivalent: "")
    configKeypressItem.target = menuHandler
    menu.addItem(configKeypressItem)

    menu.addItem(NSMenuItem.separator())

    let scrollModeItem = NSMenuItem(title: "Scroll mode", action: #selector(MenuHandler.selectScrollMode), keyEquivalent: "")
    scrollModeItem.target = menuHandler
    menuHandler.scrollModeItem = scrollModeItem
    menu.addItem(scrollModeItem)

    let reverseItem = NSMenuItem(title: "Reverse scroll direction", action: #selector(MenuHandler.toggleScrollReversed), keyEquivalent: "")
    reverseItem.target = menuHandler
    menuHandler.reverseScrollItem = reverseItem
    menu.addItem(reverseItem)

    let fineScrollItem = NSMenuItem(title: "Prefer Fine scrolling", action: #selector(MenuHandler.toggleFineScroll), keyEquivalent: "")
    fineScrollItem.target = menuHandler
    menuHandler.fineScrollItem = fineScrollItem
    menu.addItem(fineScrollItem)

    let scrollAxesSwappedItem = NSMenuItem(title: "Default to horizontal scroll", action: #selector(MenuHandler.toggleScrollAxesSwapped), keyEquivalent: "")
    scrollAxesSwappedItem.target = menuHandler
    menuHandler.scrollAxesSwappedItem = scrollAxesSwappedItem
    menu.addItem(scrollAxesSwappedItem)

    menu.addItem(NSMenuItem.separator())

    let longPressMenu = NSMenu()
    let longPressRightItem = NSMenuItem(title: "Right-click", action: #selector(MenuHandler.setLongPressRightClick), keyEquivalent: "")
    longPressRightItem.target = menuHandler
    menuHandler.longPressRightItem = longPressRightItem
    longPressMenu.addItem(longPressRightItem)
    let longPressLeftItem = NSMenuItem(title: "Left-click", action: #selector(MenuHandler.setLongPressLeftClick), keyEquivalent: "")
    longPressLeftItem.target = menuHandler
    menuHandler.longPressLeftItem = longPressLeftItem
    longPressMenu.addItem(longPressLeftItem)
    let longPressDoubleItem = NSMenuItem(title: "Double-click", action: #selector(MenuHandler.setLongPressDoubleClick), keyEquivalent: "")
    longPressDoubleItem.target = menuHandler
    menuHandler.longPressDoubleItem = longPressDoubleItem
    longPressMenu.addItem(longPressDoubleItem)

    let toggleModeMenu = NSMenu()
    let toggleAudioScrollItem = NSMenuItem(title: ModeTogglePair.audioScroll.title, action: #selector(MenuHandler.setLongPressToggleAudioScroll), keyEquivalent: "")
    toggleAudioScrollItem.target = menuHandler
    menuHandler.longPressToggleAudioScrollItem = toggleAudioScrollItem
    toggleModeMenu.addItem(toggleAudioScrollItem)
    let toggleAudioKeypressItem = NSMenuItem(title: ModeTogglePair.audioKeypress.title, action: #selector(MenuHandler.setLongPressToggleAudioKeypress), keyEquivalent: "")
    toggleAudioKeypressItem.target = menuHandler
    menuHandler.longPressToggleAudioKeypressItem = toggleAudioKeypressItem
    toggleModeMenu.addItem(toggleAudioKeypressItem)
    let toggleScrollKeypressItem = NSMenuItem(title: ModeTogglePair.scrollKeypress.title, action: #selector(MenuHandler.setLongPressToggleScrollKeypress), keyEquivalent: "")
    toggleScrollKeypressItem.target = menuHandler
    menuHandler.longPressToggleScrollKeypressItem = toggleScrollKeypressItem
    toggleModeMenu.addItem(toggleScrollKeypressItem)
    let toggleModeSub = NSMenuItem(title: "Toggle Mode", action: nil, keyEquivalent: "")
    toggleModeSub.submenu = toggleModeMenu
    longPressMenu.addItem(toggleModeSub)

    let longPressFineScrollItem = NSMenuItem(title: "Toggle fine/coarse scrolling", action: #selector(MenuHandler.setLongPressFineScroll), keyEquivalent: "")
    longPressFineScrollItem.target = menuHandler
    menuHandler.longPressFineScrollItem = longPressFineScrollItem
    longPressMenu.addItem(longPressFineScrollItem)
    let longPressRunScriptItem = NSMenuItem(title: "Run script", action: #selector(MenuHandler.setLongPressRunScript), keyEquivalent: "")
    longPressRunScriptItem.target = menuHandler
    menuHandler.longPressRunScriptItem = longPressRunScriptItem
    longPressMenu.addItem(longPressRunScriptItem)
    let longPressSub = NSMenuItem(title: "Long press", action: nil, keyEquivalent: "")
    longPressSub.submenu = longPressMenu
    menu.addItem(longPressSub)

    menu.addItem(NSMenuItem.separator())

    let configScriptsItem = NSMenuItem(title: "Configure Scripts...", action: #selector(MenuHandler.configureScripts), keyEquivalent: "")
    configScriptsItem.target = menuHandler
    menu.addItem(configScriptsItem)

    let configAppsItem = NSMenuItem(title: "Configure Applications...", action: #selector(MenuHandler.configureApplications), keyEquivalent: "")
    configAppsItem.target = menuHandler
    menu.addItem(configAppsItem)

    menu.addItem(updateAvailableItem)

    menu.addItem(NSMenuItem.separator())

    let helpItem = NSMenuItem(title: "Help...", action: #selector(MenuHandler.showHelp), keyEquivalent: "")
    helpItem.target = menuHandler
    if let helpIcon = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil) {
        helpItem.image = helpIcon
    }
    menu.addItem(helpItem)

    let quitItem = NSMenuItem(title: "Quit PowerMate Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    quitItem.target = NSApp
    menu.addItem(quitItem)

    statusItem.menu = menu
    menuHandler.updateMenuState()
}
