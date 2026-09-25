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

### Testing on macOS 27: build sandboxed

On macOS 27 the app must run **sandboxed** to behave like the shipping build.
An unsandboxed debug build reads its defaults from a different domain than the
system expects, and the position keys the app writes are ignored, so hiding
silently fails. Ad-hoc signing with the entitlements is enough:

```sh
xcodebuild -project 'Hidden Bar.xcodeproj' -scheme 'Hidden Bar' -configuration Release \
  -derivedDataPath /tmp/hb-build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_ENTITLEMENTS=hidden/Hidden.entitlements build
pkill -f "Hidden Bar.app"; rm -rf "/Applications/Hidden Bar.app"
cp -R "/tmp/hb-build/Build/Products/Release/Hidden Bar.app" /Applications/
open "/Applications/Hidden Bar.app"
```

The app auto-collapses about a second after launch; give it ten seconds
before checking. Preferences of a sandboxed app cannot be written from a
terminal (`defaults write` fails on the container); to test a preference, pass
it in the argument domain instead, e.g.
`"/Applications/Hidden Bar.app/Contents/MacOS/Hidden Bar" -alwaysHiddenSectionEnabled YES`.
Note that the app's own setters may then persist it.

## Behavioral verification (no test target exists; this is the methodology)

The repo has no unit-test infrastructure; behavior is verified against the real
menu bar. Two building blocks make that scriptable:

1. **Truth signal**. macOS <= 26: the separator's AX size
   (`osascript -e 'tell application "System Events" to tell process "Hidden Bar" to get size of menu bar item 2 of menu bar 2'`
   reads ~20pt expanded vs ~2x-screen-width collapsed). macOS 27: the separator
   never changes size; use `tools/macos27-hide-check.swift` (below), which reads
   what MenuBarAgent actually hosts on each bar. Screenshots (`screencapture`)
   are the other reliable signal; both need a permission for the terminal
   (Accessibility, Screen Recording).
2. **Clicks**: `AXPress` on the arrow toggles it (the handler treats a press
   with no mouse event as a plain click since v1.11); the check tool's
   `--press` uses it. Never switch the user's window focus or move the pointer
   from a script on a machine someone is working on.

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
no expand means the system re-laid the bar under a collapsed app. "arrow is left of the
separator" followed by "arrow re-registered as hiddenbar_expandcollapse_N" is
the self-heal: the arrow takes a fresh autosave name at a key right of the
separator, because macOS 27 remembers positions by name and offers no way to
move an item. Never act on the audit from code: clearing and re-setting the
arrow's image to force a redraw was tried and MenuBarAgent re-keyed the arrow
into the overflow.

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

## Working on the macOS 27 code (read before touching it)

- The mechanism lives in `hidden/Features/StatusBar/FillerChain.swift` and the
  macOS 27 sections of `StatusBarController.swift`. Everything measured about
  MenuBarAgent's layout is in ARCHITECTURE.md; trust it over intuition.
- Add a case to `tests/FillerChainTests/main.swift` for any behaviour change to
  the chain, and verify on the real bar with a **sandboxed** build and
  `tools/macos27-hide-check.swift`; read the diagnostics log after each change.
- Never act on the audit from code, and never clear the arrow's image to force
  a redraw: that let MenuBarAgent re-key the arrow into the overflow.
- Rearranging items is only safe while expanded; a drag makes MenuBarAgent
  re-derive every Hidden Bar item's key from geometry.
- An arrow placed by key only (fresh install, or after an automatic
  re-registration) is not pinned until the user Cmd-drags it once.
- From scripts, never switch the user's window focus or move the pointer on a
  machine someone is working on; accessibility presses on the app's own arrow
  are fine.
- The branch is `fix/macos27-overflow-hiding` on the `yoshicarroll/hidden` fork
  (`upstream` is `dwarvesf/hidden`); the upstream PR draft is kept outside the
  repo; a test build is published as pre-release `v1.11-macos27-fix` on the fork
  (`gh release upload v1.11-macos27-fix <zip> --repo yoshicarroll/hidden --clobber`).
