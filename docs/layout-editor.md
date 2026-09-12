# Layout editor and Codex actions

Open **C100 → レイアウトを編集…** in the menu bar. Click a keyboard key to choose its function type, then choose an action, direction, service set, or task area. Existing buttons can be reassigned in place. The Codex action chooser has an autofocus search field and a scrolling result list with Japanese names and command IDs; words narrow results together. Select a part in the list to inspect its position and dimensions, or drag it on the keyboard to move it. **保存して反映** validates, saves, and applies the layout without restarting the daemon. Closing a dirty editor asks whether to discard the draft.

Parts share the same 10 × 10 physical grid:

- **Task area:** one rectangle, 1–10 keys wide/high. Move, resize, or transpose projects and tasks. Offscreen sessions retain status, and key presses resolve through the same projection used for LEDs.
- **Scroll:** one key per arrow, placed anywhere. Moves the whole task viewport in physical directions, including when transposed. Holds repeat after 350 ms at 80 ms intervals.
- **Service switch:** one rectangular part containing checkboxes for Codex, herdr, Claude CLI, and Claude Desktop. Selected services occupy keys from the top left in row order. Turning a service off stops task discovery and hooks for that source; the group keeps its rectangle until resized. herdr background polling also pauses (an already-running request may finish). Action buttons are independent of task-source discovery.
- **Codex action:** choose an operation by name or command ID. The picker searches the installed desktop application's app-scoped, shortcut-configurable commands and Japanese titles. Existing keyboard shortcuts are retained; a separate unused F13–F20/modifier combination is added for each chosen command.

The same Codex operation can be assigned to multiple buttons; they share one command alias.

The Services settings tab controls enabled providers independently of layout. The switch part only selects which service destinations appear on keys. Other parts are removed with Delete, not enabled/disabled. Parts may not overlap or extend beyond the keyboard. A key inside the task area first offers area editing so that assigning a button cannot silently delete the entire area. The default layout preserves the previous 8 × 10 task area and bottom utility rows. Deleting the switch part leaves the configured service available; a single-service setup needs no switch keys. Remove the task area for an actions-only controller. Legacy default service buttons migrate to one group while preserving their selected services and the group’s footprint.

## Codex compatibility

The adapter reads command metadata from the installed app bundle located by `com.openai.codex`, without changing or executing its code. The installed version's command IDs, macOS defaults, and Japanese names feed the editor. `layout actions` lists the imported catalog. If the adapter cannot recognize a version, it falls back to a smaller verified set. This is a version-sensitive adapter, not a public Codex action API.

The daemon appends aliases to `<codexHome>/keybindings.json` and keeps the first original file as `keybindings.json.c100-backup`. It preserves custom shortcuts, disabled defaults (without restoring them when adding an alias), and normal defaults for commands without overrides. Aliases are identified by command ID and shortcut, not by the catalog order, so reordering the imported catalog cannot redirect a button to a different operation. Existing conflicting shortcuts are skipped. Removed buttons leave their Codex aliases in place; nothing silently resets the user's keymap.

Actions are sent only while Codex / ChatGPT is frontmost, and require **C100 Companion** in macOS **Privacy & Security → Accessibility**. Failures appear in the C100 menu and daemon log. Commands operate on the current Codex context; Codex decides whether the command is available there. Approval and submit have separate dedicated command bindings, avoiding ambiguous Enter/Escape emulation. No action is executed just by editing or saving its part.

OS-global shortcuts and non-configurable commands are excluded because their separate controllers cannot preserve the user's existing global binding by adding an app alias. Micro-only gestures (push-to-talk/double-tap latch, analog stick, encoder) and arbitrary skill invocation are not emulated; the app's configurable voice-input and voice-chat commands are available as ordinary buttons.

## Storage and CLI

`config.json` optionally accepts `layoutPath`. By default this is `layout.json` next to the selected config file. Layouts use schema version 1 and stable part IDs. Task/project catalogs and hook state are not stored in the layout.

```sh
c100-status layout show
c100-status layout actions
c100-status layout apply my-layout.json
c100-status layout reset
c100-status layout preview /tmp/c100-layout.png
```

`--config PATH` selects the configuration as for other commands. `layout show/apply/reset` talks to the daemon; `actions` reads app metadata and `preview` renders the saved layout without executing actions. The daemon must be running to edit/apply a live layout.

## Validation

Self-tests cover resized/offset/transposed projection, physical arrow directions, remapped key-repeat isolation, disabled sources, overlaps and bounds, persistence, preservation of user/default shortcuts, backup/idempotence, collision avoidance, and command metadata parsing. Full suite and installed-device checks are recorded in the implementation task; a successful key-event dispatch alone does not prove that Codex executed a context-dependent action.

On this machine (2026-09-13), 118 app-scoped commands were imported with Japanese labels. The full release self-test suite passed using that installed catalog. A connected C100 accepted a relocated 5 × 4 transposed task area, reported matching physical key projections, and correctly hid all tasks when sources were disabled; the default layout was restored. The editor's task-area and action inspectors were rendered and visually checked. The user granted Accessibility and the running daemon confirmed it. A physical button check of two identical Codex action assignments is pending.

After adding a new action alias, Codex may need to refresh its cached shortcut settings. If it does not respond yet, return focus to Codex after about a minute or restart Codex. This adapter does not restart Codex while a task is running.


### Action delivery validation (2026-09-13)

Action buttons prefer an existing configured shortcut that can be represented
as a single modified keystroke, skipping explicit conflicts. Bare Enter/Escape
and multi-stroke chords are not emitted; commands without a usable shortcut
fall back to their dedicated alias. Character keys are resolved using the current
input layout, and function keys include the macOS function-key flag. Events are
posted through the login session only while Codex is foreground. Logs say
`key_posted` with the shortcut and `execution=unconfirmed`; posting is not an ack.

On this machine the user confirmed physical archive success after re-registering
C100 Companion in Accessibility. The corresponding daemon log recorded
`archiveThread`, `CmdOrCtrl+Shift+A`, and the session route, with Accessibility
trusted and no action error. Earlier Control+F13 attempts did not archive even
when trusted; changing only the posting route did not resolve that case.
Other context-dependent actions and dedicated aliases still need physical checks.
The full self-test suite passed on the final build. One earlier suite run failed
an unrelated Claude hook uninstall assertion; the final rerun passed.

The local bundle is ad-hoc signed: its designated requirement contains a code
hash that changes on rebuild. Updating it can invalidate Accessibility permission.
If the daemon reports untrusted despite the Settings switch being on, removing
and re-adding the installed app can restore it. Avoid reinstalling an unchanged
validated build. A stable signing identity remains a separate deployment issue.

The action inspector shows the resolved outgoing shortcut (for example `⌘⇧A`),
its accelerator string, and whether it is an existing Codex shortcut or a C100
alias. `layout shortcuts` exposes the same read-only data. Both the display and
execution use `CodexKeyboardShortcut.forCommand`; viewing the setting never sends
keys. The editor refreshes on load and after saving; use the refresh button after
changing Codex's keybindings externally. Missing mappings and read errors are
shown explicitly rather than presenting defaults as an actual binding.


With keyboard-output firmware, the inspector labels the sender `C100（USB
キーボード）` and hides the Accessibility shortcut. The daemon's `inspect` returns
`actionTransport: keyboard-hid`. Older firmware retains the software sender and
its permission requirement. Shortcut resolution and displayed key are shared
between the transports; the hardware path additionally converts the virtual key
to a USB HID usage and modifiers. It authorizes physical presses only while Codex
is foreground and revokes pending output when it observes another foreground app.
