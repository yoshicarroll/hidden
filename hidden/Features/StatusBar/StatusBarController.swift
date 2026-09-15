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
    //     is found by bisection with a probe item (see insertFillers). Our own
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
    private var fillers: [NSStatusItem] = []
    private var alwaysHiddenFillers: [NSStatusItem] = []
    private var fillerKeyCache: Double?
    private var alwaysHiddenFillerKeyCache: Double?
    // Bumped whenever fillers are torn down, so an in-flight key search or
    // layout wait from a previous collapse cannot act on a stale state.
    private var fillerGeneration = 0
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
            // Filler geometry is derived from the display set, so rebuild the chain.
            if wasCollapsed { removeFillers(); insertFillers() }
            if alwaysHiddenFillersWanted { removeAlwaysHiddenFillers(); insertAlwaysHiddenFillers() }
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
        if true {

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
            removeAlwaysHiddenFillers()
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
            if !isCollapsed { insertAlwaysHiddenFillers() }
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
            removeAlwaysHiddenFillers()
            insertFillers()
            isCollapsedByOverflow = true
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
            removeFillers()
            isCollapsedByOverflow = false
            if alwaysHiddenFillersWanted { insertAlwaysHiddenFillers() }
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

    // MARK: macOS 27 fillers

    private var alwaysHiddenFillersWanted: Bool {
        return Preferences.alwaysHiddenSectionEnabled && Preferences.areSeparatorsHidden && btnAlwaysHidden != nil
    }

    // Filler length stays under the drop cliff (half the display width) of the
    // narrowest display, with the same 64pt margin upstream measured against.
    // Enough fillers to exceed the widest display guarantee that, on every bar,
    // at least one filler fails to fit and carries the rest into the overflow.
    private func fillerGeometry() -> (length: CGFloat, count: Int) {
        let widths = NSScreen.screens.map { $0.frame.width }
        let narrowest = widths.min() ?? 1728
        let widest = widths.max() ?? narrowest
        let length = max(100, (narrowest / 2 - 64).rounded(.down))
        let count = Int((widest / length).rounded(.up)) + 1
        return (length, count)
    }

    // Every filler gets a name MenuBarAgent has never seen. It remembers the
    // position of any item that was on the bar during a Cmd-drag, by name, and
    // from then on ignores the item's key; a reused name would pin the filler to
    // wherever it sat during some earlier collapse. The key is removed from
    // defaults once the item exists (macOS reads it when the name is assigned),
    // so unique names do not accumulate there.
    private func makeFiller(prefix: String, key: Double, length: CGFloat) -> NSStatusItem {
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

    // Where a probe item landed relative to the anchor pair it should sit between.
    private enum ProbePlacement { case between, tooFarRight, tooFarLeft, unknown }

    private func frameOf(_ item: NSStatusItem?) -> CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // Poll until the given items' frames stop changing (layout is asynchronous,
    // hosted in MenuBarAgent), then call back. Bounded to about a second.
    private func waitForLayout(of items: [NSStatusItem], generation: Int, _ done: @escaping () -> Void) {
        var last = items.map { frameOf($0) }
        var stable = 0
        var polls = 0
        func poll() {
            guard generation == self.fillerGeneration else { return }
            polls += 1
            let now = items.map { self.frameOf($0) }
            if now == last { stable += 1 } else { stable = 0; last = now }
            if stable >= 2 || polls >= 20 { done(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
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

    // Fillers must sort immediately right of the separator (between it and
    // whatever follows, normally the expand button). The ordering key
    // MenuBarAgent holds for the separator is not readable and, after drags on
    // another display, does not match the geometric formula, so the key is found
    // by bisection: a probe is inserted at a guess and its landing spot (left of
    // the separator, right of it but not adjacent, or adjacent) steers the next
    // guess. Frames are read from whichever display is active, which is
    // consistent within one search. The result is cached and tried first, so a
    // collapse normally costs one layout pass.
    private func placementRightOfSeparator(_ probe: NSStatusItem) -> ProbePlacement {
        guard let p = frameOf(probe), let s = frameOf(btnSeparate) else { return .unknown }
        if p.maxX <= s.minX + 1 { return .tooFarLeft }
        if p.minX >= s.maxX - 1 { return isAdjacent(left: s, right: p) ? .between : .tooFarRight }
        return .unknown
    }

    // The always-hidden fillers sit immediately right of the always-hidden
    // separator; the neighbour on the other side belongs to another app, so
    // "between" is judged by adjacency to that separator.
    private func placementRightOfAlwaysHidden(_ probe: NSStatusItem) -> ProbePlacement {
        guard let p = frameOf(probe), let a = frameOf(btnAlwaysHidden) else { return .unknown }
        if p.maxX <= a.minX + 1 { return .tooFarLeft }
        if p.minX >= a.maxX - 1 { return isAdjacent(left: a, right: p) ? .between : .tooFarRight }
        return .unknown
    }

    private func findKey(startingAt initial: Double, probeName: String, generation: Int,
                         placement: @escaping (NSStatusItem) -> ProbePlacement,
                         completion: @escaping (Double?) -> Void) {
        var lo: Double? = nil
        var hi: Double? = nil
        var step = 40.0
        var guess = initial
        var attempts = 0
        func attempt() {
            guard generation == self.fillerGeneration else { return }
            attempts += 1
            let probe = self.makeFiller(prefix: probeName, key: guess, length: 8)
            self.waitForLayout(of: [self.btnExpandCollapse, self.btnSeparate, probe], generation: generation) {
                let result = placement(probe)
                NSStatusBar.system.removeStatusItem(probe)
                switch result {
                case .between:
                    completion(guess)
                    return
                case .tooFarRight: lo = guess
                case .tooFarLeft: hi = guess
                case .unknown: break
                }
                if attempts >= 12 {
                    NSLog("HiddenBar27: key search %@ gave up after %d attempts (lo=%@ hi=%@)", probeName, attempts, String(describing: lo), String(describing: hi))
                    completion(nil)
                    return
                }
                if let l = lo, let h = hi {
                    guess = (l + h) / 2
                } else if let l = lo {
                    guess = l + step; step *= 2
                } else if let h = hi {
                    guess = h - step; step *= 2
                }
                // Let the probe's removal settle before the next insertion.
                self.waitForLayout(of: [self.btnExpandCollapse, self.btnSeparate], generation: generation) { attempt() }
            }
        }
        attempt()
    }

    private func insertFillers() {
        guard fillers.isEmpty else { return }
        let generation = fillerGeneration
        let geometry = fillerGeometry()
        // Fast path: with a cached key the fillers are placed directly and their
        // landing spot validated, one layout pass fewer than probing first.
        if let cached = fillerKeyCache {
            placeFillers(at: cached, geometry: geometry, generation: generation) { [weak self] placed in
                guard let self = self, generation == self.fillerGeneration else { return }
                if placed { return }
                self.fillerKeyCache = nil
                self.fillers.forEach { NSStatusBar.system.removeStatusItem($0) }
                self.fillers = []
                self.waitForLayout(of: [self.btnSeparate, self.btnExpandCollapse], generation: generation) { self.insertFillers() }
            }
            return
        }
        // Just below the separator's geometric key is the natural first guess
        // (larger keys sort further left).
        let initial = (geometricPositionKey(btnSeparate) ?? 0) - 18
        findKey(startingAt: initial, probeName: "hiddenbar_fillprobe", generation: generation,
                placement: { [weak self] probe in self?.placementRightOfSeparator(probe) ?? .unknown }) { [weak self] key in
            guard let self = self, generation == self.fillerGeneration, self.fillers.isEmpty else { return }
            guard let key = key else { NSLog("HiddenBar27: no key found right of the separator; nothing hidden"); return }
            self.placeFillers(at: key, geometry: geometry, generation: generation) { [weak self] placed in
                guard let self = self, generation == self.fillerGeneration else { return }
                if placed { self.fillerKeyCache = key } else { NSLog("HiddenBar27: fillers did not land right of the separator at key %.3f", key) }
            }
        }
    }

    // An item that does not fit at insertion is re-keyed by macOS to the
    // overflow boundary instead of taking its key, whereas resizing an existing
    // item keeps its key. So the fillers appear at a width that fits, are
    // checked (the leftmost one must sit right next to the separator), and are
    // then grown to their real length.
    private func placeFillers(at key: Double, geometry: (length: CGFloat, count: Int), generation: Int, completion: @escaping (Bool) -> Void) {
        fillers = (0..<geometry.count).map { i in
            makeFiller(prefix: "hiddenbar_fill", key: key + 0.001 * Double(i + 1), length: 8)
        }
        waitForLayout(of: fillers + [btnSeparate], generation: generation) {
            guard generation == self.fillerGeneration, let leftmost = self.fillers.last else { return }
            guard self.placementRightOfSeparator(leftmost) == .between else { completion(false); return }
            self.fillers.forEach { $0.length = geometry.length }
            completion(true)
        }
    }

    private func removeFillers() {
        fillerGeneration += 1
        fillers.forEach { NSStatusBar.system.removeStatusItem($0) }
        fillers = []
    }

    private func insertAlwaysHiddenFillers() {
        guard alwaysHiddenFillers.isEmpty, alwaysHiddenFillersWanted, let alwaysHidden = btnAlwaysHidden else { return }
        let generation = fillerGeneration
        let geometry = fillerGeometry()
        let initial = alwaysHiddenFillerKeyCache ?? ((geometricPositionKey(alwaysHidden) ?? 0) - 18)
        findKey(startingAt: initial, probeName: "hiddenbar_ahfillprobe", generation: generation,
                placement: { [weak self] probe in self?.placementRightOfAlwaysHidden(probe) ?? .unknown }) { [weak self] key in
            guard let self = self, generation == self.fillerGeneration, self.alwaysHiddenFillers.isEmpty, self.alwaysHiddenFillersWanted else { return }
            guard let key = key else { self.alwaysHiddenFillerKeyCache = nil; return }
            self.alwaysHiddenFillers = (0..<geometry.count).map { i in
                self.makeFiller(prefix: "hiddenbar_ahfill", key: key - 0.001 * Double(i + 1), length: 8)
            }
            self.waitForLayout(of: self.alwaysHiddenFillers + [alwaysHidden], generation: generation) {
                guard generation == self.fillerGeneration, let rightmost = self.alwaysHiddenFillers.first else { return }
                guard self.placementRightOfAlwaysHidden(rightmost) == .between else {
                    NSLog("HiddenBar27: always-hidden fillers did not land right of their separator at key %.3f", key)
                    self.alwaysHiddenFillerKeyCache = nil
                    self.removeAlwaysHiddenFillers()
                    return
                }
                self.alwaysHiddenFillerKeyCache = key
                self.alwaysHiddenFillers.forEach { $0.length = geometry.length }
            }
        }
    }

    private func removeAlwaysHiddenFillers() {
        fillerGeneration += 1
        alwaysHiddenFillers.forEach { NSStatusBar.system.removeStatusItem($0) }
        alwaysHiddenFillers = []
    }

    // MARK: macOS 27 position keys

    private func savedPositionKey(_ autosaveName: String) -> Double? {
        return UserDefaults.standard.object(forKey: StatusBarController.positionKeyPrefix + autosaveName) as? Double
    }

    private func setPositionKey(_ key: Double, for autosaveName: String) {
        UserDefaults.standard.set(key, forKey: StatusBarController.positionKeyPrefix + autosaveName)
    }

    // Creates a status item with its autosave name assigned immediately. On
    // macOS 27 a missing position key is seeded first (a previous launch of this
    // build leaves the real one; a fresh install gets the leftmost placement).
    private static func makeStatusItem(length: CGFloat, autosaveName: String, freshKey: Double) -> NSStatusItem {
        if #available(macOS 27.0, *) {
            let key = positionKeyPrefix + autosaveName
            if UserDefaults.standard.object(forKey: key) as? Double == nil {
                UserDefaults.standard.set(freshKey, forKey: key)
            }
        }
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = autosaveName
        return item
    }

    // The key macOS 27 derives for an item: display right edge - 40 - item right
    // edge, measured on the display that hosts the item's window.
    private func geometricPositionKey(_ item: NSStatusItem?) -> Double? {
        guard let button = item?.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
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
                removeAlwaysHiddenFillers()
                if !isCollapsed && Preferences.areSeparatorsHidden {
                    // Let the new separator land before deriving filler keys from it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.insertAlwaysHiddenFillers()
                    }
                }
            }
        } else {
            removeAlwaysHiddenFillers()
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = nil
        }
    }
}
