# Backlog

Durable, committed index of open work. The detailed planning layer
(`_meta/megagoals/issue-list-clearing/` and `.claude/`) is local-only and gitignored,
so this file is the version that survives a machine switch and a fresh clone. Keep it
short: one line per item, pointing at the issue, SPEC, or file that holds the detail.

Source of the current state: the v1.11 issue-clearing pass (2026-06-12), branch
`fix/v1-11-batch` / draft PR #365, and SPEC-003. Core-model changes (separator length
math, collapse state machine) are HIGH RISK and require a mandatory review-team pass.

## macOS 27 follow-ups

The hide mechanism on macOS 27 is fixed (#360) with overflow-based fillers; see
ARCHITECTURE.md "Known architectural limits" for the measured behavior and
`docs/RUNBOOK.md` for how to build, verify and read the diagnostics. Branch
`fix/macos27-overflow-hiding` on the `yoshicarroll/hidden` fork; the upstream PR
is drafted (not opened) at `~/Desktop/hidden-bar-pr-360.md`; a test build is
published as pre-release `v1.11-macos27-fix` on the fork.

Open questions, in priority order:

- **Arrow stability without a drag.** An arrow placed by key only (fresh install,
  or after the automatic re-registration `hiddenbar_expandcollapse_N`) can be
  re-keyed by MenuBarAgent when it re-inserts it without room on a full display,
  ending up left of the separator or in the overflow; MenuBarAgent's log shows it
  dropping and re-acquiring its process assertion on the app every few seconds.
  A user Cmd-drag pins the position for good. The app heals the arrangement at
  launch, on a skipped collapse and between placement retries, but each heal
  produces another unpinned name. Ideas: prompt once for the drag; find what
  triggers the re-insertion; make fillers less exposed to the same re-keying
  (the audit has logged filler drift on some mornings).
- **Glyph-only loss.** Seen once: the arrow kept its slot on one display but drew
  nothing there, in both states; a relaunch restored it. Not reproduced since.
  Do NOT fix by clearing and re-setting the button image: that let MenuBarAgent
  re-key the arrow into the overflow (reverted in 6b0be33).
- **Key search on a full active display.** Probes are placed by key, but when
  the active display is full the search can bisect to a bracket a fraction of a
  unit wide; today that is treated as a jammed arrow and the arrow is
  re-registered lower. Cheaper detection, or fewer probes, would help.
- **Overflow chevron placement.** Best effort: MenuBarAgent draws its chevron
  only when the first non-fitting item starts on screen; the ladder keeps it off
  wide displays in the measured cases, not in general.
- **Collapse animation and blank stretch.** Inherent to the mechanism.
- **Key search cost.** First collapse after launch or after the separator moves
  probes up to 16 layout passes; later collapses reuse the cached key. Persisting
  the key across launches is possible. Measured and rejected: permanent fillers
  toggled with `isVisible` (#392's approach); a hidden-then-shown item reappears
  at the far left on 27.0.
- **Always-hidden section on 27.** Exercised once via the argument domain; its
  chain places and the section, separator included, goes into the overflow while
  expanded. Not yet tested with real icons dragged into that section. Note: that
  test persisted `areSeparatorsHidden = true` on the development Mac; it has no
  visible effect with the section disabled and an Option-click on the arrow
  flips it back.

## Blocked on external-display hardware

- **#351 external-monitor visible-bar (26.4) verification.** The widest-attached-screen
  fix is code-only; the 26.4 + external-display reproduction was never run. Confirm no
  full-width bar leak on a real second monitor.

## Actionable now (no special hardware)

- **UAT + merge draft PR #365.** Per the local `UAT.md` (one row per fix, click-through
  steps). Merge order matters (stacked dependency). Merge is Han's action, not the agent's.
- **Cut the v1.11 release.** Version + CHANGELOG staged in #365. Needs a Developer ID for
  notarization + App Store submission. Shipping answers the "is this still maintained?"
  issues and unblocks the round-2 close sweep.
- **Upgrade-path BTM verification before any signed release.** Install a pre-v1.11 build,
  update to v1.11, confirm Login Items shows no leftover `LauncherApplication` row (the
  one-shot `SMLoginItemSetEnabled(..., false)` deauth was added but never run on hardware).
- **AXPress accessibility defect.** VoiceOver users cannot toggle the bar: the arrow's
  `AXPress` handler reads `NSApp.currentEvent`, which is nil under assistive synthesis.
- **`hoverToExpand` Preferences checkbox.** Shipped as a Terminal-only `defaults write`;
  add a proper checkbox in `PreferencesViewController`.
- **Surface the `SMAppService` error contract in the prefs UI.** On `register()` failure
  (unsigned build, or user denies in System Settings), the checkbox stays on while the
  system says off; the error is swallowed into NSLog. Fix when the prefs UI is next touched.
  `Common/Util.swift:29-31`.
- **Round-2 issue close sweep (~35 issues).** Obsolete-OS + meta/support candidates,
  deferred until v1.11 ships so the closures carry the strongest answer.
- **24h memory dogfood (#361).** Instruments stress-cycling found no leak; run v1.11 as
  the daily driver for 24h on the Air to close the open report.
- **Old branch decision.** `feature/menubarDetection` (PR #115) and `feature/ghost-mode`
  (PR #57) were kept per never-delete. Review or discard, Han's call.

## v1.12 standalone wins (no Option D needed)

- **#207 show clock/date when collapsed.** Loudest single feature ask (18+ comments).
- **#355** prefs window layout overlap. **#324** single-instance guard. **#276** Cmd+W
  closes the prefs window. Appearance bundle via community PR #194.

## Architectural epic (Option D, #366)

- **Managed-overflow / second-bar redesign.** The real fix that gates ~30 issues across
  four clusters: icon-drift (#28, #156, #181, #230, #231, #239, #252, #254, #275, #283,
  #321, #334), always-hidden (#171, #224, #242, #288), notch (#206, #225, #228, #245,
  #267, #269, #280, #292, #330), and macOS 27 (#360). Replaces length-inflation with a
  managed overflow bar, likely via Accessibility. Needs a design decision from Han +
  macOS 27 hardware. Design + folded M1 (pin icons, persist order) / M2 (decouple
  always-hidden from `areSeparatorsHidden`, recover stuck items) in SPEC-003.
- **Security + behavior review of community PRs #358 and #350 first.** #358 (second bar,
  +1160 lines) and #350 (notch overflow, +429 lines) are the existing starting points.
  Do not merge on description alone; #358 especially needs a real review.
- **#242 permanent icon-loss repro.** Needs a throwaway defaults profile (live repro
  risks losing real menu-bar icons). Required before the always-hidden decouple lands.
