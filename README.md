# Keychron C100 Codex status daemon

English | [日本語](README.ja.md)

A small foreground daemon and CLI that map Codex lifecycle hook events to the Keychron C100 8K's per-key RGB LEDs. Each Codex task owns one key. The daemon also suppresses the C100's normal keystrokes, reads its physical 10 by 10 switch matrix, and turns assigned key presses into Codex task navigation.

This is an unofficial, experimental personal project. It is not affiliated with or endorsed by OpenAI, Keychron, or QMK. It currently targets macOS 13 or later and has been tested only with the Keychron C100 8K identified as VID `0x3434`, PID `0x042c`. Codex status comes from hooks and local task data; actions are sent as USB keyboard input from the C100.

## Menu bar app

Build with `scripts/build-app.sh`, copy `.build/C100 Companion.app` to `~/Applications`, and open it. The menu shows connection status and offers layer selection, companion LED brightness, daemon restart, and links to configuration/logs. See [the app guide](docs/companion-app.md).

## Configuration

Machine-specific paths and device settings live in `~/.config/c100-status/config.json` (or `$XDG_CONFIG_HOME/c100-status/config.json`).

```sh
c100-status config init                 # create a portable starting point; never overwrite
c100-status config show                 # show resolved settings
c100-status install-agent --config ~/.config/c100-status/config.json
```

Edit the file before installing/restarting the agent. Set `backend` to `companion` for a C100 already running the companion firmware. Use `claudeConfigDirs` for your own profile directories; the list replaces defaults. See [the example](config.example.json) and [configuration reference](docs/configuration.md) for all keys and precedence.

## Required firmware and setup

**Companion firmware is required.** Start with the [step-by-step flashing and recovery guide (Japanese)](firmware/FLASHING.ja.md) and the [English build/protocol reference](firmware/README.md). The guide covers the exact supported model, pinned source build, K00 DFU entry, original-flash backup, download, readback comparison, normal USB verification, and recovery. Building alone never flashes the keyboard.

Once flashed, the C100 is a dedicated controller and remains silent without the daemon. Restoring ordinary keyboard use requires restoring firmware, not just unplugging it. `run` rejects firmware that fails the companion handshake; only a compatible device is controlled.

After flashing, build and install the app as the logged-in user:

```sh
swift build -c release
.build/release/c100-status self-test
scripts/build-app.sh --skip-build
mkdir -p "$HOME/Applications"
ditto '.build/C100 Companion.app' "$HOME/Applications/C100 Companion.app"
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" config init
```

`config init` does not overwrite existing settings. Review your config before starting. Set `backend` to `companion`; omitting it also selects companion. Device locations are machine/port-specific: use `list`, not another machine's example value.

```sh
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" install-agent
open "$HOME/Applications/C100 Companion.app" --args app --layout
"$HOME/Applications/C100 Companion.app/Contents/MacOS/c100-status" inspect
```

Expect `connected: true`, `backend: companion`, and `actionTransport: keyboard-hid` with the keyboard-output extension. If the executable is not on PATH, use the installed absolute path wherever this README says `c100-status`.

The per-user LaunchAgent is `~/Library/LaunchAgents/com.kotainaba.c100-status.run.plist`. It starts at login and is kept alive by launchd. `--label` changes its label; `--binary` changes its executable. `install-agent --dry-run` previews registration, and `install-agent --uninstall` stops/removes it. Neither `run` nor `install-agent` runs as root. Stop manual daemons/watchers before installing to avoid competing over the device/socket.

Before replacing the app, save pending edits and stop the app/daemon. Re-run `install-agent` after copying the rebuilt app to restart the installed process.

### Input, permissions, and LEDs

- No root helper or Input Monitoring setup is needed. Firmware USB keyboard output also requires no Accessibility permission.
- Ghostty tab navigation uses separate macOS Automation permission.
- Firmware suppresses ordinary keystrokes. The daemon verifies a physical press, the foreground app, and enabled services before authorizing a mapped USB shortcut.
- Other keyboards are untouched. Device selection is restricted to VID `3434`, PID `042c`, and the selected physical `locationID`.
- LED state and shortcut assignments are volatile; no `SaveLedConf` or EEPROM writes are used. Loss of host traffic blacks out the device and revokes output after about three seconds.
- Close Keychron Launcher, and do not run diagnostic watchers alongside the daemon.
- Hooks are best-effort; a stopped daemon does not block Codex. Socket/runtime files are user-only.

