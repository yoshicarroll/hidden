# Changelog

## v1.11 (unreleased)

Requires macOS 13 Ventura or later. (Pre-Ventura users: stay on
[v1.10](https://github.com/dwarvesf/hidden/releases/tag/v1.10).)

### Added
- Opt-in hover-to-expand: set `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true` to expand the bar when the pointer dwells in the menu bar.
- Right-clicking the expand/collapse arrow now opens the same context menu as the separator, so Preferences is reachable from the control you already click.

### Fixed
- macOS 27: hiding works again (#360). The re-architected menu bar drops any status item at or above half the display width and sends items that do not fit into a native overflow menu, so the old separator inflation did nothing. On 27 the app now collapses by inserting blank filler items between the arrow and the separator; the first one that does not fit carries the separator and everything left of it into the system overflow. Works with displays of different widths and notched Macs. macOS 26 and earlier keep the original mechanism.
- macOS 27: the filler logic moved into a tested `FillerChain` state machine (`tests/run-filler-chain-tests.sh`), fixing a display change cancelling a collapse in progress, a failed placement leaving stub items on the bar and blocking later collapses, a collapse that failed to place reporting itself as collapsed, and duplicate always-hidden searches at launch.
- The expand/collapse arrow now responds to accessibility presses (VoiceOver, AXPress), which arrive without a mouse event and were ignored.
- Multi-display: the collapse width is now sized for the widest attached screen, so icons no longer leak on wider external monitors; the width re-applies on display hot-plug.
- Auto-collapse no longer fires while you are interacting with the menu bar (the timer defers and re-arms while the pointer is in the bar).
- The Preferences window no longer closes when auto-collapse fires with "use full menu bar on expanding" enabled (#170, #66, #151).
- Status items that were dragged off the bar are restored at launch instead of leaving the app unreachable.
- Fixed constraint and observer leaks in the tutorial view rebuild.
- Tutorial strings and F-key shortcut labels now render correctly (no more private-use glyphs).

### Changed
- Start-at-login now uses `SMAppService` (macOS 13+); the legacy launcher helper was removed and any leftover login item is deauthorized automatically on first launch.
- Pinned the HotKey dependency to an exact version and removed an unused file-access entitlement and dead code (no behavior change).

### Known / in progress
- macOS 27: collapsing animates icons into the system overflow instead of hiding them instantly, and the free space the fillers occupy shows as an empty stretch of menu bar. macOS may show its own overflow chevron (« or ») at the left end of that stretch depending on the frontmost app's menu width; filler sizing keeps it away on wide displays, and when it does appear it lists the hidden icons.
- New menu-bar icons can appear in the hidden zone because macOS inserts them at the far left; ⌘-drag them to the right of the separator (see the manual). A built-in pin is part of the planned redesign.
