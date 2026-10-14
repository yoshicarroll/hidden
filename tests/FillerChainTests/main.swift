// FillerChainTests.swift
// Runs FillerChain against a simulated macOS 27 menu bar. See run-filler-chain-tests.sh.

import Foundation
import CoreGraphics

// MARK: - Simulated menu bar

final class FakeItem {
    let name: String
    var key: Double
    var length: CGFloat
    var frameQueries = 0
    init(name: String, key: Double, length: CGFloat) { self.name = name; self.key = key; self.length = length }
}

final class FakeHost: FillerChainHost {
    typealias Item = FakeItem
    static let rightEdge: CGFloat = 1000
    static let spacing: CGFloat = 16

    var items: [FakeItem] = []
    var logs: [String] = []
    /// Frames read nil for this many queries after an item is created.
    var attachDelay = 0
    /// Items with this prefix never get a frame.
    var neverAttachPrefix: String? = nil
    /// Simulate MenuBarAgent ignoring the key of new non-probe items and dumping them far left.
    var misplaceFillers = false
    /// Width of the region available to items. An item that does not fit at
    /// insertion is re-keyed to the overflow boundary (just left of the last
    /// fitting item), as MenuBarAgent does; resizing keeps keys.
    var regionWidth: CGFloat? = nil
    var liveProbes = 0
    var maxLiveProbes = 0
    var probesCreated = 0
    var fillersCreated = 0
    /// Until simulated time `until`, frame(of: item) reads `dx` off its layout
    /// (a frame read while MenuBarAgent re-lays the bar during a reconnect).
    var transientShift: (item: FakeItem, dx: CGFloat, until: Double)? = nil
    var currentTime: Double { now }

    private var queue: [(time: Double, block: () -> Void)] = []
    private var now = 0.0

    func add(_ name: String, key: Double, length: CGFloat) -> FakeItem {
        let it = FakeItem(name: name, key: key, length: length); items.append(it); return it
    }

    // Layout: ascending key = right to left from the right edge.
    func layoutFrame(of item: FakeItem) -> CGRect {
        var cursor = FakeHost.rightEdge
        for it in items.sorted(by: { $0.key < $1.key }) {
            let x = cursor - it.length
            if it === item { return CGRect(x: x, y: 0, width: it.length, height: 24) }
            cursor = x - FakeHost.spacing
        }
        return .zero
    }

    // FillerChainHost
    /// Keys of items that fit, laid out right to left within regionWidth.
    private func fittingKeys() -> [Double] {
        guard let region = regionWidth else { return items.map(\.key) }
        var cursor = FakeHost.rightEdge; var fits: [Double] = []
        for it in items.sorted(by: { $0.key < $1.key }) {
            let x = cursor - it.length
            if x < FakeHost.rightEdge - region { break }
            fits.append(it.key); cursor = x - FakeHost.spacing
        }
        return fits
    }
    func fits(_ item: FakeItem) -> Bool { fittingKeys().contains(item.key) }
    func makeItem(prefix: String, key: Double, length: CGFloat) -> FakeItem {
        let isProbe = prefix.hasSuffix("probe")
        if isProbe { probesCreated += 1; liveProbes += 1; maxLiveProbes = max(maxLiveProbes, liveProbes) } else { fillersCreated += 1 }
        var effectiveKey = (!isProbe && misplaceFillers) ? 100_000 + Double(items.count) : key
        let item = add("\(prefix)#\(items.count)", key: effectiveKey, length: length)
        if regionWidth != nil, !fittingKeys().contains(effectiveKey) {
            // Re-key to the boundary: just left of the last item that fits.
            let lastFitting = fittingKeys().filter { $0 != effectiveKey }.max() ?? 0
            effectiveKey = lastFitting + 0.00001
            item.key = effectiveKey
        }
        return item
    }
    func removeItem(_ item: FakeItem) {
        if item.name.contains("probe") { liveProbes -= 1 }
        items.removeAll { $0 === item }
    }
    func setLength(_ length: CGFloat, of item: FakeItem) { item.length = length }
    func frame(of item: FakeItem) -> CGRect? {
        guard items.contains(where: { $0 === item }) else { return nil }
        if let p = neverAttachPrefix, item.name.hasPrefix(p) { return nil }
        item.frameQueries += 1
        if item.frameQueries <= attachDelay { return nil }
        if regionWidth != nil, !fittingKeys().contains(item.key) { return CGRect(x: FakeHost.rightEdge - item.length, y: 0, width: item.length, height: 24) }
        if let t = transientShift, t.item === item, now < t.until { return layoutFrame(of: item).offsetBy(dx: t.dx, dy: 0) }
        return layoutFrame(of: item)
    }
    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) { queue.append((now + seconds, block)) }
    func log(_ message: String) { logs.append(message) }

    /// Drain the timer queue in time order (bounded).
    func run(maxEvents: Int = 5000) {
        var n = 0
        while !queue.isEmpty, n < maxEvents {
            queue.sort { $0.time < $1.time }
            let next = queue.removeFirst(); now = next.time; next.block(); n += 1
        }
        precondition(n < maxEvents, "timer queue did not drain")
    }
    /// Run only the next `count` timer events.
    func step(_ count: Int) {
        for _ in 0..<count { guard !queue.isEmpty else { return }; queue.sort { $0.time < $1.time }; let next = queue.removeFirst(); now = next.time; next.block() }
    }
}

