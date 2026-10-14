//
//  FillerChain.swift
//  Hidden Bar
//
//  macOS 27 hides icons by inserting blank "filler" status items right of an
//  anchor item (the separator); the first filler that does not fit carries the
//  anchor and everything left of it into the system overflow. This type owns
//  one such chain: finding the ordering key that lands the fillers immediately
//  right of the anchor, placing them small, validating, growing them, and
//  parking them at zero length between collapses. It talks to the menu bar only through FillerChainHost so
//  the whole state machine runs against a simulated bar in tests.
//

import Foundation
import CoreGraphics

enum FillerPlacement {
    case between        // immediately right of the anchor
    case tooFarRight    // right of the anchor with something in between
    case tooFarLeft     // left of the anchor
    case unknown        // frames not available yet
}

protocol FillerChainHost: AnyObject {
    associatedtype Item: AnyObject
    /// Create a status item with the given ordering key and length. Its autosave
    /// name must be one the system has never seen (see StatusBarController).
    func makeItem(prefix: String, key: Double, length: CGFloat) -> Item
    func removeItem(_ item: Item)
    func setLength(_ length: CGFloat, of item: Item)
    /// Screen frame of the item's button, nil until it is attached to a bar.
    func frame(of item: Item) -> CGRect?
    /// Run `block` on the main queue after `seconds`.
    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void)
    func log(_ message: String)
    /// Extra per-item detail for search traces (raw frame, screen); may be empty.
    func debugDescription(of item: Item) -> String
}

extension FillerChainHost {
    func debugDescription(of item: Item) -> String { "" }
}

final class FillerChain<Host: FillerChainHost> {
    /// Full lengths of the fillers in layout order: the first is the filler the
    /// right-to-left flow meets first (farthest from the anchor, next to the
    /// arrow), the last sits right next to the anchor. Each stays under the drop
    /// cliff of the display it is meant to overflow on; see
    /// StatusBarController.fillerGeometry for how the ladder is built.
    struct Geometry: Equatable {
        let lengths: [CGFloat]
        var count: Int { lengths.count }
    }

    static var maxAttempts: Int { 16 }
    static var maxUnknownStreak: Int { 3 }
    static var pollInterval: TimeInterval { 0.05 }
    static var maxPolls: Int { 40 }
    /// Fillers sort just below the found key, i.e. away from the anchor, so a
    /// key found right at the anchor's edge cannot cross it.
    static var keyStep: Double { 0.0001 }
    /// Probes and fresh fillers appear at this width, which always fits; an item
    /// that does not fit at insertion is re-keyed by macOS to the overflow
    /// boundary instead of taking its key. Resizing an existing item keeps it.
    static var insertionLength: CGFloat { 8 }
    static var probeLength: CGFloat { 8 }
    /// Largest gap between neighbouring fillers that still counts as adjacent:
    /// one item spacing (16pt on 27) with slack. Any item wedged in between adds
    /// its own width plus another spacing.
    static var maxNeighbourGap: CGFloat { 24 }

    private weak var host: Host?
    let prefix: String
    private let anchor: () -> Host.Item?
    private let placement: (_ probe: CGRect, _ anchor: CGRect) -> FillerPlacement
    /// Decides whether freshly inserted (still small) fillers landed correctly,
    /// given the item nearest the anchor and the item farthest from it. The
    /// anchor may already be in the overflow at that point (its frame stale), so
    /// the main chain checks the farthest filler against the arrow instead.
    private var validate: (_ nearestToAnchor: Host.Item, _ farthestFromAnchor: Host.Item) -> Bool
    private let geometry: () -> Geometry
    private let initialGuess: (_ anchorFrame: CGRect) -> Double

    private(set) var items: [Host.Item] = []
    /// Fillers taken off duty by remove(): still on the bar at zero length and
    /// still keyed at cachedKey, reused by the next insert(). On macOS 27 every
    /// status item that is created and removed leaks about 21 Mach ports in the
    /// app (measured on 27.0.1; changing an item's length leaks nothing), so a
    /// chain that collapses many times a day must not recreate its fillers. A
    /// zero-length item still takes one item spacing (about 16pt) on the bar.
    private(set) var parked: [Host.Item] = []
    /// The probe currently on the bar during a key search, so remove() can
    /// take it down even though it is not one of the fillers.
    private var probe: Host.Item?
    private(set) var isInFlight = false
    private(set) var cachedKey: Double?
    /// When a search gives up with both bounds set, the bracket (lo: a key that
    /// landed right of the anchor, hi: one that landed left of it). A narrow
    /// bracket with no success means another item's key sits within it, leaving
    /// no room; the host can re-key that item and try again.
    private(set) var lastFailedBracket: (lo: Double, hi: Double)?
    /// Bumped by remove(); every asynchronous step checks it, so a torn-down
    /// chain's pending work never touches the bar again.
    private var generation = 0

