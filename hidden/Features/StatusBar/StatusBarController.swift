//
//  StatusBarController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/30/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit

class StatusBarController {
    
    //MARK: - Variables
    private var timer:Timer? = nil
    
    //MARK: - BarItems
        
    // On macOS 27 the position key must be in defaults and the autosave name set
    // at creation, before the button is configured; assigning the name later
    // leaves the item where macOS first put it (measured, see the 27 notes below).
    private let btnExpandCollapse = StatusBarController.makeStatusItem(length: NSStatusItem.variableLength,
                                                                        autosaveName: StatusBarController.expandCollapseAutosaveName,
                                                                        freshKey: StatusBarController.freshExpandCollapseKey)
    private let btnSeparate = StatusBarController.makeStatusItem(length: 1,
                                                                 autosaveName: StatusBarController.separateAutosaveName,
                                                                 freshKey: StatusBarController.freshSeparateKey)
    private var btnAlwaysHidden:NSStatusItem? = nil
    
    private var btnHiddenLength: CGFloat = 20
    private var btnHiddenCollapseLength: CGFloat = 2000
    
    private var btnAlwaysHiddenLength: CGFloat = Preferences.alwaysHiddenSectionEnabled ? 20 : 0
    private var btnAlwaysHiddenEnableExpandCollapseLength: CGFloat = Preferences.alwaysHiddenSectionEnabled ? 2000 : 0
    
    private let imgIconLine = NSImage(named:NSImage.Name("ic_line"))
    
    private var isCollapsed: Bool {
        if usesOverflowHiding { return isCollapsedByOverflow }
        // Compare with > rather than == so the state survives updateCollapsedLengths
        // changing btnHiddenCollapseLength while the bar is collapsed (PR #354).
        return self.btnSeparate.length > self.btnHiddenLength
    }