// MARK: - Harness

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("  FAIL (line \(line)): \(msg)") }
}

func adjacencyRule(_ probe: CGRect, _ anchor: CGRect) -> FillerPlacement {
    if probe.maxX <= anchor.minX + 1 { return .tooFarLeft }
    if probe.minX >= anchor.maxX - 1 { return (probe.minX - anchor.maxX) <= 24 ? .between : .tooFarRight }
    return .unknown
}

/// A bar like Hidden Bar's: system items on the right, the arrow, the separator, hidden icons left of it.
func makeBar(_ host: FakeHost) -> (expand: FakeItem, separator: FakeItem, hidden: [FakeItem]) {
    _ = host.add("clock", key: 0, length: 130)
    _ = host.add("wifi", key: 146, length: 22)
    let e = host.add("expand", key: 300, length: 32)
    let s = host.add("separator", key: 348, length: 20)
    let h1 = host.add("hidden1", key: 384, length: 30)
    let h2 = host.add("hidden2", key: 430, length: 30)
    return (e, s, [h1, h2])
}

/// Validation like the app's regular chain: the nearest filler right next to the separator, or the
/// farthest filler right next to the arrow.
func validateAgainst(_ arrow: FakeItem, _ host: FakeHost, separator: FakeItem? = nil) -> (FakeItem, FakeItem) -> Bool {
    return { nearest, farthest in
        if let sep = separator, let n = host.frame(of: nearest), let a = host.frame(of: sep), host.fits(sep) {
            let gap = n.minX - a.maxX
            if gap >= -1 && gap <= 24 { return true }
        }
        guard let f = host.frame(of: farthest), let e = host.frame(of: arrow) else { return false }
        let gap = e.minX - f.maxX
        return gap >= -1 && gap <= 24
    }
}

func makeChain(_ host: FakeHost, anchor: FakeItem, arrow: FakeItem? = nil, prefix: String = "fill", count: Int = 3) -> FillerChain<FakeHost> {
    FillerChain(host: host, prefix: prefix,
                anchor: { anchor },
                geometry: { .init(lengths: Array(repeating: 300, count: count)) },
                initialGuess: { anchorFrame in Double(FakeHost.rightEdge - anchorFrame.maxX) - 18 },
                placement: adjacencyRule,
                validate: arrow.map { validateAgainst($0, host) })
}

func fillersAreRightOfSeparator(_ host: FakeHost, _ chain: FillerChain<FakeHost>, _ sep: FakeItem) -> Bool {
    let sepFrame = host.layoutFrame(of: sep)
    return chain.items.allSatisfy { host.layoutFrame(of: $0).minX >= sepFrame.maxX - 1 }
}

// MARK: - Tests

