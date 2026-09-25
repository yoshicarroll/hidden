//
//  StatusBarController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/30/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit
import os.log

class StatusBarController {
    // Diagnostics for the macOS 27 mechanism. Read with
    //   log show --last 2h --predicate 'subsystem == "com.dwarvesv.minimalbar"' --style compact
    // (notice level persists; see docs/RUNBOOK.md).
    static let diagnostics = Logger(subsystem: "com.dwarvesv.minimalbar", category: "macOS27")
    private var stateAuditTimer: Timer?
    private var screenChangeTimer: Timer?
    private var placementRetryTimer: Timer?
    // Delays before retrying a collapse whose fillers could not be placed. A
    // display reconfiguration (wake, hot-plug) re-lays every bar for a second or
    // two, during which frames are unreliable; giving up on the first failure
    // left the bar expanded after wake.
    private static let placementRetryDelays: [TimeInterval] = [2, 5, 10, 20, 30]
    
    //MARK: - Variables
    private var timer:Timer? = nil
    
    //MARK: - BarItems
        
    // On macOS 27 the position key must be in defaults and the autosave name set
    // at creation, before the button is configured; assigning the name later
    // leaves the item where macOS first put it (measured, see the 27 notes below).
    // `var` only so healArrowPosition() can re-register it under a fresh name.
    private var btnExpandCollapse = StatusBarController.makeStatusItem(length: NSStatusItem.variableLength,
                                                                        autosaveName: StatusBarController.currentArrowAutosaveName,
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
    // macOS 27 remembers an item's position by autosave name and offers no way to
    // move it. When the arrow ends up left of the separator (a stale arrangement
    // from an older build, or MenuBarAgent re-keying it), the only way to put it
    // back is to register it under a name MenuBarAgent has never seen, at a key
    // found right of the separator. The generation persists so the arrow keeps
    // that name, and the position the user gives it, across launches.
    private static let arrowNameGenerationKey = "hiddenbar_arrowNameGeneration"
    private static var currentArrowAutosaveName: String {
        let generation = UserDefaults.standard.integer(forKey: arrowNameGenerationKey)
        return generation == 0 ? expandCollapseAutosaveName : "\(expandCollapseAutosaveName)_\(generation)"
    }
    private var arrowHealAttempted = false
    private var arrowSpacingAttempted = false
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
        if usesOverflowHiding {
            // Frames may come from different displays; compare in one screen space.
            guard let e = frameOf(btnExpandCollapse), let s = frameOf(btnSeparate) else { return false }
            return Constant.isUsingLTRLanguage ? e.minX >= s.minX : e.minX <= s.minX
        }
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
        if usesOverflowHiding { setupDiagnostics() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            if self.usesOverflowHiding && !self.isBtnSeparateValidPosition {
                self.healArrowPosition { self.collapseMenuBar(reason: "launch") }
            } else {
                self.collapseMenuBar(reason: "launch")
            }
        }
        
        if Preferences.areSeparatorsHidden {hideSeparators()}
        autoCollapseIfNeeded()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stateAuditTimer?.invalidate()
        screenChangeTimer?.invalidate()
        placementRetryTimer?.invalidate()
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
                    self.expandMenubar(reason: "hover")
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
            let screens = NSScreen.screens.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" }.joined(separator: " ")
            StatusBarController.diagnostics.notice("screens changed: [\(screens, privacy: .public)] collapsed=\(wasCollapsed)")
            // Displays come and go in bursts (wake, hot-plug) and MenuBarAgent
            // re-lays every bar meanwhile; act once the configuration has been
            // stable for a moment.
            screenChangeTimer?.invalidate()
            screenChangeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.rebuildFillersAfterScreenChange()
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
        
        configureExpandCollapseButton()
        
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
        
        if self.isCollapsed {self.expandMenubar(reason: "separators toggled")}
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
            if !isCollapsed && alwaysHiddenFillersWanted { alwaysHiddenFillerChain.insert() }
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
        self.isCollapsed ? self.expandMenubar(reason: "arrow") : self.collapseMenuBar(reason: "arrow")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }
    
