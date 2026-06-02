import Foundation
import AppKit

// MARK: - MenuHandler

final class MenuHandler: NSObject, NSMenuDelegate {
    var reverseScrollItem: NSMenuItem!
    var scrollAxesSwappedItem: NSMenuItem!
    var audioStepSwappedItem: NSMenuItem!
    var audioControlItem: NSMenuItem!
    var clickMuteItem: NSMenuItem!
    var clickPlayPauseItem: NSMenuItem!
    var vuMeterItem: NSMenuItem!
    var longPressRightItem: NSMenuItem!
    var longPressDoubleItem: NSMenuItem!
    var longPressToggleAudioItem: NSMenuItem!
    var longPressRunScriptItem: NSMenuItem!

    func updateMenuState() {
        reverseScrollItem.state       = scrollReversed ? .on : .off
        scrollAxesSwappedItem.state   = scrollAxesSwapped ? .on : .off
        audioStepSwappedItem.state    = audioStepSwapped ? .on : .off
        audioControlItem.state        = audioControlEnabled ? .on : .off
        clickMuteItem.state           = (clickAction == .mute) ? .on : .off
        clickPlayPauseItem.state      = (clickAction == .playPause) ? .on : .off
        vuMeterItem.state             = vuMeterEnabled ? .on : .off
        longPressRightItem.state      = (longPressAction == .rightClick) ? .on : .off
        longPressDoubleItem.state     = (longPressAction == .doubleClick) ? .on : .off
        longPressToggleAudioItem.state = (longPressAction == .toggleAudioMode) ? .on : .off
        longPressRunScriptItem.state  = (longPressAction == .runScript) ? .on : .off
        updateStatusIcon()
        updateDockIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }

    // MARK: - Toggle actions

    @objc func toggleScrollReversed() {
        scrollReversed.toggle()
        defaults.set(scrollReversed, forKey: kScrollReversed)
        updateMenuState()
    }

    @objc func toggleScrollAxesSwapped() {
        scrollAxesSwapped.toggle()
        defaults.set(scrollAxesSwapped, forKey: kScrollAxesSwapped)
        updateMenuState()
    }

    @objc func toggleAudioStepSwapped() {
        audioStepSwapped.toggle()
        defaults.set(audioStepSwapped, forKey: kAudioStepSwapped)
        updateMenuState()
    }

    @objc func toggleAudioControl() {
        audioControlEnabled.toggle()
        defaults.set(audioControlEnabled, forKey: kAudioControl)
        if audioControlEnabled {
            if #available(macOS 14.2, *) { startAudioMeter() }
        } else {
            stopAudioMeter()
        }
        signalModeChange(toAudio: audioControlEnabled)
        updateMenuState()
    }

    @objc func setClickMute() {
        clickAction = .mute
        defaults.set("mute", forKey: kClickAction)
        updateMenuState()
    }

    @objc func setClickPlayPause() {
        clickAction = .playPause
        defaults.set("playPause", forKey: kClickAction)
        updateMenuState()
    }

    @objc func toggleVUMeter() {
        vuMeterEnabled.toggle()
        defaults.set(vuMeterEnabled, forKey: kVUMeter)
        if audioControlEnabled {
            if vuMeterEnabled {
                if #available(macOS 14.2, *) { startAudioMeter() }
            } else {
                stopAudioMeter()
                setLEDOffMain(80)
            }
        }
        updateMenuState()
    }

    @objc func setLongPressRightClick() {
        longPressAction = .rightClick
        defaults.set("rightClick", forKey: kLongPressAction)
        updateMenuState()
    }

    @objc func setLongPressDoubleClick() {
        longPressAction = .doubleClick
        defaults.set("doubleClick", forKey: kLongPressAction)
        updateMenuState()
    }

    @objc func setLongPressToggleAudio() {
        longPressAction = .toggleAudioMode
        defaults.set("toggleAudioMode", forKey: kLongPressAction)
        updateMenuState()
    }

    @objc func setLongPressRunScript() {
        longPressAction = .runScript
        defaults.set("runScript", forKey: kLongPressAction)
        updateMenuState()
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
            ("Audio mode", " – Enable in the menu to use the PowerMate as a volume control. Otherwise it acts as a scroll wheel."),
            ("VU Meter", " – Pulse the blue LED in time with your audio stream."),
            ("Click in audio mode", " – Set the default action to Play/Pause or Mute/Unmute. Hold Shift to use the other action."),
            ("Prefer Fine volume in audio mode", " – Swap normal and fine volume steps in audio mode."),
            ("Reverse scroll direction", " – Reverses the scroll direction in scroll mode."),
            ("Long press", " – Right-click, double-click, toggle audio/scroll mode, or run a script.\n"),
            ("Modifiers:", ""),
            ("Fn + turn", " – Momentarily toggle between scroll and audio mode."),
            ("Shift + turn (audio mode)", " – Fine volume step (like Shift+Option+Volume keys)."),
            ("Shift + turn (scroll mode)", " – Scroll horizontally instead of vertically (swapped when \"Default to horizontal scroll\" is on)."),
            ("Press + turn (audio or scroll mode)", " – Skip to next or previous track in the current media player."),
            ("Shift + click (audio mode)", " – Alternate between mute and play/pause.\n"),
            ("Configure Scripts", " – Sets shell commands for long press (and Shift+long press).\n"),
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

    let reverseItem = NSMenuItem(title: "Reverse scroll direction", action: #selector(MenuHandler.toggleScrollReversed), keyEquivalent: "")
    reverseItem.target = menuHandler
    menuHandler.reverseScrollItem = reverseItem
    menu.addItem(reverseItem)

    let scrollAxesSwappedItem = NSMenuItem(title: "Default to horizontal scroll", action: #selector(MenuHandler.toggleScrollAxesSwapped), keyEquivalent: "")
    scrollAxesSwappedItem.target = menuHandler
    menuHandler.scrollAxesSwappedItem = scrollAxesSwappedItem
    menu.addItem(scrollAxesSwappedItem)

    let longPressMenu = NSMenu()
    let longPressRightItem = NSMenuItem(title: "Right-click", action: #selector(MenuHandler.setLongPressRightClick), keyEquivalent: "")
    longPressRightItem.target = menuHandler
    menuHandler.longPressRightItem = longPressRightItem
    longPressMenu.addItem(longPressRightItem)
    let longPressDoubleItem = NSMenuItem(title: "Double-click", action: #selector(MenuHandler.setLongPressDoubleClick), keyEquivalent: "")
    longPressDoubleItem.target = menuHandler
    menuHandler.longPressDoubleItem = longPressDoubleItem
    longPressMenu.addItem(longPressDoubleItem)
    let longPressToggleAudioItem = NSMenuItem(title: "Toggle audio/scroll mode", action: #selector(MenuHandler.setLongPressToggleAudio), keyEquivalent: "")
    longPressToggleAudioItem.target = menuHandler
    menuHandler.longPressToggleAudioItem = longPressToggleAudioItem
    longPressMenu.addItem(longPressToggleAudioItem)
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