func testHappyPath() {
    print("happy path: search, place, grow")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    var result: Bool? = nil
    chain.insert { result = $0 }
    host.run()
    expect(result == true, "insert reports success")
    expect(chain.isPlaced, "chain is placed")
    expect(chain.items.count == 3, "three fillers")
    expect(chain.items.allSatisfy { $0.length == 300 }, "fillers grown to 300")
    expect(fillersAreRightOfSeparator(host, chain, bar.separator), "fillers sit right of the separator")
    expect(host.liveProbes == 0, "no probe left on the bar")
    expect(chain.cachedKey != nil, "key cached")
    let sepFrame = host.layoutFrame(of: bar.separator)
    let nearest = host.layoutFrame(of: chain.items[0])
    expect(nearest.minX - sepFrame.maxX <= FakeHost.spacing + 1, "nearest filler adjacent to the separator")
    chain.remove()
    expect(chain.items.isEmpty && chain.parked.count == 3, "remove parks the fillers")
    expect(host.items.filter { $0.name.hasPrefix("fill") }.allSatisfy { $0.length == 0 }, "parked fillers are zero length")
    chain.discard()
    expect(chain.parked.isEmpty && !host.items.contains { $0.name.hasPrefix("fill") }, "discard clears the bar")
}

func testCachedKeyFastPathAndRecovery() {
    print("cached key: fast path, then recovery when the cache is stale")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    chain.insert(); host.run(); chain.remove()
    let probesAfterFirst = host.probesCreated
    chain.insert(); host.run()
    expect(host.probesCreated == probesAfterFirst, "cached key placed without a probe")
    expect(chain.isPlaced && fillersAreRightOfSeparator(host, chain, bar.separator), "fast path placed correctly")
    chain.remove()
    // The user dragged the separator: its key moved; the cached key is now left of it.
    bar.separator.key = 200
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(result == true, "recovers by searching again")
    expect(fillersAreRightOfSeparator(host, chain, bar.separator), "fillers right of the moved separator")
    expect(host.probesCreated > probesAfterFirst, "a new search ran")
}

func testFinding1_independentGenerations() {
    print("finding 1: removing one chain does not cancel another chain's in-flight insert")
    let host = FakeHost(); let bar = makeBar(host)
    let alwaysHidden = host.add("alwaysHiddenSep", key: 470, length: 20)
    let main = makeChain(host, anchor: bar.separator, prefix: "fill")
    let ah = makeChain(host, anchor: alwaysHidden, prefix: "ahfill")
    var mainResult: Bool? = nil
    main.insert { mainResult = $0 }
    host.step(3)                      // main chain is mid-search
    expect(main.isInFlight, "main chain in flight")
    ah.remove()                       // the other chain is torn down (screen change handler)
    host.run()
    expect(mainResult == true, "main chain still completes")
    expect(main.isPlaced && main.items.allSatisfy { $0.length == 300 }, "main fillers placed and grown, not stranded at 8pt")
}

func testFinding3_placementFailureCleansUp() {
    print("finding 3: a failed placement leaves nothing on the bar and allows a retry")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    host.misplaceFillers = true
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(result == false, "insert reports failure")
    expect(chain.items.isEmpty, "no fillers retained")
    expect(!host.items.contains { $0.name.hasPrefix("fill") }, "no filler left on the bar")
    expect(!chain.isInFlight, "not in flight")
    expect(chain.cachedKey == nil, "no key cached from a failed placement")
    host.misplaceFillers = false
    var second: Bool? = nil
    chain.insert { second = $0 }; host.run()
    expect(second == true, "a later insert is not blocked")
}

func testFinding4_idempotentInsert() {
    print("finding 4: concurrent inserts run one search with one probe at a time")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    var completions = 0
    chain.insert { _ in completions += 1 }
    chain.insert { _ in completions += 1 }   // e.g. hideSeparators() racing the delayed setup
    host.step(2)
    chain.insert { _ in completions += 1 }
    host.run()
    expect(completions == 1, "only the first insert calls back (got \(completions))")
    expect(host.maxLiveProbes == 1, "never more than one probe on the bar (max \(host.maxLiveProbes))")
    expect(chain.items.count == 3, "exactly one set of fillers")
    // A repeat insert once placed is a no-op that reports success.
    var again: Bool? = nil
    chain.insert { again = $0 }; host.run()
    expect(again == true && chain.items.count == 3, "insert on a placed chain is a successful no-op")
}

