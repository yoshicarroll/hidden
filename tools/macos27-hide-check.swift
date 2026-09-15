// macos27-hide-check.swift
//
// Verifies Hidden Bar's collapse behaviour on macOS 27 without screenshots, by
// reading what MenuBarAgent (the process that owns the macOS 27 menu bar)
// actually hosts on each display's bar. Items in the native overflow are absent
// from that list, while their own apps' accessibility trees keep reporting
// stale positions, so MenuBarAgent's tree is the reliable signal.
//
// Usage (needs Accessibility permission for the terminal, e.g. under
// System Settings > Privacy & Security > Accessibility):
//
//   swift tools/macos27-hide-check.swift                      # dump hosted items per display
//   swift tools/macos27-hide-check.swift --press              # toggle Hidden Bar via an accessibility press, then dump
//   swift tools/macos27-hide-check.swift --expect-hidden Magnet 1Password   # exit 1 if any is on a bar
//   swift tools/macos27-hide-check.swift --expect-visible Magnet 1Password  # exit 1 if any is missing
//
// Names are the owning apps' names as shown in the dump. On the display that
// hosts the active menu bar, MenuBarAgent's nodes carry no owner and the tool
// matches them to the apps' own accessibility items by position, which can lag
// briefly after a toggle; the other displays are labelled exactly. Adapted from
// the verification technique described in dwarvesf/hidden#392.

import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IONBF, 0)

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return v
}

func rect(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let pr = attr(e, kAXPositionAttribute) { AXValueGetValue(pr as! AXValue, .cgPoint, &p) }
    if let sr = attr(e, kAXSizeAttribute) { AXValueGetValue(sr as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}

func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }

// Owner of a hosted item when MenuBarAgent exposes it: an AXApplication node
// inside the hosted subtree (present on every display but the one hosting the
// active menu bar).
func ownerName(_ e: AXUIElement, _ depth: Int = 0) -> String {
    if str(e, kAXRoleAttribute) == "AXApplication" { return str(e, kAXTitleAttribute) }
    guard depth < 4, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return "" }
    for k in kids {
        let n = ownerName(k, depth + 1)
        if !n.isEmpty { return n }
    }
    return ""
}

// Fallback: the first title/description in the subtree (system items, the
// overflow chevron, or an item's own accessibility description).
func anyDescription(_ e: AXUIElement, _ depth: Int = 0) -> String {
    for a in [kAXDescriptionAttribute, kAXTitleAttribute] {
        let v = str(e, a)
        if !v.isEmpty { return v }
    }
    guard depth < 4, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return "" }
    for k in kids {
        let d = anyDescription(k, depth + 1)
        if !d.isEmpty { return d }
    }
    return ""
}

struct Item { let x: CGFloat; let w: CGFloat; var label: String }
struct Bar { let display: CGRect; var items: [Item] }

// On the display hosting the active menu bar the hosted nodes carry no owner;
// match those to the apps' own AXExtrasMenuBar items by geometry.
func appExtras() -> [Item] {
    var out: [Item] = []
    for a in NSWorkspace.shared.runningApplications {
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1.0)
        guard let bar = attr(ax, "AXExtrasMenuBar"),
              let kids = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { continue }
        for k in kids {
            let r = rect(k)
            out.append(Item(x: r.minX, w: r.width, label: a.localizedName ?? "?"))
        }
    }
    return out
}

func hostedBars() -> [Bar] {
    var bars: [Bar] = []
    let extras = appExtras()
    for a in NSWorkspace.shared.runningApplications where a.bundleIdentifier == "com.apple.MenuBarAgent" {
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 3)
        guard let wins = attr(ax, kAXWindowsAttribute) as? [AXUIElement] else { continue }
        var seen = Set<String>()
        for w in wins {
            let wr = rect(w)
            let key = "\(Int(wr.minX)),\(Int(wr.width))"
            guard !seen.contains(key), let kids = attr(w, kAXChildrenAttribute) as? [AXUIElement], !kids.isEmpty else { continue }
            seen.insert(key)
            // Label priority: owner app from the subtree, then the owner of the
            // app item at the same X (the active display's nodes carry no owner,
            // and the apps' own positions can lag), then any description.
            let items = kids.map { k -> Item in
                let r = rect(k)
                var name = ownerName(k)
                if name.isEmpty, let m = extras.min(by: { abs($0.x - r.minX) < abs($1.x - r.minX) }), abs(m.x - r.minX) <= 6 {
                    name = m.label
                }
                if name.isEmpty { name = anyDescription(k) }
                return Item(x: r.minX, w: r.width, label: name)
            }
            bars.append(Bar(display: wr, items: items.sorted { $0.x < $1.x }))
        }
    }
    return bars
}

// Accessibility press on Hidden Bar's expand/collapse button (its rightmost item).
func pressHiddenBar() -> Bool {
    for a in NSWorkspace.shared.runningApplications where a.bundleIdentifier == "com.dwarvesv.minimalbar" {
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        guard let bar = attr(ax, "AXExtrasMenuBar"),
              let kids = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
              let button = kids.max(by: { rect($0).minX < rect($1).minX }) else { continue }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
    return false
}

guard AXIsProcessTrusted() else {
    print("This tool needs Accessibility permission for the terminal running it.")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var expectHidden: [String] = [], expectVisible: [String] = []
var press = false
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--press": press = true
    case "--expect-hidden": while let n = args.first, !n.hasPrefix("--") { expectHidden.append(args.removeFirst()) }
    case "--expect-visible": while let n = args.first, !n.hasPrefix("--") { expectVisible.append(args.removeFirst()) }
    default: print("unknown argument \(a)"); exit(2)
    }
}

if press {
    print(pressHiddenBar() ? "pressed Hidden Bar's expand/collapse button" : "could not find Hidden Bar's button")
    Thread.sleep(forTimeInterval: 3)   // let the key search and layout settle
}

var failures = 0
for bar in hostedBars() {
    print("display x=\(Int(bar.display.minX)) w=\(Int(bar.display.width)): \(bar.items.count) hosted items")
    for it in bar.items { print(String(format: "   %6d w=%4d %@", Int(it.x), Int(it.w), it.label)) }
    let names = Set(bar.items.map(\.label))
    for n in expectHidden where names.contains(n) { print("   FAIL: \(n) is on this bar but should be hidden"); failures += 1 }
    for n in expectVisible where !names.contains(n) { print("   FAIL: \(n) is missing from this bar but should be visible"); failures += 1 }
}
if !expectHidden.isEmpty || !expectVisible.isEmpty { print(failures == 0 ? "OK" : "\(failures) failure(s)") }
exit(failures == 0 ? 0 : 1)