LED indexes are row-major `row * 10 + column`, with zero-based rows/columns and indexes `0...99`. Named colors are `off`, `white`, `red`, `green`, `blue`, and `amber`.

```sh
c100-status ping
c100-status inspect
c100-status logs
tail -f "$(c100-status log-path)"
```


## Safe daemon dry-run

Terminal 1:

```sh
.build/release/c100-status run --dry-run
```

Terminal 2:

```sh
.build/release/c100-status ping
printf '%s' '{"session_id":"dry-run","hook_event_name":"PermissionRequest"}' \
  | .build/release/c100-status hook
.build/release/c100-status logs
```

The daemon records state transitions but skips all HID access in dry-run mode.

## Codex hooks

Start the daemon first. Then copy `hooks.example.json` to a trusted Codex hook layer and replace `/ABSOLUTE/PATH/TO/c100-status` with the release executable's absolute path. Codex requires reviewing and trusting non-managed hooks before they run.

The mapping is:

| Codex event | LED state |
| --- | --- |
| `SessionStart` | white (`idle`) |
| `UserPromptSubmit`, `PostToolUse` | blue (`working`) |
| `PermissionRequest` | amber (`approval`) after a 500 ms debounce only when routed to the user |
| `PreToolUse` | blue (`working`); cancels a pending approval display |
| `Stop` | green (`done`) |
| `SessionEnd` | white (`idle`) while the task remains cataloged |

Each hook invocation is a short-lived sender. The foreground daemon maps projects to rows and tasks inside each project to columns. The visible key is computed from the vertical window and the shared horizontal offset. Project rows follow Codex app's saved `project-order`, including empty project rows. Tasks follow the app's pinned/explicit sidebar order, then its recency order. Tasks without a saved project are grouped into one final `projectless` row instead of receiving one row per working directory. The top eight rows show ten tasks per project at a time; additional projects and tasks remain tracked and are reachable by scrolling.

The daemon rereads the Codex catalog and sidebar state every two seconds. Adding or reordering projects, and adding or reordering tasks within a project, therefore remaps the grid without restarting the daemon. Existing task status colors move with their tasks.

Lifecycle hooks whose `session_id` is not yet present in the Codex app task catalog are held in memory for up to six seconds instead of receiving a key immediately. If the task appears during that window, its latest status is applied after catalog placement; otherwise the event is dropped as an internal or non-app execution session. This prevents executor-scoped `PostToolUse` events from repeatedly creating and releasing phantom keys. Hook diagnostic metadata (`turn_id`, `agent_id`, and `agent_type`) is included in the daemon log when Codex supplies it.

An assigned session at rest is white (`idle`, HSV value 96/255). Active status events temporarily replace that baseline with blue, amber, green, or red according to the table above. `SessionEnd` returns the task to white. Its key is turned off and released only after the task disappears from the Codex app task catalog.

`PermissionRequest` runs before Codex chooses between automatic review and a user-facing approval, so the hook event alone is not an approval-wait signal. The daemon reads the hook's `tool_name` and the task rollout's current `approvals_reviewer`: explicit `request_permissions` calls and tasks using the `user` reviewer become amber after 500 ms, while `auto_review`/`guardian_subagent` requests remain blue. If the reviewer cannot be resolved, the daemon also remains blue to avoid a false user-wait indication. A later lifecycle event resolves any pending amber state.

Pressing a green (`done`) session key acknowledges the completed state after Codex navigation succeeds and returns that key to white (`idle`). Other active status colors are left unchanged.

Codex does not emit the `Stop` hook when an active turn is interrupted with Esc. The daemon therefore tails the local Codex rollout for each assigned task during its two-second catalog refresh. A new `turn_aborted` event returns only that interrupted task from blue or amber to white.