func testFinding5_slowAndNeverAttachingProbes() {
    print("finding 5: slow frame attach still converges; a never-attaching probe fails fast")
    var host = FakeHost(); var bar = makeBar(host); var chain = makeChain(host, anchor: bar.separator)
    host.attachDelay = 4
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(result == true, "converges despite delayed frames")
    expect(fillersAreRightOfSeparator(host, chain, bar.separator), "placed correctly despite delayed frames")

    host = FakeHost(); bar = makeBar(host); chain = makeChain(host, anchor: bar.separator)
    host.neverAttachPrefix = "fillprobe"
    result = nil
    chain.insert { result = $0 }; host.run()
    expect(result == false, "gives up when probes never attach")
    expect(host.probesCreated <= FillerChain<FakeHost>.maxUnknownStreak, "bails after \(FillerChain<FakeHost>.maxUnknownStreak) unknowns, not \(FillerChain<FakeHost>.maxAttempts) (created \(host.probesCreated))")
    expect(host.liveProbes == 0 && chain.items.isEmpty, "nothing left on the bar")
}

func testTightRegionFallsBackToSequentialPlacement() {
    print("tight region: the fillers push the separator itself into the overflow; validation uses the arrow")
    let host = FakeHost(); let bar = makeBar(host)
    // Right of the separator: clock 130, wifi 22, arrow 32 with gaps = 232. Room for the probe and the
    // separator while searching, but once four 8pt fillers (96) are in, the separator no longer fits.
    host.regionWidth = 232 + 96 + 8
    let chain = FillerChain<FakeHost>(host: host, prefix: "fill", anchor: { bar.separator },
                geometry: { .init(lengths: [300, 500, 700, 700]) },
                initialGuess: { f in Double(FakeHost.rightEdge - f.maxX) - 18 }, placement: adjacencyRule,
                validate: validateAgainst(bar.expand, host))
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    if ProcessInfo.processInfo.environment["DEBUG_TIGHT"] != nil {
        for it in host.items.sorted(by: { $0.key < $1.key }) { print("     \(it.name) key=\(it.key) len=\(it.length) frame=\(host.frame(of: it).map { "\(Int($0.minX))-\(Int($0.maxX))" } ?? "nil")") }
        print("     probesCreated=\(host.probesCreated) logs=\(host.logs)")
    }
    expect(result == true, "placement succeeds although the separator overflowed")
    expect(chain.items.count == 4, "all four fillers exist (got \(chain.items.count))")
    expect(!host.fits(bar.separator), "separator is in the overflow (hidden)")
    let sepKey = bar.separator.key, expandKey = bar.expand.key
    expect(chain.items.allSatisfy { $0.key > expandKey && $0.key < sepKey }, "every filler is keyed between the arrow and the separator (keys \(chain.items.map(\.key)))")
    expect(Set(chain.items.map(\.length)) == Set([300, 500, 700]), "fillers grown to the ladder lengths (got \(chain.items.map(\.length)))")
    expect(host.liveProbes == 0, "no probe left")
}

func testAnchorNeverAttaches() {
    print("anchor never attaches: fails without touching the bar")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    host.neverAttachPrefix = "separator"
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(result == false, "reports failure")
    expect(host.probesCreated == 0, "no probe inserted")
}

func testRemoveDuringSearchCancelsSilently() {
    print("remove during a search: no callback, no leftovers")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    var called = false
    chain.insert { _ in called = true }
    host.step(3)
    chain.remove()
    host.run()
    expect(!called, "cancelled insert does not call back")
    expect(host.liveProbes == 0, "probe removed")
    expect(chain.items.isEmpty && !chain.isInFlight, "chain idle")
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(result == true, "chain usable again")
}

func testLadderLengthsAppliedInOrder() {
    print("ladder: lengths apply in layout order, the filler next to the arrow first")
    let host = FakeHost(); let bar = makeBar(host)
    let chain = FillerChain<FakeHost>(host: host, prefix: "fill", anchor: { bar.separator },
                geometry: { .init(lengths: [300, 500, 700]) },
                initialGuess: { f in Double(FakeHost.rightEdge - f.maxX) - 18 }, placement: adjacencyRule)
    chain.insert(); host.run()
    let byDistance = chain.items.sorted { host.layoutFrame(of: $0).minX > host.layoutFrame(of: $1).minX }
    expect(byDistance.map(\.length) == [300, 500, 700], "rightmost filler gets lengths[0] (got \(byDistance.map(\.length)))")
}

func fillersOnBar(_ host: FakeHost, prefix: String = "fill") -> [FakeItem] {
    host.items.filter { $0.name.hasPrefix(prefix) && !$0.name.contains("probe") }
}