    private func collapseMenuBar(reason: String) {
        guard self.isBtnSeparateValidPosition && !self.isCollapsed else {
            if usesOverflowHiding {
                StatusBarController.diagnostics.notice("collapse skipped (\(reason, privacy: .public)): validPosition=\(self.isBtnSeparateValidPosition) collapsed=\(self.isCollapsed)")
                if !isCollapsed && !isBtnSeparateValidPosition && !arrowHealAttempted {
                    healArrowPosition { [weak self] in self?.collapseMenuBar(reason: reason) }
                    return
                }
            }
            autoCollapseIfNeeded()
            return
        }
        if usesOverflowHiding { StatusBarController.diagnostics.notice("collapse (\(reason, privacy: .public))") }

        if usesOverflowHiding {
            // The always-hidden fillers would only add blank rows to the overflow
            // menu, since everything left of the chain ends up in there anyway.
            alwaysHiddenFillerChain.remove()
            // Collapsed state is set now so a second click or the auto-collapse
            // timer cannot start a rival placement; a failed placement rolls it
            // back (rollBackFailedCollapse).
            isCollapsedByOverflow = true
            placeFillersWithRetry(attempt: 0, reason: reason)
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
    private func expandMenubar(reason: String) {
        guard self.isCollapsed else {return}
        if usesOverflowHiding { StatusBarController.diagnostics.notice("expand (\(reason, privacy: .public))") }
        if usesOverflowHiding {
            placementRetryTimer?.invalidate()
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

    // Filler geometry is derived from the display set, so rebuild whichever chain
    // is in use: the regular one while collapsed, the always-hidden one while
    // expanded (collapsing takes that section down anyway).
    private func rebuildFillersAfterScreenChange() {
        StatusBarController.diagnostics.notice("screens settled; rebuilding fillers (collapsed=\(self.isCollapsed))")
        if isCollapsed {
            fillerChain.remove()
            placeFillersWithRetry(attempt: 0, reason: "screens changed")
        } else if alwaysHiddenFillersWanted {
            alwaysHiddenFillerChain.remove()
            alwaysHiddenFillerChain.insert()
        }
    }

    // Place the regular fillers; on failure retry with backoff while the bar is
    // still meant to be collapsed, and only then roll back to expanded.
    private func placeFillersWithRetry(attempt: Int, reason: String) {
        placementRetryTimer?.invalidate()
        fillerChain.insert { [weak self] ok in
            guard let self = self, self.isCollapsedByOverflow else { return }
            if ok {
                if attempt > 0 { StatusBarController.diagnostics.notice("fillers placed on retry \(attempt) (\(reason, privacy: .public))") }
                return
            }
            guard attempt < StatusBarController.placementRetryDelays.count else {
                self.rollBackFailedCollapse()
                return
            }
            // A tight bracket means the arrow's key crowds the separator's (it was
            // re-keyed to the boundary at some re-insertion); make room first.
            if let bracket = self.fillerChain.lastFailedBracket, bracket.hi - bracket.lo < 2, !self.arrowSpacingAttempted {
                self.arrowSpacingAttempted = true
                self.spaceArrowKey(below: bracket.lo) { [weak self] in
                    guard let self = self, self.isCollapsedByOverflow else { return }
                    self.fillerChain.remove()
                    self.placeFillersWithRetry(attempt: attempt, reason: reason)
                }
                return
            }
            let delay = StatusBarController.placementRetryDelays[attempt]
            StatusBarController.diagnostics.notice("filler placement failed (\(reason, privacy: .public)); retry \(attempt + 1) in \(Int(delay))s")
            self.placementRetryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self = self, self.isCollapsedByOverflow else { return }
                self.fillerChain.remove()
                self.placeFillersWithRetry(attempt: attempt + 1, reason: reason)
            }
        }
    }

    // MARK: macOS 27 arrow healing

    // The arrow is left of the separator, so nothing can be hidden. Re-register
    // it under a fresh autosave name at a key immediately right of the separator
    // (found with the filler chain's probe search), then rebuild the button.
    // Once per launch; if the search fails the arrangement is left for the user
    // to fix by dragging, as before.
    private func healArrowPosition(completion: @escaping () -> Void) {
        guard !arrowHealAttempted else { completion(); return }
        arrowHealAttempted = true
        StatusBarController.diagnostics.error("arrow is left of the separator: arrow=\(String(describing: self.frameOf(self.btnExpandCollapse)), privacy: .public) separator=\(String(describing: self.frameOf(self.btnSeparate)), privacy: .public); re-registering it right of the separator")
        fillerChain.locateKey { [weak self] key in
            guard let self = self else { return }
            guard let key = key else {
                StatusBarController.diagnostics.error("arrow healing: no key found right of the separator; leaving the arrangement for the user to fix")
                completion()
                return
            }
            let generation = UserDefaults.standard.integer(forKey: StatusBarController.arrowNameGenerationKey) + 1
            UserDefaults.standard.set(generation, forKey: StatusBarController.arrowNameGenerationKey)
            let name = StatusBarController.currentArrowAutosaveName
            NSStatusBar.system.removeStatusItem(self.btnExpandCollapse)
            UserDefaults.standard.set(key, forKey: StatusBarController.positionKeyPrefix + name)
            self.btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.btnExpandCollapse.autosaveName = name
            self.configureExpandCollapseButton()
            self.fillerChain.invalidateCache()
            StatusBarController.diagnostics.notice("arrow re-registered as \(name, privacy: .public) at key \(key)")
            // Let it land before anything measures it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                StatusBarController.diagnostics.notice("arrow healing result: validPosition=\(self.isBtnSeparateValidPosition) arrow=\(String(describing: self.frameOf(self.btnExpandCollapse)), privacy: .public) separator=\(String(describing: self.frameOf(self.btnSeparate)), privacy: .public)")
                completion()
            }
        }
    }

    // Re-register the arrow a few key units below `lo` (a key known to sort right
    // of the separator), so fillers have room between the separator and the
    // arrow. Tries decreasing distances and keeps the first placement that lands
    // the arrow right of the separator with at most one small item between.
    private func spaceArrowKey(below lo: Double, completion: @escaping () -> Void) {
        let candidates: [Double] = [lo - 4, lo - 1, lo - 0.25]
        func attempt(_ index: Int) {
            guard index < candidates.count else {
                StatusBarController.diagnostics.error("arrow spacing: no candidate key landed the arrow next to the separator; giving up")
                completion()
                return
            }
            let key = candidates[index]
            let generation = UserDefaults.standard.integer(forKey: StatusBarController.arrowNameGenerationKey) + 1
            UserDefaults.standard.set(generation, forKey: StatusBarController.arrowNameGenerationKey)
            let name = StatusBarController.currentArrowAutosaveName
            NSStatusBar.system.removeStatusItem(self.btnExpandCollapse)
            UserDefaults.standard.set(key, forKey: StatusBarController.positionKeyPrefix + name)
            self.btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.btnExpandCollapse.autosaveName = name
            self.configureExpandCollapseButton()
            self.fillerChain.invalidateCache()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                let ok: Bool = {
                    guard let a = self.frameOf(self.btnExpandCollapse), let s = self.frameOf(self.btnSeparate) else { return false }
                    return a.minX >= s.maxX - 1 && (a.minX - s.maxX) <= StatusBarController.smallSystemItemAllowance
                }()
                StatusBarController.diagnostics.notice("arrow spacing: re-registered as \(name, privacy: .public) at key \(key) -> \(ok ? "next to the separator" : "not next to the separator") arrow=\(String(describing: self.frameOf(self.btnExpandCollapse)), privacy: .public) separator=\(String(describing: self.frameOf(self.btnSeparate)), privacy: .public)")
                if ok { completion() } else { attempt(index + 1) }
            }
        }
        attempt(0)
    }

    private func configureExpandCollapseButton() {
        guard let button = btnExpandCollapse.button else { return }
        button.image = isCollapsed ? Assets.expandImage : Assets.collapseImage
        button.target = self
        button.action = #selector(self.btnExpandCollapsePressed(sender:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: macOS 27 diagnostics

    private func setupDiagnostics() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, label) in [(NSWorkspace.willSleepNotification, "will sleep"), (NSWorkspace.didWakeNotification, "did wake"),
                              (NSWorkspace.screensDidSleepNotification, "screens did sleep"), (NSWorkspace.screensDidWakeNotification, "screens did wake"),
                              (NSWorkspace.activeSpaceDidChangeNotification, "active space changed")] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                StatusBarController.diagnostics.notice("\(label, privacy: .public): collapsed=\(self.isCollapsed) fillers=\(self.fillerChain.items.count) inFlight=\(self.fillerChain.isInFlight)")
            }
        }
        // MenuBarAgent hosts the bar; if it relaunches, every item is re-registered.
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.MenuBarAgent", let self = self else { return }
            StatusBarController.diagnostics.error("MenuBarAgent relaunched (pid \(app.processIdentifier)): collapsed=\(self.isCollapsed) fillers=\(self.fillerChain.items.count)")
        }
        stateAuditTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.auditCollapsedState()
        }
    }

    // While collapsed, the filler next to the arrow should still be close to it:
    // adjacent, or separated only by a small system item such as the dynamic
    // "Audio and Video Controls" (about 40pt with spacing). Anything else means
    // the system re-laid the bar under us. This audit only logs; acting on it
    // (clearing and re-setting the arrow image) was tried and it pushed the
    // arrow into the overflow, so it must never touch the bar.
    private func auditCollapsedState() {
        guard isCollapsed, !fillerChain.isInFlight else { return }
        guard let farthest = fillerChain.items.last else {
            StatusBarController.diagnostics.error("audit: collapsed but no fillers on the bar")
            return
        }
        guard let f = frameOf(farthest), let e = frameOf(btnExpandCollapse) else {
            StatusBarController.diagnostics.notice("audit: collapsed; frames unavailable: filler=\(String(describing: self.frameOf(farthest)), privacy: .public) arrow=\(String(describing: self.frameOf(self.btnExpandCollapse)), privacy: .public)")
            return
        }
        let gap = e.minX - f.maxX
        if !(isAdjacent(left: f, right: e) || (gap > 0 && gap <= 72)) {
            let fs = farthest.button?.window?.screen.map { Int($0.frame.minX) } ?? -1, es = btnExpandCollapse.button?.window?.screen.map { Int($0.frame.minX) } ?? -1
            StatusBarController.diagnostics.error("audit: collapsed but the filler next to the arrow is far from it: filler=\(Int(f.minX))-\(Int(f.maxX)) (screen \(fs)) arrow=\(Int(e.minX))-\(Int(e.maxX)) (screen \(es))")
        }
    }

    // MARK: macOS 27 filler chains

    private var alwaysHiddenFillersWanted: Bool {
        return Preferences.alwaysHiddenSectionEnabled && Preferences.areSeparatorsHidden && btnAlwaysHidden != nil
    }

    private func setupFillerChains() {
        // The regular chain accepts either reference: the filler nearest the
        // separator right next to it, or the filler farthest from it right next
        // to the arrow. On a crowded bar the fillers push the separator itself
        // into the overflow (the intended result) and its frame goes stale; on a
        // notched display the system's overflow chevron can sit between the
        // fillers and the arrow. One of the two is always usable.
        fillerChain = makeFillerChain(prefix: "hiddenbar_fill", anchor: { [weak self] in self?.btnSeparate },
                                      placement: { [weak self] probe, separator in self?.placementBetweenSeparatorAndArrow(probe: probe, separator: separator) ?? .unknown },
                                      validate: { [weak self] nearest, farthest in
                                          guard let self = self else { return false }
                                          if let n = self.frameOf(nearest), let a = self.frameOf(self.btnSeparate), self.placementBetweenSeparatorAndArrow(probe: n, separator: a) == .between { return true }
                                          if let f = self.frameOf(farthest), let e = self.frameOf(self.btnExpandCollapse), self.isAdjacent(left: f, right: e) { return true }
                                          StatusBarController.diagnostics.notice("validate: separator \(String(describing: self.frameOf(self.btnSeparate)), privacy: .public) nearest \(String(describing: self.frameOf(nearest)), privacy: .public) farthest \(String(describing: self.frameOf(farthest)), privacy: .public) arrow \(String(describing: self.frameOf(self.btnExpandCollapse)), privacy: .public)")
                                          return false
                                      })
        // The always-hidden chain's right-hand neighbour belongs to another app,
        // so it keeps the default check against its own separator.
        alwaysHiddenFillerChain = makeFillerChain(prefix: "hiddenbar_ahfill", anchor: { [weak self] in self?.btnAlwaysHidden }, placement: nil, validate: nil)
    }

    private func makeFillerChain(prefix: String, anchor: @escaping () -> NSStatusItem?,
                                 placement: ((CGRect, CGRect) -> FillerPlacement)?,
                                 validate: ((NSStatusItem, NSStatusItem) -> Bool)?) -> FillerChain<StatusBarController> {
        return FillerChain(host: self, prefix: prefix, anchor: anchor,
                           geometry: { [weak self] in self?.fillerGeometry() ?? .init(lengths: [100]) },
                           // Just below the anchor's geometric key is the natural
                           // first guess (larger keys sort further left).
                           initialGuess: { [weak self] anchorFrame in (self?.geometricPositionKey(ofFrame: anchorFrame) ?? 0) - 18 },
                           placement: placement ?? { [weak self] probe, anchor in self?.placement(ofProbe: probe, rightOf: anchor) ?? .unknown },
                           validate: validate)
    }

    // A collapse whose fillers could not be placed: undo the collapsed state so
    // the arrow, activation policy and auto-collapse timer match the bar, which
    // still shows everything.
    private func rollBackFailedCollapse() {
        guard isCollapsedByOverflow else { return }
        StatusBarController.diagnostics.error("collapse failed, rolling back to expanded")
        isCollapsedByOverflow = false
        btnExpandCollapse.button?.image = Assets.collapseImage
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
        }
        if alwaysHiddenFillersWanted { alwaysHiddenFillerChain.insert() }
        autoCollapseIfNeeded()
    }

    // Filler lengths in layout order (next to the arrow first). Every display gets one filler
    // sized just under its own drop cliff (half its width, with the 64pt margin
    // upstream measured against), in ascending order, so on each display the
    // fillers under its cliff fill the free space and the first that does not
    // fit carries the rest into the overflow; longer ones are dropped there and
    // change nothing. The ladder is then padded with the widest display's length
    // until the total exceeds the widest display.
    //
    // Making the later fillers as long as the widest display allows also keeps
    // the system's overflow chevron away: MenuBarAgent shows it when the first
    // item that does not fit still lands partly on screen, and does not when
    // that item would start left of the screen edge (measured; see
    // docs/ARCHITECTURE.md).
    private func fillerGeometry() -> FillerChain<StatusBarController>.Geometry {
        let widths = Set(NSScreen.screens.map { $0.frame.width }).sorted()
        let cliffLengths = widths.map { max(100, ($0 / 2 - 64).rounded(.down)) }
        guard let longest = cliffLengths.last, let widest = widths.last else {
            return .init(lengths: [800, 800, 800])
        }
        var lengths = cliffLengths
        while lengths.reduce(0, +) <= widest { lengths.append(longest) }
        lengths.append(longest)
        return .init(lengths: lengths)
    }

    // An item's app-side window sits on whichever display was active when the
    // item was created, and stays there. Items created at different times can
    // therefore report frames from different displays, which made probe-versus-
    // separator comparisons meaningless (the search bisected to nothing whenever
    // the user had moved to another display since launch). The trailing items are
    // right-aligned identically on every bar, so every frame is translated into
    // the separator's screen by its offset from the right edge before use.
    private var referenceScreen: NSScreen? {
        return btnSeparate.button?.window?.screen ?? NSScreen.main
    }

    private func frameOf(_ item: NSStatusItem?) -> CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        var frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        // A freshly created item reports a placeholder frame near the origin, with
        // no screen, until MenuBarAgent lays it out; only a frame on a screen and
        // inside that screen's menu bar strip is a real position.
        guard let itemScreen = window.screen else { return nil }
        let strip = CGRect(x: itemScreen.frame.minX, y: itemScreen.visibleFrame.maxY - 1,
                           width: itemScreen.frame.width, height: itemScreen.frame.maxY - itemScreen.visibleFrame.maxY + 2)
        guard strip.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        if let reference = referenceScreen, itemScreen != reference {
            frame.origin.x += reference.frame.maxX - itemScreen.frame.maxX
            frame.origin.y += reference.frame.maxY - itemScreen.frame.maxY
        }
        return frame
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

    // For the regular chain: MenuBarAgent attaches small system items ("Now
    // Playing", "Audio and Video Controls", 16-20pt) right next to the
    // separator, so a probe can never be strictly adjacent to it then. Accept a
    // probe right of the separator with room for one such item in between, as
    // long as it is still left of the arrow: anything keyed between the
    // separator and the arrow hides exactly the icons left of the separator.
    private static let smallSystemItemAllowance: CGFloat = 72
    private func placementBetweenSeparatorAndArrow(probe: CGRect, separator: CGRect) -> FillerPlacement {
        if probe.maxX <= separator.minX + 1 { return .tooFarLeft }
        guard probe.minX >= separator.maxX - 1 else { return .unknown }
        if let arrow = frameOf(btnExpandCollapse), probe.minX >= arrow.maxX - 1 { return .tooFarRight }
        let gap = probe.minX - separator.maxX
        return (isAdjacent(left: separator, right: probe) || gap <= StatusBarController.smallSystemItemAllowance) ? .between : .tooFarRight
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
                self.collapseMenuBar(reason: "auto-collapse timer")
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
        StatusBarController.diagnostics.notice("\(message, privacy: .public)")
    }

    func debugDescription(of item: NSStatusItem) -> String {
        guard let button = item.button, let window = button.window else { return " [no window]" }
        let raw = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))" } ?? "nil"
        let sepScreen = btnSeparate.button?.window?.screen.map { "\(Int($0.frame.minX))" } ?? "nil"
        return " [raw \(Int(raw.minX))-\(Int(raw.maxX)) y=\(Int(raw.minY)) screen \(screen); separator screen \(sepScreen)]"
    }
}
