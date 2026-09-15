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
    var liveProbes = 0
    var maxLiveProbes = 0
    var probesCreated = 0

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
    func makeItem(prefix: String, key: Double, length: CGFloat) -> FakeItem {
        let isProbe = prefix.hasSuffix("probe")
        if isProbe { probesCreated += 1; liveProbes += 1; maxLiveProbes = max(maxLiveProbes, liveProbes) }
        let effectiveKey = (!isProbe && misplaceFillers) ? 100_000 + Double(items.count) : key
        return add("\(prefix)#\(items.count)", key: effectiveKey, length: length)
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

func makeChain(_ host: FakeHost, anchor: FakeItem, prefix: String = "fill", count: Int = 3) -> FillerChain<FakeHost> {
    FillerChain(host: host, prefix: prefix,
                anchor: { anchor },
                geometry: { .init(lengths: Array(repeating: 300, count: count)) },
                initialGuess: { anchorFrame in Double(FakeHost.rightEdge - anchorFrame.maxX) - 18 },
                placement: adjacencyRule)
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
    expect(chain.items.isEmpty && !host.items.contains { $0.name.hasPrefix("fill") }, "remove clears the bar")
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

testHappyPath()
testLadderLengthsAppliedInOrder()
testCachedKeyFastPathAndRecovery()
testFinding1_independentGenerations()
testFinding3_placementFailureCleansUp()
testFinding4_idempotentInsert()
testFinding5_slowAndNeverAttachingProbes()
testAnchorNeverAttaches()
testRemoveDuringSearchCancelsSilently()
print(failures == 0 ? "\nOK: \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
