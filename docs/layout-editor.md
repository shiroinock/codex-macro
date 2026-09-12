# Layout, actions, and services

Open **C100 → 設定（レイアウト・サービス）…** in the menu bar. The settings window has three tabs.

## Layout

Click a key or a placed part to edit it in the right-hand panel. Choose the function type, search for an action, and adjust position, dimensions, direction, or service destinations. Dragging a part moves it on the preview. **保存して反映** validates and applies the layout without restarting the daemon. Closing a dirty editor asks whether to discard the draft.

Parts use the same 10 × 10 physical grid:

- **Task area:** one rectangle, 1–10 keys wide/high. Move, resize, or transpose projects and tasks. Offscreen sessions retain their status. Key input and LEDs use the same projection.
- **Scroll:** one key per arrow. Moves the entire task viewport in physical directions, including when transposed. Holding repeats after 350 ms, then every 80 ms.
- **Service switch:** one rectangle containing the selected service destinations in row order. It determines which service-selection keys appear. Enabled providers are configured in the Services tab.
- **Desktop action:** one semantic operation per key. Search by name or command ID. Multiple keys may have the same action.

Parts cannot overlap or extend beyond the keyboard. A task area must be shrunk before assigning a separate button inside its rectangle. The default layout uses an 8-row × 10-column task area and two utility rows. A single-service setup can omit the switch part; an actions-only layout can omit the task area.

## Actions

The foreground application and enabled services determine the shortcut sent for an assigned action. The Actions tab lists outgoing shortcuts and support status for selected services. It distinguishes Codex settings, bundled Claude Desktop Code-tab bindings, and any saved per-key overrides. Assigned but unavailable actions remain visible for diagnosis. Use refresh after changing shortcuts outside Companion.

Codex action candidates and labels are read from command metadata inside the installed app's `app.asar`, located through bundle ID `com.openai.codex`. If metadata cannot be read, a built-in command set is used. Current mappings are read from `<codexHome>/keybindings.json`. Usable configured shortcuts take priority; commands without one use a dedicated unused F13–F20/modifier alias. Registration preserves existing settings and keeps the first original file as `keybindings.json.c100-backup`. Removing a button does not remove its registered alias.

The C100 sends the resolved shortcut as USB keyboard input. No Accessibility permission is needed with the distributed firmware. The daemon checks the foreground app before authorizing a physical press and cancels pending output when it observes a different foreground app. `inspect` reports `actionTransport: keyboard-hid`. Successful sending does not prove that the target app executed a context-dependent action.

Claude Desktop uses bundled bindings for its Code tab. Automatic import of Claude Desktop settings and keyboard delivery of its archive action are not implemented. Unsupported routes send no keys. Claude CLI and herdr provide task tracking and navigation, but have no keyboard action routes. OS-global commands, multi-stroke chords, analog controls, and Micro-specific gestures are not emulated.

## Services

Select enabled providers, the initial service, and profile/data paths independently of the layout. Only enabled services contribute action candidates or receive action output. Saving a layout does not register Codex bindings if Codex is disabled. Service draft edits immediately update the editor's candidates; saving applies them to the daemon.

When the daemon has been stopped from the menu, saving service settings keeps it stopped. The saved settings take effect on resume.

## Storage and CLI

`layoutPath` selects the layout file; the default is `layout.json` next to the selected configuration. Layouts use schema version 1 and stable part IDs. Task catalogs and hook state are separate.

```sh
c100-status layout show
c100-status layout actions
c100-status layout shortcuts
c100-status layout apply my-layout.json
c100-status layout reset
c100-status layout preview /tmp/c100-layout.png
```

`--config PATH` selects the configuration. `show/apply/reset` communicate with the daemon; `actions` reads the command catalog, `shortcuts` resolves outgoing mappings, and `preview` renders the saved layout without sending actions. Live layout editing requires a running daemon.