Project identity honors explicit projectless selection and Codex task-to-project assignments first. Tasks without an assignment or catalog project ID are matched against saved local project roots (longest directory match, including multiple roots and workspace-root hints). Ambiguous roots remain projectless. The grid groups Codex tasks by resolved project ID, so separate saved projects never merge just because they share a working directory. The top eight rows are a scrollable window into the complete catalog. Projectless chats follow the named projects and scroll normally; they are not pinned to a physical row. Offscreen task status is retained. See [scroll controls](docs/scrolling.md).

Codex forks inherit their source task's project by following the recorded fork and subagent ancestry. This keeps both same-directory session forks and separate-worktree forks on the source project's row while assigning each fork its own column and key.

Pressing an assigned key navigates to `codex://threads/<session_id>`. If the Codex app is already running, one press navigates immediately. If Codex is not running, the same key must be pressed twice within 350 ms before the app is launched and navigated.

## Claude Code (herdr / terminal / Claude Desktop)

The daemon tracks herdr, plain-terminal (Ghostty), and Claude Desktop Claude Code sessions on independent source layers. Different services do not merge rows even when they share a working directory.

A session with tracked subagents remains blue even while its parent is idle. `SubagentStart`/`SubagentStop` track each agent; the last stop restores the parent's own status. Tracking expires after two hours. After a 30-minute grace period, each individual subagent is also removed if its own transcript cannot be confirmed fresh; one active sibling does not keep a stale agent alive.

### Installing the Claude Code hooks

Claude Code reads hooks from `settings.json` in each configured profile directory (`claudeConfigDirs`). The default is `$CLAUDE_CONFIG_DIR`, falling back to `~/.claude`.

The easiest way to install them is `c100-status install-claude-hooks`:

```
c100-status install-claude-hooks --dry-run   # preview what would change
c100-status install-claude-hooks             # write it for real
```

This targets exactly the configured `claudeConfigDirs`; pass one or more `--config-dir PATH` to install into a different set instead, and `--binary PATH` to point at a specific executable instead of auto-detecting this one's absolute path. It's idempotent -- re-running it after a rebuild (to pick up a new absolute path) or with no changes at all is always safe, and it only ever adds/replaces the `c100-status`-owned entries: any other hooks already in `settings.json` (see herdr below) are left completely alone. Before writing, the current `settings.json` is copied to `settings.json.c100-backup-<epoch-ms>` alongside it. Run with `--uninstall` to remove only the `c100-status` entries again. A config directory with no `settings.json` is skipped (a warning is printed, nothing is created); a `settings.json` that fails to parse is left untouched and reported as an error rather than risking data loss. Claude Code still requires reviewing and trusting non-managed hooks before they run.

If you'd rather do it by hand, merge the contents of `hooks.claude.example.json` into a config directory's `settings.json` yourself, replacing `/ABSOLUTE/PATH/TO/c100-status` with the release executable's absolute path.

If you also use herdr, it manages its own `hooks/herdr-agent-state.sh` entries in the same `settings.json` files; `install-claude-hooks` (and, if merging by hand, you) must add the `c100-status hook --source claude` entries as additional array entries alongside herdr's, not by editing or replacing them -- each event array (e.g. `PostToolUse`) can hold multiple hook entries and Claude Code runs all of them. If herdr later regenerates `settings.json` (it can overwrite the file when its own config changes), the `c100-status` entries are not preserved by herdr and `install-claude-hooks` must be re-run.

### How the herdr integration works