    // MARK: macOS 27 overflow-based hiding (#360)
    //
    // macOS 27 re-architected the menu bar (MenuBarAgent). Measured behavior:
    //  1. Items lay out right-to-left. The first item that does not fit, and
    //     EVERY item after it, move into the system's native overflow menu.
    //  2. An item whose length reaches half the display width is dropped from
    //     layout entirely; nothing after it is affected. This is what killed the
    //     old trick: a separator inflated to 2x the widest screen was simply
    //     discarded, and its icons stayed put.
    //  3. One item length applies to every display's bar, and the free space
    //     differs per display, so no single length can both exceed the free
    //     space on a wide display and stay under the cliff on a narrow one.
    //
    // So on 27 the separator keeps its normal size, and a collapse inserts a
    // chain of blank "filler" items between the expand button and the separator,
    // each shorter than half the NARROWEST display and long enough in total to
    // exceed the WIDEST. On each display the fillers that fit take the free
    // space, and the first that does not fit carries the separator and every
    // icon left of it into the overflow. Expanding removes the fillers.
    //
    //  4. Position on 27 is an ordering key equal to (display right edge - 40 -
    //     item right edge). For an item the user has ever Cmd-dragged, MenuBarAgent
    //     keeps that key in its own store (by app name + autosaveName) and restores
    //     it across launches. For an item it has never seen arranged it reads the
    //     "legacy" key from "NSStatusItem Preferred Position <autosaveName>" in
    //     our defaults when the item appears, and never writes it back. Neither
    //     store is readable, so the key that puts a filler right of the separator
    //     is found by bisection with a probe item (see FillerChain). Our own
    //     items always carry a key: an item of ours WITHOUT one is flung to the far
    //     right the moment a keyed sibling (a filler) appears. The seeded keys
    //     only matter until the user first drags the item; they are deliberately
    //     not refreshed from geometry, because frames come from whichever display
    //     is active and keys measured on a narrower display sort our items too
    //     far right relative to other apps' icons.
    private var usesOverflowHiding: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }
    private var isCollapsedByOverflow = false
    // The two filler chains (see FillerChain.swift): one right of the separator
    // that hides the regular section while collapsed, one right of the
    // always-hidden separator that hides that section while expanded. Each owns
    // its own cancellation generation, in-flight state and key cache.
    private var fillerChain: FillerChain<StatusBarController>!
    private var alwaysHiddenFillerChain: FillerChain<StatusBarController>!
    private static let positionKeyPrefix = "NSStatusItem Preferred Position "
    private static let expandCollapseAutosaveName = "hiddenbar_expandcollapse"
    private static let separateAutosaveName = "hiddenbar_separate"
    private static let alwaysHiddenAutosaveName = "hiddenbar_terminate"
    // Fresh install on 27: no saved keys yet. Large keys sort left of every other
    // app's icons, matching the leftmost placement new items got on macOS <= 26.
    // The separator sits left of the expand button, the always-hidden separator
    // left of both.
    private static let freshExpandCollapseKey = 5000.0
    private static let freshSeparateKey = 5040.0
    private static let freshAlwaysHiddenKey = 5080.0
    
    private var isBtnSeparateValidPosition: Bool {
        guard
            let btnExpandCollapseX = self.btnExpandCollapse.button?.getOrigin?.x,
            let btnSeparateX = self.btnSeparate.button?.getOrigin?.x
            else {return false}
        
        if Constant.isUsingLTRLanguage {
            return btnExpandCollapseX >= btnSeparateX
        } else {
            return btnExpandCollapseX <= btnSeparateX
        }
    }
    
    private var isBtnAlwaysHiddenValidPosition: Bool {
        if !Preferences.alwaysHiddenSectionEnabled { return true }
        
        guard
            let btnSeparateX = self.btnSeparate.button?.getOrigin?.x,
            let btnAlwaysHiddenX = self.btnAlwaysHidden?.button?.getOrigin?.x
            else {return false}
        
        if Constant.isUsingLTRLanguage {
            return btnSeparateX >= btnAlwaysHiddenX
        } else {
            return btnSeparateX <= btnAlwaysHiddenX
        }
    }
    
    private var isToggle = false

    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?

    // True while the pointer sits in any screen's menubar band (the strip between
    // visibleFrame.maxY and frame.maxY, which is the menubar's exact height there).
    // On fullscreen spaces the menubar is hidden and the band collapses to ~zero,
    // so this returns false there: intentional, no visible menubar = no deferral.
    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }

    // The preferences window is an ordinary app window, not in the menu bar, so
    // the mouse-in-menubar guard does not cover it. With "use full menu bar on
    // expanding" on, an auto-collapse deactivates the app and dismisses this
    // window mid-edit (#170, same family as #66/#151). Defer the collapse while
    // it is on screen. isWindowLoaded short-circuits without force-loading the
    // window when preferences were never opened.
    private var isPreferencesWindowVisible: Bool {
        let wc = PreferencesWindowController.shared
        return wc.isWindowLoaded && (wc.window?.isVisible ?? false)
    }
    
    //MARK: - Methods
    init() {
        updateCollapsedLengths()
        if usesOverflowHiding {
            // The separator is never inflated on 27; the <= 26 path sizes it on
            // the first expand, which never happens here.
            btnSeparate.length = btnHiddenLength
        }
        setupUI()
        if usesOverflowHiding { setupFillerChains() }
        restoreRemovedStatusItems()
        setupAlwayHideStatusBar()
        setupHoverToExpandIfEnabled()
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.collapseMenuBar()
        }
        
        if Preferences.areSeparatorsHidden {hideSeparators()}
        autoCollapseIfNeeded()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // Opt-in via `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true`.
    // No monitor is installed at all unless the pref is true at launch.
    private func setupHoverToExpandIfEnabled() {
        guard Preferences.hoverToExpand else { return }
        NSLog("HoverToExpand: enabled, installing global mouse monitor")
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard self.isCollapsed && self.isMouseInMenuBar else {
                self.hoverDwellTimer?.invalidate()
                self.hoverDwellTimer = nil
                return
            }
            // Short dwell so a pointer merely passing through doesn't expand.
            guard self.hoverDwellTimer == nil else { return }
            self.hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.hoverDwellTimer = nil
                if self.isCollapsed && self.isMouseInMenuBar {
                    self.expandMenubar()
                }
            }
        }
    }
    
    @objc private func handleScreenParametersChanged() {
        // Re-apply the recomputed length to the LIVE item when collapsed, or a
        // display hot-plug leaves the separator at a stale length (PR #354).
        let wasCollapsed = isCollapsed
        updateCollapsedLengths()
        if usesOverflowHiding {
            // Filler geometry is derived from the display set, so rebuild whichever
            // chain is in use: the regular one while collapsed, the always-hidden
            // one while expanded (collapsing takes that section down anyway).
            if wasCollapsed {
                fillerChain.remove()
                fillerChain.insert { [weak self] ok in if !ok { self?.rollBackFailedCollapse() } }
            } else if alwaysHiddenFillersWanted {
                alwaysHiddenFillerChain.remove()
                alwaysHiddenFillerChain.insert()
            }
            return
        }
        if wasCollapsed {
            btnSeparate.length = btnHiddenCollapseLength
            if Preferences.areSeparatorsHidden {
                btnAlwaysHidden?.length = btnAlwaysHiddenEnableExpandCollapseLength
            }
        }
    }

    private func updateCollapsedLengths() {
        // The menubar replicates across every attached display, so the collapse
        // length must cover the WIDEST screen, not NSScreen.main (the focused one);
        // sizing from a narrower screen leaks hidden icons on wider displays.
        // frame.width, not visibleFrame: the menubar spans the full frame width.
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        // Keep collapse length bounded to avoid pathological layout/memory behavior;
        // macOS enforces a hard 10,000pt maximum on NSStatusItem.length (PR #354).
        let boundedCollapseLength = max(500, min(screenWidth * 2, 10_000))
        btnHiddenCollapseLength = boundedCollapseLength
        btnAlwaysHiddenEnableExpandCollapseLength = Preferences.alwaysHiddenSectionEnabled ? boundedCollapseLength : 0
    }
    
    private func restoreRemovedStatusItems() {
        // Cmd-dragging a status item off the bar is persisted by macOS via
        // autosaveName, leaving the app running but unreachable. These items are
        // the app's only UI, so they self-restore at launch.
        btnExpandCollapse.isVisible = true
        btnSeparate.isVisible = true
    }

    private func setupUI() {
        if let button = btnSeparate.button {
            button.image = self.imgIconLine
        }
        let menu = self.getContextMenu()
        btnSeparate.menu = menu

        updateAutoCollapseMenuTitle()
        
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
            button.target = self
            
            button.action = #selector(self.btnExpandCollapsePressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
    }
    
    @objc func btnExpandCollapsePressed(sender: NSStatusBarButton) {
        // An accessibility press (VoiceOver, AXPress from a test) arrives with no
        // mouse event; treat it as a plain click so the control stays operable.
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseUp || event.type == .rightMouseUp else {
            self.expandCollapseIfNeeded()
            return
        }

        let isOptionKeyPressed = event.modifierFlags.contains(NSEvent.ModifierFlags.option)

        if event.type == NSEvent.EventType.leftMouseUp && !isOptionKeyPressed{
            self.expandCollapseIfNeeded()
        } else if event.type == NSEvent.EventType.rightMouseUp && !isOptionKeyPressed {
            // Right-click opens the same context menu the separator has (#356),
            // making settings reachable from the control everyone clicks.
            // The separators/always-hidden toggle stays on option-click.
            showContextMenu(from: sender)
        } else {
            // Both option+left and option+right land here: separators toggle.
            self.showHideSeparatorsAndAlwayHideArea()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        guard let menu = btnSeparate.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }
    
    func showHideSeparatorsAndAlwayHideArea() {
        Preferences.areSeparatorsHidden ? self.showSeparators() : self.hideSeparators()
        
        if self.isCollapsed {self.expandMenubar()}
    }
    
    private func showSeparators() {
        Preferences.areSeparatorsHidden = false
        
        if usesOverflowHiding {
            alwaysHiddenFillerChain.remove()
            return
        }
        if !self.isCollapsed {
            self.btnSeparate.length = self.btnHiddenLength
        }
        self.btnAlwaysHidden?.length = self.btnAlwaysHiddenLength
    }
    
    private func hideSeparators() {
        guard self.isBtnAlwaysHiddenValidPosition else {return}
        
        Preferences.areSeparatorsHidden = true
        
        if usesOverflowHiding {
            if !isCollapsed { alwaysHiddenFillerChain.insert() }
            return
        }
        if !self.isCollapsed {
            self.btnSeparate.length = self.btnHiddenLength
        }
        self.btnAlwaysHidden?.length = self.btnAlwaysHiddenEnableExpandCollapseLength
    }
    
    func expandCollapseIfNeeded() {
        //prevented rapid click cause icon show many in Dock
        if isToggle {return}
        isToggle = true
        self.isCollapsed ? self.expandMenubar() : self.collapseMenuBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }
    
    private func collapseMenuBar() {
        guard self.isBtnSeparateValidPosition && !self.isCollapsed else {
            autoCollapseIfNeeded()
            return
        }

        if usesOverflowHiding {
            // The always-hidden fillers would only add blank rows to the overflow
            // menu, since everything left of the chain ends up in there anyway.
            alwaysHiddenFillerChain.remove()
            // Collapsed state is set now so a second click or the auto-collapse
            // timer cannot start a rival placement; a failed placement rolls it
            // back (rollBackFailedCollapse).
            isCollapsedByOverflow = true
            fillerChain.insert { [weak self] ok in if !ok { self?.rollBackFailedCollapse() } }
        } else {
            btnSeparate.length = self.btnHiddenCollapseLength
        }
        if let button = btnExpandCollapse.button {
            button.image = Assets.expandImage
        }
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
        }
    }
    private func expandMenubar() {
        guard self.isCollapsed else {return}
        if usesOverflowHiding {
            fillerChain.remove()
            isCollapsedByOverflow = false
            if alwaysHiddenFillersWanted { alwaysHiddenFillerChain.insert() }
        } else {
            btnSeparate.length = btnHiddenLength
        }
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
        }
        autoCollapseIfNeeded()
        
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            
        }
    }
    
    private func autoCollapseIfNeeded() {
        guard Preferences.isAutoHide else {return}
        guard !isCollapsed else { return }

        startTimerToAutoHide()
    }

    // MARK: macOS 27 filler chains

    private var alwaysHiddenFillersWanted: Bool {
        return Preferences.alwaysHiddenSectionEnabled && Preferences.areSeparatorsHidden && btnAlwaysHidden != nil
    }

    private func setupFillerChains() {
        fillerChain = makeFillerChain(prefix: "hiddenbar_fill") { [weak self] in self?.btnSeparate }
        alwaysHiddenFillerChain = makeFillerChain(prefix: "hiddenbar_ahfill") { [weak self] in self?.btnAlwaysHidden }
    }

    private func makeFillerChain(prefix: String, anchor: @escaping () -> NSStatusItem?) -> FillerChain<StatusBarController> {
        return FillerChain(host: self, prefix: prefix, anchor: anchor,
                           geometry: { [weak self] in self?.fillerGeometry() ?? .init(length: 100, count: 1) },
                           // Just below the anchor's geometric key is the natural
                           // first guess (larger keys sort further left).
                           initialGuess: { [weak self] anchorFrame in (self?.geometricPositionKey(ofFrame: anchorFrame) ?? 0) - 18 },
                           placement: { [weak self] probe, anchor in self?.placement(ofProbe: probe, rightOf: anchor) ?? .unknown })
    }

    // A collapse whose fillers could not be placed: undo the collapsed state so
    // the arrow, activation policy and auto-collapse timer match the bar, which
    // still shows everything.
    private func rollBackFailedCollapse() {
        guard isCollapsedByOverflow else { return }
        NSLog("HiddenBar27: collapse failed, rolling back to expanded")
        isCollapsedByOverflow = false
        btnExpandCollapse.button?.image = Assets.collapseImage
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
        }
        if alwaysHiddenFillersWanted { alwaysHiddenFillerChain.insert() }
        autoCollapseIfNeeded()
    }

    // Filler length stays under the drop cliff (half the display width) of the
    // narrowest display, with the same 64pt margin upstream measured against.
    // Enough fillers to exceed the widest display guarantee that, on every bar,
    // at least one filler fails to fit and carries the rest into the overflow.
    private func fillerGeometry() -> FillerChain<StatusBarController>.Geometry {
        let widths = NSScreen.screens.map { $0.frame.width }
        let narrowest = widths.min() ?? 1728
        let widest = widths.max() ?? narrowest
        let length = max(100, (narrowest / 2 - 64).rounded(.down))
        let count = Int((widest / length).rounded(.up)) + 1
        return .init(length: length, count: count)
    }

    private func frameOf(_ item: NSStatusItem?) -> CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // Two items are neighbours in the flow when only the 16pt inter-item spacing
    // separates them, or when they straddle the notch: the flow runs right of
    // the notch first and continues left of it, so the last item on the right
    // side and the first on the left side are neighbours too.
    private func isAdjacent(left: CGRect, right: CGRect) -> Bool {
        let gap = right.minX - left.maxX
        if gap >= -1 && gap <= 24 { return true }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: left.midX, y: left.midY)) }),
              let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea else { return false }
        return left.maxX <= leftArea.maxX + 1 && left.maxX >= leftArea.maxX - 80
            && right.minX >= rightArea.minX - 1 && right.minX <= rightArea.minX + 80
    }

    // Fillers must sort immediately right of their anchor (the separator, or the
    // always-hidden separator). Frames are read from whichever display is
    // active, which is consistent within one search.
    private func placement(ofProbe probe: CGRect, rightOf anchor: CGRect) -> FillerPlacement {
        if probe.maxX <= anchor.minX + 1 { return .tooFarLeft }
        if probe.minX >= anchor.maxX - 1 { return isAdjacent(left: anchor, right: probe) ? .between : .tooFarRight }
        return .unknown
    }

    // MARK: macOS 27 position keys

    // Seed the key macOS reads when the item with this autosave name appears,
    // unless one is already stored (a previous launch, or a fresh-install value).
    private static func seedPositionKeyIfMissing(_ key: Double, for autosaveName: String) {
        let defaultsKey = positionKeyPrefix + autosaveName
        if UserDefaults.standard.object(forKey: defaultsKey) as? Double == nil {
            UserDefaults.standard.set(key, forKey: defaultsKey)
        }
    }

    // Creates a status item with its autosave name assigned immediately. On
    // macOS 27 a missing position key is seeded first; assigning the name later
    // leaves the item where macOS first put it (measured).
    private static func makeStatusItem(length: CGFloat, autosaveName: String, freshKey: Double) -> NSStatusItem {
        if #available(macOS 27.0, *) {
            seedPositionKeyIfMissing(freshKey, for: autosaveName)
        }
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = autosaveName
        return item
    }

    // The key macOS 27 derives for an item at this frame: display right edge -
    // 40 - item right edge, on the display that hosts the frame.
    private func geometricPositionKey(ofFrame frame: CGRect) -> Double? {
        guard frame.width > 0,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { return nil }
        return Double(screen.frame.maxX - 40 - frame.maxX)
    }
    
    private func startTimerToAutoHide() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: Preferences.numberOfSecondForAutoHide, repeats: false) { [weak self] _ in
            guard let self = self, Preferences.isAutoHide else { return }
            // Don't yank the bar shut mid-interaction: while the pointer is in the
            // menubar (hovering, clicking, dragging icons), defer and re-arm.
            // Intentionally unbounded; each re-arm invalidates the previous timer,
            // so deferral never accumulates timers.
            if self.isMouseInMenuBar || self.isPreferencesWindowVisible {
                self.startTimerToAutoHide()
            } else {
                self.collapseMenuBar()
            }
        }
    }
    
    private func getContextMenu() -> NSMenu {
        let menu = NSMenu()
        
        let prefItem = NSMenuItem(title: "Preferences...".localized, action: #selector(openPreferenceViewControllerIfNeeded), keyEquivalent: "P")
        prefItem.target = self
        menu.addItem(prefItem)
        
        let toggleAutoHideItem = NSMenuItem(title: "Toggle Auto Collapse".localized, action: #selector(toggleAutoHide), keyEquivalent: "t")
        toggleAutoHideItem.target = self
        toggleAutoHideItem.tag = 1
        NotificationCenter.default.addObserver(self, selector: #selector(updateAutoHide), name: .prefsChanged, object: nil)
        menu.addItem(toggleAutoHideItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit".localized, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        return menu
    }
    
    private func updateAutoCollapseMenuTitle() {
        guard let toggleAutoHideItem = btnSeparate.menu?.item(withTag: 1) else { return }
        if Preferences.isAutoHide {
            toggleAutoHideItem.title = "Disable Auto Collapse".localized
        } else {
            toggleAutoHideItem.title = "Enable Auto Collapse".localized
        }
    }
    
    @objc func updateAutoHide() {
        updateAutoCollapseMenuTitle()
        autoCollapseIfNeeded()
    }
    
    @objc func openPreferenceViewControllerIfNeeded() {
        Util.showPrefWindow()
    }
    
    @objc func toggleAutoHide() {
        Preferences.isAutoHide.toggle()
    }
}


//MARK: - Alway hide feature
extension StatusBarController {
    private func setupAlwayHideStatusBar() {
        NotificationCenter.default.addObserver(self, selector: #selector(toggleStatusBarIfNeeded), name: .alwayHideToggle, object: nil)
        toggleStatusBarIfNeeded()
    }
    @objc private func toggleStatusBarIfNeeded() {
        updateCollapsedLengths()

        if Preferences.alwaysHiddenSectionEnabled {
            if usesOverflowHiding { alwaysHiddenFillerChain.remove() }
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = StatusBarController.makeStatusItem(length: btnAlwaysHiddenLength,
                                                                      autosaveName: StatusBarController.alwaysHiddenAutosaveName,
                                                                      freshKey: StatusBarController.freshAlwaysHiddenKey)
            if let button = btnAlwaysHidden?.button {
                button.image = self.imgIconLine
                button.appearsDisabled = true
            }
            self.btnAlwaysHidden?.isVisible = true
            if usesOverflowHiding {
                // A new separator has a new key; the chain waits for it to land.
                alwaysHiddenFillerChain.invalidateCache()
                if !isCollapsed && Preferences.areSeparatorsHidden {
                    alwaysHiddenFillerChain.insert()
                }
            }
        } else {
            if usesOverflowHiding { alwaysHiddenFillerChain.remove() }
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = nil
        }
    }
}

// MARK: - FillerChainHost

extension StatusBarController: FillerChainHost {
    typealias Item = NSStatusItem

    // Every filler and probe gets a name MenuBarAgent has never seen. It
    // remembers the position of any item that was on the bar during a Cmd-drag,
    // by name, and from then on ignores the item's key; a reused name would pin
    // the filler to wherever it sat during some earlier collapse. The key is
    // removed from defaults once the item exists (macOS reads it when the name
    // is assigned), so unique names do not accumulate there.
    func makeItem(prefix: String, key: Double, length: CGFloat) -> NSStatusItem {
        let name = "\(prefix)_\(UUID().uuidString)"
        let defaultsKey = StatusBarController.positionKeyPrefix + name
        UserDefaults.standard.set(key, forKey: defaultsKey)
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = name
        item.button?.isEnabled = false
        item.button?.appearsDisabled = true
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return item
    }

    func removeItem(_ item: NSStatusItem) {
        NSStatusBar.system.removeStatusItem(item)
    }

    func setLength(_ length: CGFloat, of item: NSStatusItem) {
        item.length = length
    }

    func frame(of item: NSStatusItem) -> CGRect? {
        return frameOf(item)
    }

    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    func log(_ message: String) {
        NSLog("HiddenBar27: %@", message)
    }
}
