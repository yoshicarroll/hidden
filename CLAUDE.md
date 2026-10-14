# Hidden Bar

macOS menu bar utility (Swift, AppKit, App Store sandbox). Read `docs/ARCHITECTURE.md`
first; `docs/RUNBOOK.md` has build, verification and diagnostics; `docs/BACKLOG.md`
lists open work; `docs/MANUAL.md` is user-facing.

## macOS 27 work (branch `fix/macos27-overflow-hiding`)

- The hiding mechanism on macOS 27 lives in `hidden/Features/StatusBar/FillerChain.swift`
  (tested state machine) and the macOS 27 sections of `StatusBarController.swift`.
  Everything measured about MenuBarAgent's layout is in ARCHITECTURE.md; trust it
  over intuition, the bar does not behave like earlier macOS.
- Unit tests: `sh tests/run-filler-chain-tests.sh` (plain swiftc, no Xcode test
  target). Add a case for any behaviour change to the chain; the suite has caught
  real bugs.
- Real-bar verification: build **sandboxed** (RUNBOOK "Testing on macOS 27"),
  install to /Applications, then `swift tools/macos27-hide-check.swift` with
  `--press`, `--expect-hidden`, `--expect-visible`. Diagnostics:
  `/usr/bin/log show --last 6h --predicate 'subsystem == "com.dwarvesv.minimalbar"' --style compact`.
- Rules learned the hard way:
  - never act on the audit from code, and never clear the arrow's image to force
    a redraw (it re-keyed the arrow into the overflow);
  - rearranging items is only safe while expanded; a drag re-derives every
    Hidden Bar item's key from geometry;
  - do not switch window focus or move the pointer from scripts while the user
    is working; AX presses on the app's own arrow are fine;
  - never create and remove status items per collapse: each one leaks ~21 Mach ports
    on 27; fillers are parked at length 0 and reused (ARCHITECTURE.md, macOS 27);
  - session scratch directories are wiped; anything worth keeping goes in
    `tools/`, `tests/` or `docs/`.
- Work is committed to the `yoshicarroll/hidden` fork; upstream is `dwarvesf/hidden`
  (`upstream` remote). PR draft: `~/Desktop/hidden-bar-pr-360.md` (not opened).
  Test build: pre-release `v1.11-macos27-fix` on the fork; refresh with
  `gh release upload v1.11-macos27-fix <zip> --repo yoshicarroll/hidden --clobber`.