While `run` is active, a dedicated background thread polls `herdr agent list` and `herdr workspace list` every two seconds (independent of the daemon's 10 ms HID poll loop, so a slow or hung herdr call never affects key-press responsiveness). Only `"agent":"claude"` entries are tracked. Each herdr-reported session is placed using:

- **Row**: herdr's `workspace_id`/`number` (ascending), within the herdr layer.
- **Column**: dense position after sorting panes by tab, vertical position, horizontal position, and pane number.
- **Initial status**: herdr's `agent_status` (`idle`/`working`/`blocked`/`done`/`unknown` -> `idle`/`working`/`approval`/`done`/`idle`), used only until the session's first Claude Code hook arrives -- after that, hook events are authoritative. If herdr keeps reporting `idle`/`done` for two consecutive polls while no hook has been seen since, the daemon treats the hook as missed and applies herdr's status directly (recovery path).

If `herdr agent list`/`workspace list` fails, the daemon keeps showing the last successful snapshot for 15 seconds before treating herdr as empty (so a brief hiccup doesn't blank the grid). When a pane closes (or herdr stops reporting a session it previously reported), that session's key is released immediately, the same as a Codex session leaving the catalog.

Pressing an assigned herdr session's key runs `herdr agent focus <pane_id>` (200 ms timeout, best-effort -- a timeout or failure is logged but does not block the rest of navigation) and then activates Ghostty (`com.mitchellh.ghostty`) via `NSWorkspace`, since herdr itself has no window-foregrounding capability. If Ghostty isn't installed, this is logged and the key press is otherwise a no-op.

### Locating the herdr binary

The daemon resolves `herdr` in this order: `--herdr-bin PATH` > configuration `herdrBinary` > `HERDR_BIN` environment variable > absolute directories in `PATH` > `/opt/homebrew/bin/herdr` > `/usr/local/bin/herdr` > `~/.cargo/bin/herdr`. If none resolve to an executable, herdr support is silently disabled (a single INFO log line at startup) and the daemon otherwise behaves exactly as it did before M2.

### How plain-terminal (Ghostty) Claude Code sessions work

A `claude` process launched directly in a terminal -- no herdr, no Claude Desktop -- is tracked two ways at once:

- **Hooks are authoritative for status.** The same `c100-status hook --source claude` entries used for herdr (see "Installing the Claude Code hooks" above) register/update the session and drive its idle/working/approval/done state.
- **`sessions/<pid>.json` is authoritative for placement.** Claude Code writes one small JSON file per running process under `<configDir>/sessions/<pid>.json` (fields used: `pid`, `sessionId`, `cwd`; other fields such as `version`, `peerFeatures`, `messagingSocketPath` are ignored). Every sync (2s cadence), the daemon scans this file across the configured `claudeConfigDirs`, confirms the `pid` in the filename is still alive (`kill(pid, 0)`), and uses the file's `cwd` for row/column grouping. This lets a session already running when the daemon starts get seeded onto the grid immediately, without waiting for its next hook event.

Each `sessions/<pid>.json` file is opened with `O_NOFOLLOW` (refusing symlinks) and capped at 64 KiB before being parsed; oversized or non-regular files are skipped rather than read.

If a session herdr is also tracking is the same Claude Code process (i.e. the same session id shows up in both the herdr poll and the terminal scan), herdr's placement wins and the terminal-scan copy is dropped -- avoiding a session flapping between two different row/column placements every sync.

Two independent garbage-collection paths cover a terminal session ending without ever going through Claude Code's normal shutdown: if a hook-registered session's `sessions/<pid>.json` disappears or its pid dies without a `SessionEnd` hook ever arriving (crash, `kill -9`), it's removed on the next sync; separately, any hook-registered Claude session (herdr, terminal, or desktop alike) whose transcript `.jsonl` file hasn't been modified in 30 minutes is presumed abandoned and removed as a safety net.

Pressing an assigned terminal session's key runs an AppleScript against Ghostty (`com.mitchellh.ghostty`) that walks every open window/tab/terminal looking for one whose `working directory` matches the session's `cwd` exactly, then activates its window, selects its tab, and focuses the terminal (Ghostty's AppleScript dictionary does not expose a terminal's underlying pid, so `cwd` is the only usable identifying property; if more than one open tab shares the same cwd, the first match wins). The `cwd` value is passed as an `osascript` `argv` argument, never interpolated into the script text, so it cannot be used to inject additional AppleScript. The script runs with a 1 second hard timeout; if it times out, macOS Automation permission for the daemon hasn't been granted (or was revoked), or no tab matches, the daemon logs why and falls back to just activating Ghostty via `NSWorkspace`, the same fallback herdr navigation uses. The first time this fires, macOS will prompt to allow the daemon to control Ghostty via Apple Events (System Settings > Privacy & Security > Automation) -- until that's approved, every key press falls back to just activating Ghostty without a specific tab.

Note: Ghostty's AppleScript dictionary only exposes `environment variables` as a write-only property used when *creating* a new terminal; it cannot be read back from an already-running terminal to identify a session more precisely, which is why matching is cwd-based rather than session-id-based.

### How Claude Desktop sessions work

Claude Desktop is identified by `CLAUDE_CODE_ENTRYPOINT=claude-desktop`. Its transcript profile defaults to `~/.claude`; set `claudeDesktopConfigDir` when it differs, and include that profile in `claudeConfigDirs` when installing hooks. As with terminal sessions, **hooks are authoritative for status**; the on-disk scan below exists only to seed already-open sessions on daemon startup and to garbage-collect sessions Desktop never sent a `SessionEnd` hook for.

Desktop writes one file per session under `~/Library/Application Support/Claude/claude-code-sessions/<accountId>/<workspaceId>/local_<uuid>.json` (override the scanned root with `--claude-desktop-dir`). The file's own `sessionId` carries the `local_` prefix and is Desktop-internal; the field the daemon actually uses as the session id is `cliSessionId`, which matches the Claude Code hook `session_id` and the `<cliSessionId>.jsonl` transcript filename. `scheduled-tasks.json` in the same directory is unrelated and ignored.

A session counts as alive if it isn't archived (`isArchived: false`) and at least one of the following holds: its `lastActivityAt` is within 6 hours, its transcript `.jsonl` mtime is within 6 hours, or the daemon has already hook-registered it as a `claude-desktop` session (hooks are authoritative once they've fired, so a session the daemon has heard from directly is never dropped just because this scan's timestamps look old). If Claude Desktop (`com.anthropic.claudefordesktop`) isn't currently running, the scan reports no sessions at all -- there would be nothing to navigate to, and a quit app can't send `SessionEnd` for whatever it had open.

**The current navigation adapter does not target a specific Claude Desktop session.** This describes the implemented fallback, not a claim about every capability of current or future Claude URL schemes. Pressing its key does one of two things:

- If that session's current status is `approval`, it opens `claude://code/needs-input`, which shows Desktop's cross-session "needs your input" list (not the specific session, but a real navigational improvement over nothing).
- For any other status, it just activates Claude Desktop via `NSWorkspace` (bringing the app forward, without selecting a particular conversation), the same "best available fallback" herdr and Ghostty navigation use when they can't pinpoint a window.

**SDK-mode notification caveat**: Claude Desktop's Claude Code runs in SDK mode rather than as the interactive TUI, and this project has not exhaustively verified that `Notification` hook events (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `agent_completed`) fire identically to the TUI in every case. `PermissionRequest` (fired on every tool permission check, independent of SDK vs. TUI mode) is the primary, more reliably-observed signal this daemon relies on for detecting a Desktop session waiting on approval; if your Desktop sessions don't light up amber when you'd expect, check `/tmp/keychron-c100-status-<uid>.log` for which hook events are actually arriving.

## Layers (per-source grids)

The keyboard multiplexes four independent grids ("layers"), one per session source: Codex Desktop, herdr, plain-terminal Claude Code, and Claude Desktop. Only one layer's sessions are shown on the main 0-79 key grid at a time; switching layers is instant and every layer keeps its own row/project bookkeeping, so a herdr session and a Codex session that happen to share a cwd never merge into (or fight over) the same row.

**In the default layout, the bottom two physical rows (keys 80–99) are utility rows.** The editor can resize/reposition the task area and controls. Key 88 is up, and 97/98/99 are left/down/right. Horizontal scrolling moves all project rows together; keys 80–87 are inactive. Keys 90–93 retain the layer switches; 89 and 94–96 stay off.

| Key | Layer | Base color | Why |
| --- | --- | --- | --- |
| 90 | Codex | Blue-violet / indigo (~#5B5BF5-#6466F1) | OpenAI Codex's own brand color |
| 91 | herdr | Azure / dodger blue (`#4a9eff`) | herdr.dev's own `--accent` CSS variable (its default `terminal`/`herdr`/`taat` theme) |
| 92 | Claude CLI (terminal) | Anthropic "Claude orange" (~#D97757) | Claude Code's own brand coral/terracotta |
| 93 | Claude Desktop | Same Claude family, rotated toward red/burgundy and dimmed | Keeps the two Claude-sourced layers visually distinct from each other at a glance |

Pressing a layer key switches the active layer immediately and persists the choice to `/tmp/keychron-c100-status-<uid>-layer.json`, so a daemon restart resumes on the same layer. The default (first run, or if that file is missing/corrupt) is Codex; set `defaultLayer` to change it. A saved selection takes precedence.

**Non-active layers still light up their key** so you know something needs attention without switching over: whenever a background layer has a session in `approval`, `error`, or `done` (checked in that priority order), its key blinks -- toggling roughly every 600ms between its normal base color and that status's real color -- instead of staying static. The active layer's key uses its active-state brightness without blinking; overall brightness still applies. Because a layer's brand hue can sit close to a status color (Codex's blue-violet is near `.working`'s blue; Claude's orange is near `.approval`'s amber and `.error`'s red), the blink -- not the static color alone -- is what makes "this layer needs attention" reliably distinguishable from "this is just the layer's resting color".

Hooks and catalog syncs for non-active layers keep updating that layer's internal state (and therefore its key's blink) in the background; they just don't repaint the main grid until you switch to that layer. Navigating a key (0-79) and the "press a done session to mark it read" acknowledgement only ever apply to the currently active layer's sessions.

## Runtime paths and options

- Socket: `/tmp/keychron-c100-status-<uid>.sock`; override with `--socket PATH` on both daemon and clients.
- Log: `/tmp/keychron-c100-status-<uid>.log`; override with `--log-file PATH` on `run`, `logs`, and `log-path`.
- Device: pass the location reported by `list` to `run --location` when selecting among multiple C100 devices.
- Claude Code config directories: set `claudeConfigDirs` or `--claude-config-dirs PATH1,PATH2` to replace the scanned profile list. No named personal profiles are added implicitly.
- Claude Desktop sessions directory: `~/Library/Application Support/Claude/claude-code-sessions`; override with `--claude-desktop-dir PATH`.
- Device compatibility: the daemon requires a successful companion firmware handshake.

`apply <status>` bypasses the daemon and writes directly to HID. Use it only for troubleshooting while the daemon and Keychron Launcher are stopped.

## Uninstall

If `run` was installed as a LaunchAgent, remove it first:

```sh
.build/release/c100-status install-agent --uninstall
```

Otherwise stop the foreground daemon (Ctrl-C). The user-owned runtime socket, status log, and local Codex data are not removed.

## Current limitation

`clear` clears volatile status display. It does not restore the original keyboard firmware or saved RGB configuration. To restore ordinary keyboard use, follow the firmware recovery guide.

Existing-task bootstrap reads Codex's local SQLite task catalog. Failure is non-fatal and is reported in the daemon log; lifecycle hooks continue to work independently.

## License and protocol references

The original Swift source in this repository is licensed under the MIT License. See [LICENSE](LICENSE). Interoperability notes and third-party acknowledgements are in [NOTICE.md](NOTICE.md).

## Layout, actions, and services

The settings window has three tabs. **Layout** uses an inline right panel for clicked keys, with function selection, action search, position/size controls and drag-to-move. There is no placed-parts list or assignment modal. **Actions** shows outgoing shortcuts for selected services and distinguishes imported Codex settings, bundled Claude Code-tab defaults and unsupported routes. **Services** configures enabled providers, initial display and profile/data paths.

Assign one semantic action per key. Enabled services and the foreground app determine the outgoing shortcut; disabled services never receive it. Multiple keys may share an action. Claude Desktop settings import and Claude archive delivery remain unsupported. Claude CLI/herdr task tracking/navigation works, but their keyboard action routes are not implemented. See [the layout editor](docs/layout-editor.md).

## Browser firmware installer

The [experimental Web Flasher](https://shiroinock.github.io/codex-macro/) targets Chrome on macOS. It requires a downloaded backup to be reselected and compared before writing, verifies flash by reading it back, and supports restoring a device backup. Backups stay local. The user confirmed physical backup saving, flashing, readback comparison, and Companion operation after restart. A follow-up test also confirmed restoring the original stock backup, ordinary keyboard input, and reinstalling companion firmware. See the [validation record](firmware/VALIDATION.md) and [CLI guide](firmware/FLASHING.ja.md).
