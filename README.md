# Keychron C100 Codex status daemon

A small foreground daemon and CLI that map Codex lifecycle hook events to the Keychron C100 8K's per-key RGB LEDs. Each Codex task owns one key. The daemon also suppresses the C100's normal keystrokes, reads its physical 10 by 10 switch matrix, and turns assigned key presses into Codex task navigation.

This is an unofficial, experimental personal project. It is not affiliated with or endorsed by OpenAI, Keychron, or QMK. It currently targets macOS 13 or later and has been tested only with the Keychron C100 8K identified as VID `0x3434`, PID `0x042c`. Its Codex integration depends on undocumented local Codex Desktop interfaces that can change between releases.

## Safety properties

- Matches only Keychron VID `0x3434`, PID `0x042c`, and the selected physical `locationID`.
- Does not use Karabiner, event taps, or Accessibility. The C100 must be excluded from Karabiner so this process can exclusively capture its keyboard HID interface.
- The installed root helper only leases exclusive keyboard capture. It does not read Codex data, control LEDs, or open app URLs; those stay in the user process.
- The helper is assembled in a private root-owned staging directory, ad-hoc signed, and then moved into place as a root-owned App Bundle. launchd never executes the build artifact from the user-writable project directory.
- The helper accepts capture requests only for the device `locationID` fixed at installation time.
- A three-second renewable lease releases the C100 automatically if the foreground user daemon exits or crashes.
- Physical position comes from the C100 vendor protocol's 10 by 10 matrix state, not from the emitted keycode. Duplicate key assignments are therefore safe.
- Does not send Keychron's `SaveLedConf` command; status colors are volatile.
- `list` and `--dry-run` do not write to the keyboard.
- Codex hooks are best-effort: a stopped daemon never blocks the Codex agentic loop.
- The Unix socket and runtime files are user-only and live under `/tmp` by default.
- Close Keychron Launcher before writing, because both clients may compete for the same vendor HID interface.

## Build

```sh
swift build -c release
.build/release/c100-status self-test
.build/release/c100-status list
```

The currently observed device location is `0x110000`. Install the privileged grabber once:

```sh
sudo .build/release/c100-status install-helper --location 0x110000
.build/release/c100-status grabber-status
```

The installer creates the root-owned, background-only `/Applications/C100 Status Grabber.app` and registers a root-owned LaunchDaemon under `/Library/LaunchDaemons`. The app bundle exists so it can be selected in macOS's Input Monitoring privacy pane; it has no Dock icon or user interface. The helper starts automatically but does not seize the keyboard until the user daemon requests a lease.

After installation, open **System Settings > Privacy & Security > Input Monitoring**, add **C100 Status Grabber** from `/Applications`, and enable it. Then restart the helper once:

```sh
sudo launchctl kickstart -k system/com.kotainaba.c100-status.grabber
```

After that, run without `sudo`:

```sh
.build/release/c100-status run --location 0x110000
```

`run` deliberately refuses to start as root. Administrative privileges are used only by `install-helper` and `uninstall-helper`.

Re-run `install-helper` after rebuilding or updating the executable. Because the locally built App Bundle is ad-hoc signed, macOS may ask you to enable Input Monitoring again after replacement.

`run` stays in the foreground as the logged-in user. While it renews the helper lease, normal keystrokes from the C100 are suppressed; other keyboards are unaffected. Press Ctrl-C to release the lease and stop the daemon. A crash releases the lease within three seconds. It logs to both the terminal and `/tmp/keychron-c100-status-<uid>.log`.

The local daemon protocol is newline-framed. A client that connects but does not finish a request is disconnected after 500 ms, so it cannot block HID polling or helper lease renewal. If any other synchronous operation stalls the main loop for at least 750 ms, the daemon logs `daemon loop delayed duration_ms=...` after it recovers.

At startup, the daemon turns all 100 LEDs off, then imports existing local Codex tasks from the read-only Codex task catalog. User-created Codex forks are supplemented from the local Codex state database because they are not exposed in that catalog; internal subagent sessions remain excluded. Imported tasks begin dim white. The catalog is refreshed periodically so a task can be assigned before its first lifecycle hook arrives. Catalog entries that disappear are released. `SessionEnd` only returns a still-cataloged task to dim white because Codex also emits it while unloading task history during app shutdown or restart.

The C100 firmware ignores the per-key HSV value component in its solid per-key renderer, so sending black does not turn off one key. The daemon therefore uses the volatile mixed-RGB mode: assigned keys belong to a region rendered by the per-key effect, while unassigned keys belong to a region with no effect. No firmware or EEPROM write is required.