func testParkedFillersAreReused() {
    print("parking: remove() keeps the fillers at zero length and insert() reuses them")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    chain.insert(); host.run()
    let first = chain.items
    let created = host.fillersCreated, probes = host.probesCreated
    for _ in 0..<5 {
        chain.remove(); host.run()
        expect(fillersOnBar(host).count == 3 && fillersOnBar(host).allSatisfy { $0.length == 0 }, "parked at zero length")
        var result: Bool? = nil
        chain.insert { result = $0 }; host.run()
        expect(result == true && chain.isPlaced, "reinsert succeeds")
    }
    expect(host.fillersCreated == created, "no filler created after the first collapse (created \(host.fillersCreated - created))")
    expect(host.probesCreated == probes, "no probe either")
    expect(zip(chain.items, first).allSatisfy { $0 === $1 }, "the same items, in the same order")
    expect(chain.items.allSatisfy { $0.length == 300 }, "grown to full length")
    expect(fillersAreRightOfSeparator(host, chain, bar.separator), "still right of the separator")
    // remove() on an idle chain with parked fillers leaves them alone.
    chain.remove(); chain.remove()
    expect(chain.parked.count == 3 && fillersOnBar(host).count == 3, "repeat remove keeps the parked set")
}

func testParkedFillersFollowGeometry() {
    print("parking: a new filler count reuses what it can")
    let host = FakeHost(); let bar = makeBar(host)
    var lengths: [CGFloat] = [300, 300, 300]
    let chain = FillerChain<FakeHost>(host: host, prefix: "fill", anchor: { bar.separator },
                geometry: { .init(lengths: lengths) },
                initialGuess: { f in Double(FakeHost.rightEdge - f.maxX) - 18 }, placement: adjacencyRule)
    chain.insert(); host.run(); chain.remove()
    let created = host.fillersCreated
    lengths = [200, 300, 400, 400]
    chain.insert(); host.run()
    expect(chain.items.count == 4 && host.fillersCreated == created + 1, "one more filler created for a fourth display slot")
    expect(fillersAreRightOfSeparator(host, chain, bar.separator), "all four right of the separator")
    chain.remove()
    lengths = [500, 500]
    chain.insert(); host.run()
    expect(chain.items.count == 2 && fillersOnBar(host).count == 2, "surplus parked fillers removed (on bar: \(fillersOnBar(host).count))")
    expect(host.fillersCreated == created + 1, "none created for a shorter ladder")
}

func testStaleParkedFillersAreReplaced() {
    print("parking: parked fillers that no longer land right of the anchor are replaced, not stacked")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    chain.insert(); host.run(); chain.remove()
    bar.separator.key = 200   // dragged while expanded
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(result == true && fillersAreRightOfSeparator(host, chain, bar.separator), "re-placed right of the moved separator")
    expect(fillersOnBar(host).count == 3, "only the new set is on the bar (\(fillersOnBar(host).count))")
}

func testItemWedgedBetweenParkedFillers() {
    print("parking: an item dragged in between parked fillers is not hidden; the fillers are replaced at the same key")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    chain.insert(); host.run(); chain.remove()
    guard let key = chain.cachedKey else { expect(false, "first placement cached a key"); return }
    // A drag while expanded: MenuBarAgent re-keys the parked fillers from their
    // geometry (16pt apart) and another app's item lands between two of them.
    for (i, f) in chain.parked.enumerated() { f.key = key - 20 * Double(i) }
    let wedged = host.add("macwhisper", key: key - 10, length: 32)
    let created = host.fillersCreated, probes = host.probesCreated
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(result == true && chain.isPlaced, "collapse still succeeds")
    expect(host.probesCreated == probes, "no key search: the cached key is still good")
    expect(host.fillersCreated == created + 3, "a fresh set of three fillers")
    expect(fillersOnBar(host).count == 3, "the old set is gone (on bar: \(fillersOnBar(host).count))")
    let keys = chain.items.map(\.key)
    expect(!keys.isEmpty && !(keys.min()! < wedged.key && wedged.key < keys.max()!), "the wedged item is outside the chain (keys \(keys), item \(wedged.key))")
}

