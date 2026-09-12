# C100 Companion (macOS 13+)

Build a local, ad-hoc signed app with `scripts/build-app.sh`, then copy `.build/C100 Companion.app` into `~/Applications` and open it. A keyboard icon and **C100** appear in the menu bar. `c100-status app` also launches the menu directly during development.

The menu shows the daemon's connection state and selected firmware backend, offers four source layers, and controls LED brightness (10–200% of the existing palette). Brightness requires companion firmware; values above 100% saturate at the LED's maximum. Selection checkmarks follow physical layer-key changes. Closing the menu app leaves the daemon running.

**Restart daemon** installs/reloads the per-user default LaunchAgent using the app's bundled executable and the selected configuration. This also starts an uninstalled daemon. Keep the installed app in place once its executable is registered. The first revision manages the default `com.kotainaba.c100-status.run` label; custom LaunchAgent labels remain CLI-managed.

The default configuration is shared with the CLI. **Choose configuration file** selects another validated JSON file for this app; restarting the daemon applies it to the service too. **Open configuration file** opens it in the default editor (or creates a default starting file when none exists). Logs open in the default viewer. The menu app's configuration selection is remembered in its preferences.

Brightness survives daemon restarts in `<socketPath>.display.json`, alongside the existing temporary runtime state. A system cleanup of `/tmp` resets it to 100%. Layer selection follows the existing layer state file. Login launch of the menu app can be configured in macOS Login Items; the daemon's LaunchAgent already starts at login.

The UI runs CLI requests off its main thread, with a five-second timeout. It never opens HID itself. If the daemon is stopped or waiting for hardware before its socket is ready, the menu reports that it is waiting for a response. Stock firmware brightness control is disabled.

## CLI controls

```sh
c100-status inspect                       # JSON: connected, backend, layer, brightness
c100-status layer claude-terminal
c100-status brightness 100                 # 10...200; companion firmware only
```

Use `scroll up|down|left|right` to operate the scroll window from the CLI. The physical utility keys are described in [scrolling.md](scrolling.md).

All commands accept `--config PATH` and use the configured daemon socket. The app is a local build, not a notarized distribution.

## Validation (2026-09-13)

Release build and all existing self-tests passed. The report fixture was updated to the current idle-white value of 96. The local app bundle passed code-signature verification. On the connected C100, the installed executable switched all four layers, changed brightness to 50/150/100%, rejected 201%, and retained 75% through LaunchAgent restart. Tests restored Codex and 100%. The menu process and bundled daemon were both running. Automated native-menu inspection was unavailable because the computer-use service timed out; menu clicks still require a visual smoke check.