From another terminal:

```sh
.build/release/c100-status ping
.build/release/c100-status status working
.build/release/c100-status status approval
.build/release/c100-status status done
.build/release/c100-status key 42 red
.build/release/c100-status key 42 off
.build/release/c100-status clear
.build/release/c100-status logs
tail -f "$(.build/release/c100-status log-path)"
```

Individual LEDs use zero-based indexes `0...99`. On a logical 10 by 10 grid,
the index is `row * 10 + column`, with both row and column starting at zero.
Available named colors are `off`, `white`, `red`, `green`, `blue`, and `amber`.
The LED order and the physical matrix order have both been verified as this same
row-major `0...99` index.

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
| `SessionStart` | dim white (`idle`) |
| `UserPromptSubmit`, `PostToolUse` | blue (`working`) |
| `PermissionRequest` | amber (`approval`) after a 500 ms debounce only when routed to the user |
| `PreToolUse` | blue (`working`); cancels a pending approval display |
| `Stop` | green (`done`) |
| `SessionEnd` | dim white (`idle`) while the task remains cataloged |

Each hook invocation is a short-lived sender. The foreground daemon maps projects to rows and tasks inside each project to columns. Thus `keyIndex = projectRow * 10 + sessionColumn`. Project rows follow Codex app's saved `project-order`, including empty project rows. Tasks follow the app's pinned/explicit sidebar order, then its recency order. Tasks without a saved project are grouped into one final `projectless` row instead of receiving one row per working directory. The 10 by 10 grid supports up to 10 rows and 10 tasks per row.

The daemon rereads the Codex catalog and sidebar state every two seconds. Adding or reordering projects, and adding or reordering tasks within a project, therefore remaps the grid without restarting the daemon. Existing task status colors move with their tasks.

Lifecycle hooks whose `session_id` is not yet present in the Codex app task catalog are held in memory for up to six seconds instead of receiving a key immediately. If the task appears during that window, its latest status is applied after catalog placement; otherwise the event is dropped as an internal or non-app execution session. This prevents executor-scoped `PostToolUse` events from repeatedly creating and releasing phantom keys. Hook diagnostic metadata (`turn_id`, `agent_id`, and `agent_type`) is included in the daemon log when Codex supplies it.

An assigned session at rest is dim white (`idle`). Active status events temporarily replace that baseline with blue, amber, green, or red according to the table above. `SessionEnd` returns the task to dim white. Its key is turned off and released only after the task disappears from the Codex app task catalog.

`PermissionRequest` runs before Codex chooses between automatic review and a user-facing approval, so the hook event alone is not an approval-wait signal. The daemon reads the hook's `tool_name` and the task rollout's current `approvals_reviewer`: explicit `request_permissions` calls and tasks using the `user` reviewer become amber after 500 ms, while `auto_review`/`guardian_subagent` requests remain blue. If the reviewer cannot be resolved, the daemon also remains blue to avoid a false user-wait indication. A later lifecycle event resolves any pending amber state.

Pressing a green (`done`) session key acknowledges the completed state after Codex navigation succeeds and returns that key to dim white (`idle`). Other active status colors are left unchanged.

Codex does not emit the `Stop` hook when an active turn is interrupted with Esc. The daemon therefore tails the local Codex rollout for each assigned task during its two-second catalog refresh. A new `turn_aborted` event returns only that interrupted task from blue or amber to dim white.

Project identity uses Codex's local task-to-project assignment, so each worktree shares a row with its saved Codex project without merging separately saved projects that happen to use the same Git origin. Tasks without a project assignment fall back to their exact normalized working-directory path. The 10 most recently active projects and up to 10 most recent tasks per project fit on the physical grid.

Codex forks inherit their source task's project by following the recorded fork and subagent ancestry. This keeps both same-directory session forks and separate-worktree forks on the source project's row while assigning each fork its own column and key.

Pressing an assigned key navigates to `codex://threads/<session_id>`. If the Codex app is already running, one press navigates immediately. If Codex is not running, the same key must be pressed twice within 350 ms before the app is launched and navigated.

## Claude Code (herdr / terminal / Claude Desktop)

The daemon also tracks Claude Code sessions alongside Codex, on the same 10 by 10 grid (rows merge by shared cwd/project, so a herdr pane and a Codex task in the same working directory can share a row). As of M2, the herdr integration is implemented; plain-terminal and Claude Desktop navigation (M3/M4) still fall back to logging the intent instead of navigating.

### Installing the Claude Code hooks

Claude Code reads hooks from `settings.json` in one of three config directories, depending on how it's launched:

- `~/.claude` (plain terminal and Claude Desktop)
- `~/.claude-config/max`
- `~/.claude-config/enterprise`

For each config directory you use, merge the contents of `hooks.claude.example.json` into that directory's `settings.json`, replacing `/ABSOLUTE/PATH/TO/c100-status` with the release executable's absolute path. Claude Code requires reviewing and trusting non-managed hooks before they run.

If you also use herdr, it manages its own `hooks/herdr-agent-state.sh` entries in the same `settings.json` files. **Add the `c100-status hook --source claude` entries as additional array entries alongside herdr's, not by editing or replacing them** -- each event array (e.g. `PostToolUse`) can hold multiple hook entries and Claude Code runs all of them. If herdr later regenerates `settings.json` (it can overwrite the file when its own config changes), the `c100-status` entries you added are not preserved by herdr and must be re-merged.

### How the herdr integration works

While `run` is active, a dedicated background thread polls `herdr agent list` and `herdr workspace list` every two seconds (independent of the daemon's 10 ms HID poll loop, so a slow or hung herdr call never affects key-press responsiveness). Only `"agent":"claude"` entries are tracked. Each herdr-reported session is placed using:

- **Row**: herdr's `workspace_id`/`number` (ascending), merged onto an existing Codex row if their cwds are the same directory.
- **Column**: the pane's number in its `pane_id` (e.g. `w9:p1` -> column 0).
- **Initial status**: herdr's `agent_status` (`idle`/`working`/`blocked`/`done`/`unknown` -> `idle`/`working`/`approval`/`done`/`idle`), used only until the session's first Claude Code hook arrives -- after that, hook events are authoritative. If herdr keeps reporting `idle`/`done` for two consecutive polls while no hook has been seen since, the daemon treats the hook as missed and applies herdr's status directly (recovery path).

If `herdr agent list`/`workspace list` fails, the daemon keeps showing the last successful snapshot for 15 seconds before treating herdr as empty (so a brief hiccup doesn't blank the grid). When a pane closes (or herdr stops reporting a session it previously reported), that session's key is released immediately, the same as a Codex session leaving the catalog.

Pressing an assigned herdr session's key runs `herdr agent focus <pane_id>` (200 ms timeout, best-effort -- a timeout or failure is logged but does not block the rest of navigation) and then activates Ghostty (`com.mitchellh.ghostty`) via `NSWorkspace`, since herdr itself has no window-foregrounding capability. If Ghostty isn't installed, this is logged and the key press is otherwise a no-op.

### Locating the herdr binary

The daemon resolves `herdr` in this order: `--herdr-bin PATH` (on `run`) > `HERDR_BIN` environment variable > `/opt/homebrew/bin/herdr` > `/usr/local/bin/herdr` > `~/.cargo/bin/herdr`. If none resolve to an executable, herdr support is silently disabled (a single INFO log line at startup) and the daemon otherwise behaves exactly as it did before M2.

## Runtime paths and options

- Socket: `/tmp/keychron-c100-status-<uid>.sock`; override with `--socket PATH` on both daemon and clients.
- Grabber socket: `/var/run/keychron-c100-grabber-<uid>.sock`; override with `--grabber-socket PATH` for diagnostics.
- Log: `/tmp/keychron-c100-status-<uid>.log`; override with `--log-file PATH` on `run`, `logs`, and `log-path`.
- Device: pass `--location 0x110000` to `run` when selecting among multiple C100 devices.
- Input ownership: startup fails rather than leaving normal C100 typing enabled when exclusive capture cannot be obtained.

`apply <status>` bypasses the daemon and writes directly to HID. Use it only for troubleshooting while the daemon and Keychron Launcher are stopped.

## Uninstall

Stop the foreground daemon, then remove the root helper, LaunchDaemon, and helper log:

```sh
sudo .build/release/c100-status uninstall-helper
```

The user-owned runtime socket, status log, and local Codex data are not removed. You can delete the repository separately after uninstalling the helper.

## Current limitation

`clear` turns all volatile per-key colors off. The daemon does not yet snapshot and restore the user's previous RGB mode. Unplugging/reconnecting the keyboard restores its saved configuration because this tool never sends `SaveLedConf`.

Existing-task bootstrap reads Codex's local SQLite task catalog, which is an internal on-disk interface rather than a documented public API. Failure is non-fatal and is reported in the daemon log; lifecycle hooks continue to work independently.

## License and protocol references

The original Swift source in this repository is licensed under the MIT License. See [LICENSE](LICENSE). Interoperability notes and third-party acknowledgements are in [NOTICE.md](NOTICE.md).