    init(host: Host, prefix: String,
         anchor: @escaping () -> Host.Item?,
         geometry: @escaping () -> Geometry,
         initialGuess: @escaping (_ anchorFrame: CGRect) -> Double,
         placement: @escaping (_ probe: CGRect, _ anchor: CGRect) -> FillerPlacement,
         validate: ((_ nearestToAnchor: Host.Item, _ farthestFromAnchor: Host.Item) -> Bool)? = nil) {
        self.host = host
        self.prefix = prefix
        self.anchor = anchor
        self.geometry = geometry
        self.initialGuess = initialGuess
        self.placement = placement
        self.validate = validate ?? { _, _ in false }
        if validate == nil {
            // Default: the nearest filler sits right next to the anchor.
            self.validate = { [weak self] nearest, _ in self?.placementOf(nearest) == .between }
        }
    }

    /// Fillers are on the bar at full length.
    var isPlaced: Bool { !items.isEmpty && !isInFlight }

    /// Place the fillers. Idempotent: a call while a placement is in flight or
    /// already complete does nothing. `completion` reports whether the fillers
    /// ended up right of the anchor; on failure no filler remains on the bar
    /// (parked ones only if the anchor never attached, so they were never
    /// tried). A remove() during the work cancels it without calling back.
    func insert(completion: ((Bool) -> Void)? = nil) {
        guard !isInFlight else { return }
        guard items.isEmpty else { completion?(true); return }
        isInFlight = true
        let generation = self.generation
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self = self, generation == self.generation else { return }
            self.isInFlight = false
            completion?(ok)
        }
        waitForAnchor(generation: generation) { [weak self] anchorFrame in
            guard let self = self else { return }
            guard let anchorFrame = anchorFrame else {
                self.host?.log("FillerChain \(self.prefix): anchor never attached; nothing placed")
                finish(false)
                return
            }
            let geometry = self.geometry()
            self.host?.log("FillerChain \(self.prefix): placing \(geometry.count) fillers \(geometry.lengths.map { Int($0) }) \(self.cachedKey.map { "at cached key \($0)" } ?? "after a key search")")
            if let cached = self.cachedKey {
                self.place(at: cached, geometry: geometry, generation: generation) { [weak self] ok in
                    guard let self = self else { return }
                    if ok { finish(true); return }
                    self.host?.log("FillerChain \(self.prefix): cached key \(cached) no longer lands right of the anchor; searching")
                    self.cachedKey = nil
                    self.discardItems()
                    self.waitForLayout(of: [], generation: generation) { [weak self] in
                        self?.search(from: anchorFrame, geometry: geometry, generation: generation, finish: finish)
                    }
                }
            } else {
                self.search(from: anchorFrame, geometry: geometry, generation: generation, finish: finish)
            }
        }
    }

    /// Take the fillers off duty and cancel any work in progress. Placed fillers
    /// are parked at zero length for the next insert(); anything still in flight
    /// has not been validated and is removed.
    func remove() {
        generation += 1
        let wasInFlight = isInFlight
        isInFlight = false
        if wasInFlight { discardItems(); return }
        guard !items.isEmpty else { return }
        if let host = host { items.forEach { host.setLength(0, of: $0) } }
        parked = items
        items = []
    }

    /// Remove every filler from the bar, parked ones included, and cancel any
    /// work in progress. For when the anchor goes away or the fillers' blank
    /// spacing must not stay on the bar.
    func discard() {
        generation += 1
        isInFlight = false
        discardItems()
    }

    /// Forget the cached key, e.g. after the anchor was moved. Parked fillers sit
    /// at that key, so they go too.
    func invalidateCache() {
        cachedKey = nil
        if let host = host { parked.forEach { host.removeItem($0) } }
        parked = []
    }

    /// Run only the key search: find a key whose item lands immediately right of
    /// the anchor, without placing any fillers. Used to re-register another item
    /// next to the anchor. Not idempotent with insert(); callers keep the chain
    /// otherwise idle.
    func locateKey(completion: @escaping (Double?) -> Void) {
        guard !isInFlight else { completion(nil); return }
        isInFlight = true
        let generation = self.generation
        waitForAnchor(generation: generation) { [weak self] anchorFrame in
            guard let self = self else { return }
            guard let anchorFrame = anchorFrame else { self.isInFlight = false; completion(nil); return }
            self.findKey(startingAt: self.initialGuess(anchorFrame), generation: generation) { [weak self] key in
                guard let self = self, generation == self.generation else { return }
                self.isInFlight = false
                completion(key)
            }
        }
    }

    // MARK: - Steps

    private func discardItems() {
        guard let host = host else { items = []; parked = []; probe = nil; return }
        (items + parked).forEach { host.removeItem($0) }
        items = []
        parked = []
        if let p = probe { host.removeItem(p); probe = nil }
    }

    private func search(from anchorFrame: CGRect, geometry: Geometry, generation: Int, finish: @escaping (Bool) -> Void) {
        findKey(startingAt: initialGuess(anchorFrame), generation: generation) { [weak self] key in
            guard let self = self else { return }
            guard let key = key else {
                self.host?.log("FillerChain \(self.prefix): no key found right of the anchor; nothing placed")
                finish(false)
                return
            }
            self.place(at: key, geometry: geometry, generation: generation) { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    self.cachedKey = key
                    self.host?.log("FillerChain \(self.prefix): placed at key \(key)")
                } else {
                    self.host?.log("FillerChain \(self.prefix): fillers did not land right of the anchor at key \(key)")
                    self.discardItems()
                }
                finish(ok)
            }
        }
    }

    /// Bisect for a key whose probe lands immediately right of the anchor.
    private func findKey(startingAt initial: Double, generation: Int, completion: @escaping (Double?) -> Void) {
        lastFailedBracket = nil
        var lo: Double? = nil
        var hi: Double? = nil
        var step = 40.0
        var guess = initial
        var attempts = 0
        var unknownStreak = 0
        func attempt() {
            guard let host = self.host, generation == self.generation else { return }
            attempts += 1
            let probe = host.makeItem(prefix: prefix + "probe", key: guess, length: FillerChain.probeLength)
            self.probe = probe
            waitForLayout(of: [probe], generation: generation) { [weak self] in
                guard let self = self, let host = self.host else { return }
                let result = self.placementOf(probe)
                host.log("FillerChain \(self.prefix): attempt \(attempts) key \(guess) -> \(result): probe \(host.frame(of: probe).map { "\(Int($0.minX))-\(Int($0.maxX))" } ?? "nil") anchor \(self.anchor().flatMap { host.frame(of: $0) }.map { "\(Int($0.minX))-\(Int($0.maxX))" } ?? "nil")\(host.debugDescription(of: probe))")
                host.removeItem(probe)
                self.probe = nil
                switch result {
                case .between:
                    host.log("FillerChain \(self.prefix): key \(guess) found after \(attempts) probe(s)")
                    completion(guess)
                    return
                case .tooFarRight: lo = guess; unknownStreak = 0
                case .tooFarLeft: hi = guess; unknownStreak = 0
                case .unknown: unknownStreak += 1
                }
                if unknownStreak >= FillerChain.maxUnknownStreak {
                    host.log("FillerChain \(self.prefix): \(unknownStreak) probes in a row had no usable frame; giving up")
                    completion(nil)
                    return
                }
                if attempts >= FillerChain.maxAttempts {
                    host.log("FillerChain \(self.prefix): key search gave up after \(attempts) attempts (lo=\(String(describing: lo)) hi=\(String(describing: hi)))")
                    if let l = lo, let h = hi { self.lastFailedBracket = (l, h) }
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
                self.waitForLayout(of: [], generation: generation) { attempt() }
            }
        }
        attempt()
    }

    /// Put the fillers on the bar small at `key` (reusing parked ones, which sit
    /// at that key already), confirm the one nearest the anchor sits right next
    /// to it, then grow them all.
    private func place(at key: Double, geometry: Geometry, generation: Int, completion: @escaping (Bool) -> Void) {
        guard let host = host else { return }
        let reused = parked.prefix(geometry.count)
        parked.dropFirst(geometry.count).forEach { host.removeItem($0) }
        parked = []
        reused.forEach { host.setLength(FillerChain.insertionLength, of: $0) }
        items = Array(reused) + (reused.count..<geometry.count).map { i in
            host.makeItem(prefix: prefix, key: key - FillerChain.keyStep * Double(i), length: FillerChain.insertionLength)
        }
        waitForLayout(of: items, generation: generation) { [weak self] in
            guard let self = self, let host = self.host, let nearest = self.items.first, let farthest = self.items.last else { return }
            // A drag while expanded re-keys parked fillers from their geometry and
            // can leave another app's item between them, which growing would hide.
            // The checks below only look at the ends of the chain, so parked
            // fillers must also still be neighbours; if not, replace them at the
            // same key.
            if !reused.isEmpty, let gap = self.firstGapBetweenFillers() {
                host.log("FillerChain \(self.prefix): parked fillers no longer adjacent (gap \(Int(gap))pt); replacing them")
                self.items.forEach { host.removeItem($0) }
                self.items = []
                self.waitForLayout(of: [], generation: generation) { [weak self] in
                    self?.place(at: key, geometry: geometry, generation: generation, completion: completion)
                }
                return
            }
            guard self.validate(nearest, farthest) else {
                let frames = self.items.map { host.frame(of: $0).map { "\(Int($0.minX))-\(Int($0.maxX))" } ?? "nil" }
                let anchorFrame = self.anchor().flatMap { host.frame(of: $0) }.map { "\(Int($0.minX))-\(Int($0.maxX))" } ?? "nil"
                host.log("FillerChain \(self.prefix): validation failed; fillers (nearest anchor first) \(frames) anchor \(anchorFrame)")
                completion(false)
                return
            }
            // items[0] has the highest key and sits next to the anchor; the flow
            // reaches items.last first.
            for (item, length) in zip(self.items.reversed(), geometry.lengths) { host.setLength(length, of: item) }
            completion(true)
        }
    }

    /// The first gap between neighbouring fillers wider than maxNeighbourGap, or
    /// nil if they all sit together. items[0] is leftmost (highest key).
    private func firstGapBetweenFillers() -> CGFloat? {
        guard let host = host else { return nil }
        for (left, right) in zip(items, items.dropFirst()) {
            guard let l = host.frame(of: left), let r = host.frame(of: right) else { continue }
            let gap = r.minX - l.maxX
            if gap < -1 || gap > FillerChain.maxNeighbourGap { return gap }
        }
        return nil
    }

    private func placementOf(_ item: Host.Item) -> FillerPlacement {
        guard let host = host, let p = host.frame(of: item), let a = anchor(), let af = host.frame(of: a) else { return .unknown }
        return placement(p, af)
    }

    /// Poll until the anchor has a frame; nil if it never attaches.
    private func waitForAnchor(generation: Int, _ done: @escaping (CGRect?) -> Void) {
        var polls = 0
        func poll() {
            guard let host = self.host, generation == self.generation else { return }
            if let a = self.anchor(), let f = host.frame(of: a) { done(f); return }
            polls += 1
            if polls >= FillerChain.maxPolls { done(nil); return }
            host.after(FillerChain.pollInterval, poll)
        }
        poll()
    }

    /// Poll until every listed item has a frame and none changed between two
    /// polls (layout is asynchronous in MenuBarAgent and can take well over a
    /// second for several new items), or the poll budget runs out. With no items
    /// this is a single settle delay.
    private func waitForLayout(of watched: [Host.Item], generation: Int, _ done: @escaping () -> Void) {
        var last: [CGRect?] = []
        var stable = 0
        var polls = 0
        func poll() {
            guard let host = self.host, generation == self.generation else { return }
            polls += 1
            let now = watched.map { host.frame(of: $0) }
            let allAttached = now.allSatisfy { $0 != nil }
            if allAttached && now == last { stable += 1 } else { stable = 0; last = now }
            if (allAttached && stable >= 1) || polls >= FillerChain.maxPolls { done(); return }
            host.after(FillerChain.pollInterval, poll)
        }
        host?.after(FillerChain.pollInterval, poll)
    }
}