func testTransientSplitDuringRelayoutKeepsParkedFillers() {
    print("parking: a split seen only while the bar re-lays (display reconnect) does not replace the fillers")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    chain.insert(); host.run(); chain.remove()
    let parked = chain.parked
    // The filler farthest from the anchor reads 900pt off for half a second.
    host.transientShift = (parked[2], 900, host.currentTime + 0.5)
    let created = host.fillersCreated
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(host.logs.contains { $0.contains("look split") }, "the split was seen")
    expect(result == true && chain.isPlaced, "collapse succeeds")
    expect(host.fillersCreated == created, "no filler created (created \(host.fillersCreated - created))")
    expect(zip(chain.items, parked).allSatisfy { $0 === $1 }, "the parked fillers were reused")
    expect(chain.items.allSatisfy { $0.length == 300 }, "and grown")
}

func testInvalidateCacheAndInFlightRemoveDiscard() {
    print("parking: invalidateCache() and a remove() mid-placement leave nothing behind")
    let host = FakeHost(); let bar = makeBar(host); let chain = makeChain(host, anchor: bar.separator)
    chain.insert(); host.run(); chain.remove()
    chain.invalidateCache()
    expect(chain.parked.isEmpty && fillersOnBar(host).isEmpty, "invalidateCache removes the parked fillers")
    chain.insert(); host.run(); chain.remove()
    chain.insert(); host.step(1)
    expect(chain.isInFlight, "reinsert in flight")
    chain.remove(); host.run()
    expect(chain.parked.isEmpty && fillersOnBar(host).isEmpty, "unvalidated fillers are not parked")
    var result: Bool? = nil
    chain.insert { result = $0 }; host.run()
    expect(result == true, "usable afterwards")
}

func r(_ minX: CGFloat, _ maxX: CGFloat) -> CGRect { CGRect(x: minX, y: 0, width: maxX - minX, height: 24) }

func testCollapsedAudit() {
    print("audit: no false positives from overflowed fillers or icons between the separator and the arrow")
    let builtIn = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let external = CGRect(x: 1728, y: 0, width: 2304, height: 1296)
    var audit = CollapsedAudit()
    // Frames from real false positives (macOS 27.0.1).
    expect(audit.judge(filler: r(1184, 1984), arrow: r(1277, 1309), screen: builtIn) == .stale, "filler running past the display edge is in the overflow: skipped")
    expect(audit.judge(filler: r(2578, 3378), arrow: r(3466, 3498), screen: external) == .baseline, "first look records the gap (an icon sits in it)")
    expect(audit.judge(filler: r(2570, 3370), arrow: r(3458, 3490), screen: external) == .ok, "same gap a minute later")
    expect(audit.judge(filler: r(274, 1074), arrow: r(1162, 1194), screen: builtIn) == .baseline, "each display has its own baseline")
    expect(audit.judge(filler: r(274, 1074), arrow: r(1202, 1234), screen: builtIn) == .ok, "a 40pt system item appearing is within the allowance")
    // Real trouble.
    expect(audit.judge(filler: r(2000, 2800), arrow: r(3466, 3498), screen: external) == .gapChanged(from: 88, to: 666), "fillers re-laid far from the arrow are reported")
    expect(audit.judge(filler: r(3000, 3800), arrow: r(3466, 3498), screen: external) == .arrowLeftOfFiller, "arrow left of the filler is reported")
    audit.reset()
    expect(audit.judge(filler: r(2000, 2800), arrow: r(3466, 3498), screen: external) == .baseline, "a new placement starts a new baseline")
}

testHappyPath()
testCollapsedAudit()
testParkedFillersAreReused()
testParkedFillersFollowGeometry()
testStaleParkedFillersAreReplaced()
testItemWedgedBetweenParkedFillers()
testTransientSplitDuringRelayoutKeepsParkedFillers()
testInvalidateCacheAndInFlightRemoveDiscard()
testLadderLengthsAppliedInOrder()
testCachedKeyFastPathAndRecovery()
testFinding1_independentGenerations()
testFinding3_placementFailureCleansUp()
testFinding4_idempotentInsert()
testFinding5_slowAndNeverAttachingProbes()
testTightRegionFallsBackToSequentialPlacement()
testAnchorNeverAttaches()
testRemoveDuringSearchCancelsSilently()
print(failures == 0 ? "\nOK: \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
