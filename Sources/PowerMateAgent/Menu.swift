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
    var clickLeftClickItem: NSMenuItem!
    var clickRightClickItem: NSMenuItem!
    var clickMuteItem: NSMenuItem!
    var clickPlayPauseItem: NSMenuItem!
    var clickCustomItem: NSMenuItem!
    var doubleClickNoneItem: NSMenuItem!
    var doubleClickLeftClickItem: NSMenuItem!
    var doubleClickRightClickItem: NSMenuItem!
    var doubleClickMuteItem: NSMenuItem!
    var doubleClickPlayPauseItem: NSMenuItem!
    var doubleClickCustomItem: NSMenuItem!
    var vuMeterItem: NSMenuItem!
    var longPressRightItem: NSMenuItem!
    var longPressLeftItem: NSMenuItem!
    var longPressDoubleItem: NSMenuItem!
    var longPressToggleAudioScrollItem: NSMenuItem!
    var longPressToggleAudioKeypressItem: NSMenuItem!
    var longPressToggleScrollKeypressItem: NSMenuItem!
    var longPressFineScrollItem: NSMenuItem!
    var longPressRunScriptItem: NSMenuItem!
    var longPressCustomItem: NSMenuItem!
    var holdKeyNoneItem: NSMenuItem!
    var holdKeyCaptureItem: NSMenuItem!

    func updateMenuState() {
        reverseScrollItem.state       = defaultSettings.scrollReversed ? .on : .off
        fineScrollItem.state          = defaultSettings.fineScrollEnabled ? .on : .off
        scrollAxesSwappedItem.state   = defaultSettings.scrollAxesSwapped ? .on : .off
        audioStepSwappedItem.state    = defaultSettings.audioStepSwapped ? .on : .off
        scrollModeItem.state          = defaultSettings.mode == .scroll ? .on : .off
        audioControlItem.state        = defaultSettings.mode == .audio ? .on : .off
        keypressModeItem.state        = defaultSettings.mode == .keypress ? .on : .off
        clickLeftClickItem.state      = (defaultSettings.clickAction == .leftClick) ? .on : .off
        clickRightClickItem.state     = (defaultSettings.clickAction == .rightClick) ? .on : .off
        clickMuteItem.state           = (defaultSettings.clickAction == .mute) ? .on : .off
        clickPlayPauseItem.state      = (defaultSettings.clickAction == .playPause) ? .on : .off
        clickCustomItem.state         = (defaultSettings.clickAction.customBinding != nil) ? .on : .off
        clickCustomItem.title         = customKeypressTitle(defaultSettings.clickAction.customBinding)
        doubleClickNoneItem.state      = (defaultSettings.doubleClickAction == .none) ? .on : .off
        doubleClickLeftClickItem.state = (defaultSettings.doubleClickAction == .leftClick) ? .on : .off
        doubleClickRightClickItem.state = (defaultSettings.doubleClickAction == .rightClick) ? .on : .off
        doubleClickMuteItem.state      = (defaultSettings.doubleClickAction == .mute) ? .on : .off
        doubleClickPlayPauseItem.state = (defaultSettings.doubleClickAction == .playPause) ? .on : .off
        doubleClickCustomItem.state    = (defaultSettings.doubleClickAction.customBinding != nil) ? .on : .off
        doubleClickCustomItem.title    = customKeypressTitle(defaultSettings.doubleClickAction.customBinding)
        vuMeterItem.state             = vuMeterEnabled ? .on : .off
        longPressRightItem.state               = (defaultSettings.longPressAction == .rightClick) ? .on : .off
        longPressLeftItem.state                = (defaultSettings.longPressAction == .leftClick) ? .on : .off
        longPressDoubleItem.state              = (defaultSettings.longPressAction == .doubleClick) ? .on : .off
        longPressToggleAudioScrollItem.state    = (defaultSettings.longPressAction == .toggleMode(.audioScroll)) ? .on : .off
        longPressToggleAudioKeypressItem.state  = (defaultSettings.longPressAction == .toggleMode(.audioKeypress)) ? .on : .off
        longPressToggleScrollKeypressItem.state = (defaultSettings.longPressAction == .toggleMode(.scrollKeypress)) ? .on : .off
        longPressFineScrollItem.state           = (defaultSettings.longPressAction == .toggleFineScroll) ? .on : .off
        longPressRunScriptItem.state            = (defaultSettings.longPressAction == .runScript) ? .on : .off
        longPressCustomItem.state               = (defaultSettings.longPressAction.customBinding != nil) ? .on : .off
        longPressCustomItem.title               = customKeypressTitle(defaultSettings.longPressAction.customBinding)

        holdKeyNoneItem.state    = (defaultSettings.holdKey == nil) ? .on : .off
        holdKeyCaptureItem.state = (defaultSettings.holdKey != nil) ? .on : .off
        holdKeyCaptureItem.title = holdKeyTitle(defaultSettings.holdKey)
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

    private func setClickAction(_ action: ClickAction) {
        defaultSettings.clickAction = action
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func setClickLeftClick()  { setClickAction(.leftClick) }
    @objc func setClickRightClick() { setClickAction(.rightClick) }
    @objc func setClickMute()       { setClickAction(.mute) }
    @objc func setClickPlayPause()  { setClickAction(.playPause) }

    @objc func setClickCustom() {
        if let binding = showCaptureCustomKeypress(current: defaultSettings.clickAction.customBinding) {
            setClickAction(.custom(binding))
        }
    }

    private func setDoubleClickAction(_ action: ClickAction) {
        defaultSettings.doubleClickAction = action
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func setDoubleClickNone()       { setDoubleClickAction(.none) }
    @objc func setDoubleClickLeftClick()  { setDoubleClickAction(.leftClick) }
    @objc func setDoubleClickRightClick() { setDoubleClickAction(.rightClick) }
    @objc func setDoubleClickMute()       { setDoubleClickAction(.mute) }
    @objc func setDoubleClickPlayPause()  { setDoubleClickAction(.playPause) }

    @objc func setDoubleClickCustom() {
        if let binding = showCaptureCustomKeypress(current: defaultSettings.doubleClickAction.customBinding) {
            setDoubleClickAction(.custom(binding))
        }
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

    @objc func setLongPressCustom() {
        if let binding = showCaptureCustomKeypress(current: defaultSettings.longPressAction.customBinding) {
            setLongPressAction(.custom(binding))
        }
    }

    private func setHoldKey(_ binding: KeyBinding?) {
        defaultSettings.holdKey = binding
        saveDefaultSettings()
        updateMenuState()
    }

    @objc func setHoldKeyNone() { setHoldKey(nil) }

    @objc func setHoldKeyCapture() {
        if let binding = showCaptureHoldKey(current: defaultSettings.holdKey) {
            setHoldKey(binding)
        }
    }

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
            ("Prefer Fine volume in audio mode", " – Swap normal and fine volume steps in audio mode."),
            ("Reverse scroll direction", " – Reverses the scroll direction in scroll mode."),
            ("Prefer Fine scrolling", " – Scroll by single-pixel increments instead of the default coarse step for precise control."),
            ("Keypress mode", " – Turning sends a configured keystroke instead of scrolling (disables Audio mode). Configure the keys, including Shift/Option/Command/Press variants, via \"Configure Keypress Mode...\".\n"),
            ("Click / Double-click", " – Set what the button does on a click or double-click: Left-click, Right-click, Mute/Unmute, Play/Pause, or a Custom Keypress you record. Applies the same in every mode. Double-click defaults to None (no detection delay added to clicks) until you configure one. For Mute/Unmute or Play/Pause, hold Shift to use the other action."),
            ("Long press", " – Right-click, left-click, double-click, toggle between two modes (Audio/Scroll, Audio/Keypress, or Scroll/Keypress), toggle fine/coarse scrolling, run a script, or a Custom Keypress. Configurable per app in \"Configure Applications...\".\n"),
            ("Hold key", " – Holds a single key down for exactly as long as the PowerMate button is held, for push-to-talk dictation and anything else that reacts to a key being held. A bare modifier such as Fn can be recorded. While a hold key is set, click, double-click and long press do nothing.\n"),
            ("Modifiers:", ""),
            ("Fn + turn", " – Momentarily toggle between scroll and audio mode."),
            ("Shift + turn (audio mode)", " – Fine volume step (like Shift+Option+Volume keys)."),
            ("Shift + turn (scroll mode)", " – Scroll horizontally instead of vertically (swapped when \"Default to horizontal scroll\" is on)."),
            ("Option + turn (scroll mode)", " – Toggle between fine and coarse scrolling."),
            ("Shift + Option + turn (scroll mode)", " – Scroll on the alternate axis in fine mode."),
            ("Press + turn (audio or scroll mode)", " – Skip to next or previous track in the current media player."),
            ("Shift + click/double-click", " – When set to Mute/Unmute or Play/Pause, alternates to the other action instead.\n"),
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

    // Click, Double-click, and Long press are grouped together: all three are independent of
    // rotation mode and configure what the button itself does.
    let clickMenu = NSMenu()
    let clickLeftClickItem = NSMenuItem(title: "Left-click", action: #selector(MenuHandler.setClickLeftClick), keyEquivalent: "")
    clickLeftClickItem.target = menuHandler
    menuHandler.clickLeftClickItem = clickLeftClickItem
    clickMenu.addItem(clickLeftClickItem)
    let clickRightClickItem = NSMenuItem(title: "Right-click", action: #selector(MenuHandler.setClickRightClick), keyEquivalent: "")
    clickRightClickItem.target = menuHandler
    menuHandler.clickRightClickItem = clickRightClickItem
    clickMenu.addItem(clickRightClickItem)
    let clickMuteItem = NSMenuItem(title: "Mute/unmute", action: #selector(MenuHandler.setClickMute), keyEquivalent: "")
    clickMuteItem.target = menuHandler
    menuHandler.clickMuteItem = clickMuteItem
    clickMenu.addItem(clickMuteItem)
    let clickPlayPauseItem = NSMenuItem(title: "Play/Pause", action: #selector(MenuHandler.setClickPlayPause), keyEquivalent: "")
    clickPlayPauseItem.target = menuHandler
    menuHandler.clickPlayPauseItem = clickPlayPauseItem
    clickMenu.addItem(clickPlayPauseItem)
    let clickCustomItem = NSMenuItem(title: "Custom Keypress...", action: #selector(MenuHandler.setClickCustom), keyEquivalent: "")
    clickCustomItem.target = menuHandler
    menuHandler.clickCustomItem = clickCustomItem
    clickMenu.addItem(clickCustomItem)
    let clickSub = NSMenuItem(title: "Click", action: nil, keyEquivalent: "")
    clickSub.submenu = clickMenu
    menu.addItem(clickSub)

    let doubleClickMenu = NSMenu()
    let doubleClickNoneItem = NSMenuItem(title: "None", action: #selector(MenuHandler.setDoubleClickNone), keyEquivalent: "")
    doubleClickNoneItem.target = menuHandler
    menuHandler.doubleClickNoneItem = doubleClickNoneItem
    doubleClickMenu.addItem(doubleClickNoneItem)
    let doubleClickLeftClickItem = NSMenuItem(title: "Left-click", action: #selector(MenuHandler.setDoubleClickLeftClick), keyEquivalent: "")
    doubleClickLeftClickItem.target = menuHandler
    menuHandler.doubleClickLeftClickItem = doubleClickLeftClickItem
    doubleClickMenu.addItem(doubleClickLeftClickItem)
    let doubleClickRightClickItem = NSMenuItem(title: "Right-click", action: #selector(MenuHandler.setDoubleClickRightClick), keyEquivalent: "")
    doubleClickRightClickItem.target = menuHandler
    menuHandler.doubleClickRightClickItem = doubleClickRightClickItem
    doubleClickMenu.addItem(doubleClickRightClickItem)
    let doubleClickMuteItem = NSMenuItem(title: "Mute/unmute", action: #selector(MenuHandler.setDoubleClickMute), keyEquivalent: "")
    doubleClickMuteItem.target = menuHandler
    menuHandler.doubleClickMuteItem = doubleClickMuteItem
    doubleClickMenu.addItem(doubleClickMuteItem)
    let doubleClickPlayPauseItem = NSMenuItem(title: "Play/Pause", action: #selector(MenuHandler.setDoubleClickPlayPause), keyEquivalent: "")
    doubleClickPlayPauseItem.target = menuHandler
    menuHandler.doubleClickPlayPauseItem = doubleClickPlayPauseItem
    doubleClickMenu.addItem(doubleClickPlayPauseItem)
    let doubleClickCustomItem = NSMenuItem(title: "Custom Keypress...", action: #selector(MenuHandler.setDoubleClickCustom), keyEquivalent: "")
    doubleClickCustomItem.target = menuHandler
    menuHandler.doubleClickCustomItem = doubleClickCustomItem
    doubleClickMenu.addItem(doubleClickCustomItem)
    let doubleClickSub = NSMenuItem(title: "Double-click", action: nil, keyEquivalent: "")
    doubleClickSub.submenu = doubleClickMenu
    menu.addItem(doubleClickSub)

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
    let longPressCustomItem = NSMenuItem(title: "Custom Keypress...", action: #selector(MenuHandler.setLongPressCustom), keyEquivalent: "")
    longPressCustomItem.target = menuHandler
    menuHandler.longPressCustomItem = longPressCustomItem
    longPressMenu.addItem(longPressCustomItem)
    let longPressSub = NSMenuItem(title: "Long press", action: nil, keyEquivalent: "")
    longPressSub.submenu = longPressMenu
    menu.addItem(longPressSub)

    let holdKeyMenu = NSMenu()
    let holdKeyNoneItem = NSMenuItem(title: "None", action: #selector(MenuHandler.setHoldKeyNone), keyEquivalent: "")
    holdKeyNoneItem.target = menuHandler
    menuHandler.holdKeyNoneItem = holdKeyNoneItem
    holdKeyMenu.addItem(holdKeyNoneItem)
    let holdKeyCaptureItem = NSMenuItem(title: "Hold Key While Pressed...", action: #selector(MenuHandler.setHoldKeyCapture), keyEquivalent: "")
    holdKeyCaptureItem.target = menuHandler
    menuHandler.holdKeyCaptureItem = holdKeyCaptureItem
    holdKeyMenu.addItem(holdKeyCaptureItem)
    let holdKeySub = NSMenuItem(title: "Hold key", action: nil, keyEquivalent: "")
    holdKeySub.submenu = holdKeyMenu
    menu.addItem(holdKeySub)

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
