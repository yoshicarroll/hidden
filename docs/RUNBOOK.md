# Maintainer runbook

Build, verify, and release Hidden Bar. Assumes current Xcode on macOS 13+.

## Build

```sh
# CI-style build, no signing required
xcodebuild -project 'Hidden Bar.xcodeproj' -scheme 'Hidden Bar' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

# runnable local build (uses your Apple Development identity)
xcodebuild -project 'Hidden Bar.xcodeproj' -scheme 'Hidden Bar' \
  -configuration Debug build
```

Both must exit 0 with **no** `MACOSX_DEPLOYMENT_TARGET` override; the floor is
13.0 in the project file. The single expected warning is the deliberately
deprecated `SMLoginItemSetEnabled(false)` call that cleans up legacy installs.

## Behavioral verification (no test target exists; this is the methodology)

The repo has no unit-test infrastructure; behavior is verified against the real
menu bar. Two building blocks make that scriptable:

1. **Truth signal**: the separator's AX size.
   `osascript -e 'tell application "System Events" to tell process "Hidden Bar" to get size of menu bar item 2 of menu bar 2'`
   reads ~20pt expanded vs ~2x-screen-width collapsed. Item 1 is the arrow.
2. **Real clicks, not AXPress**: `AXPress` on the arrow is a no-op because the
   action handler reads `NSApp.currentEvent` (nil under assistive synthesis;
   known accessibility defect). Post real `CGEvent` mouse clicks at the arrow's
   AX-reported coordinates instead.

Standard checks before any release:

- expand/collapse toggle flips the separator size both ways;
- with `numberOfSecondForAutoHide` set to 3, an expanded bar survives 2x the
  window while the pointer is parked in the menubar band, collapses within the
  window once the pointer leaves, and collapses normally if the pointer never
  entered;
- `hoverToExpand` off: no monitor log line, hover does nothing; on: dwell
  expands (synthesize a `mouseMoved` stream: cursor warping alone fires no
  events);
- autostart pref on -> `AutoStart: SMAppService.mainApp.status = 1` on stderr;
  off -> `= 0` (run the binary directly to capture stderr);
- localization tables stay parseable: `plutil -lint hidden/*.lproj/*.strings`.

When testing on a machine that runs Hidden Bar daily: export the prefs domain
first (`defaults export com.dwarvesv.minimalbar backup.plist`), quit the
installed app, test the dev build, then re-import and relaunch.

## Release

1. Verify the stack: every PR reviewed, builds green, behavioral checks above run.
2. Bump `MARKETING_VERSION` (both Hidden Bar configurations) and
   `CURRENT_PROJECT_VERSION` in the project file.
3. Archive + notarize (Developer ID), staple, zip, GitHub release with notes
   listing closed issues.
4. App Store (separate lane): the MAS listing has lagged GitHub since v1.8
   (issues #281/#202); decide deliberately whether a release goes there too.
5. Homebrew cask (`brew install --cask hiddenbar`) follows the GitHub release
   artifact; notarization matters (issue #219).
6. Before any public release after the SMAppService migration: one
   upgrade-path run from a launcher-era build (v1.9 or older) verifying System
   Settings shows no ghost LauncherApplication login item.

## Stacked-PR hygiene

Feature stacks land as chained PRs (`develop <- A <- B`). Merge the base PR
first, then retarget the next PR's base to `develop` BEFORE merging it;
deleting a merged branch auto-closes dependents otherwise.

## Issue triage map

The live clusters and their code areas are documented at the end of
[ARCHITECTURE.md](ARCHITECTURE.md#known-architectural-limits): notch, macOS 27
mechanism break, and pointer-vs-open-menu limits. Memory reports (#361 et al.)
have so far not reproduced as leaks (constraint-leak fix landed; `leaks` clean
over toggle stress); re-check with a 24h+ uptime `footprint` sample before
chasing further.

## Unit tests for the macOS 27 filler chain

```sh
sh tests/run-filler-chain-tests.sh
```

Compiles `FillerChain.swift` with `tests/FillerChainTests/main.swift` (plain
`swiftc`, no test target) and runs the chain against a simulated menu bar:
happy path, cached-key fast path and recovery, independent cancellation of the
two chains, cleanup after a failed placement, idempotent inserts, slow and
never-attaching frames, and cancellation mid-search. Any behaviour change to
the chain should come with a case here.

## Diagnosing a bar that expanded by itself on macOS 27

The macOS 27 code logs every collapse and expand with its trigger (arrow,
auto-collapse timer, hover, launch, separators toggled), each screen
configuration change, sleep/wake and screen sleep/wake, MenuBarAgent
relaunches, each filler placement (cached key or search, attempts, result),
rollbacks of a failed collapse, and a once-a-minute audit that reports when the
bar is collapsed but the fillers are no longer next to the separator. Notice
level persists, so the trail survives a reboot:

```sh
log show --last 6h --predicate 'subsystem == "com.dwarvesv.minimalbar"' --style compact
log stream --predicate 'subsystem == "com.dwarvesv.minimalbar"'        # live
```

Read the lines just before the unexpected state. "expand (...)" names who
asked for it; "collapse failed, rolling back to expanded" means every
placement retry failed (the preceding "filler placement failed ... retry"
lines show the attempts); an "audit:" or "MenuBarAgent relaunched" line with
no expand means the system re-laid the bar under a collapsed app. An arrow that is
missing on one display only (its slot is empty, the other bars show it) is a
hosted scene that lost its glyph when that display reconnected; the app redraws
it after displays settle, and a relaunch also restores it.

## Verifying hiding on macOS 27 without screenshots

`tools/macos27-hide-check.swift` reads what MenuBarAgent hosts on each display's
bar. Items in the native overflow are absent from that list, while their own
apps' accessibility trees keep reporting stale positions, so this is the
reliable signal. The terminal running it needs Accessibility permission.

```sh
swift tools/macos27-hide-check.swift                                # dump hosted items per display
swift tools/macos27-hide-check.swift --press --expect-visible Magnet 1Password   # toggle, then assert
swift tools/macos27-hide-check.swift --press --expect-hidden Magnet 1Password
```

Names are the owning apps' names as printed in the dump. The `--press` option
performs an accessibility press on Hidden Bar's arrow, waits for the layout to
settle, then checks. Exit status is non-zero on any failed expectation.
