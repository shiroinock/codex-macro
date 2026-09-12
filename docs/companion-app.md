# C100 Companion (macOS 13+)

Build a local, ad-hoc signed app with `scripts/build-app.sh`, then copy `.build/C100 Companion.app` into `~/Applications` and open it. A keyboard icon and **C100** appear in the menu bar. `c100-status app` also launches the menu directly during development.

The menu shows the daemon's connection state and selected firmware backend, offers four source layers, and controls LED brightness (10–200% of the existing palette). Brightness requires companion firmware; values above 100% saturate at the LED's maximum. Selection checkmarks follow physical layer-key changes. Closing the menu app leaves the daemon running.

**Stop daemon** unloads the default per-user LaunchAgent without deleting its plist or settings. The app stays open and shows a stopped status; **Resume daemon** starts it again. Saving service settings while paused stores them for the next resume. The retained LaunchAgent starts at the next login. Manually launched daemons and custom labels remain CLI-managed.

**Restart daemon** installs/reloads the per-user default LaunchAgent using the app's bundled executable and the selected configuration. This also starts an uninstalled daemon. Keep the installed app in place once its executable is registered. The menu manages the default `com.kotainaba.c100-status.run` label; custom LaunchAgent labels remain CLI-managed.

The default configuration is shared with the CLI. **Choose configuration file** selects another validated JSON file for this app; restarting the daemon applies it to the service too. **Open configuration file** opens it in the default editor (or creates a default starting file when none exists). Logs open in the default viewer. The menu app's configuration selection is remembered in its preferences.

Brightness survives daemon restarts in `<socketPath>.display.json`, alongside the existing temporary runtime state. A system cleanup of `/tmp` resets it to 100%. Layer selection follows the existing layer state file. Login launch of the menu app can be configured in macOS Login Items; the daemon's LaunchAgent already starts at login.

The UI runs CLI requests off its main thread, with a five-second timeout. It never opens HID itself. If the daemon is stopped or waiting for hardware before its socket is ready, the menu reports that it is waiting for a response. A deliberate menu stop is displayed separately from a connection failure.

## CLI controls

```sh
c100-status stop-agent                    # stop without removing login settings
c100-status install-agent                 # resume / restart
c100-status inspect                       # JSON: connected, backend, layer, brightness
c100-status layer claude-terminal
c100-status brightness 100                 # 10...200; companion firmware only
```

Use `scroll up|down|left|right` to operate the scroll window from the CLI. The physical utility keys are described in [scrolling.md](scrolling.md).

All commands accept `--config PATH` and use the configured daemon socket. The app is a local build, not a notarized distribution.

## Settings window

The menu opens **設定（レイアウト・サービス）…**. See [Layout editor](layout-editor.md) for key assignments, task areas, action mappings, and service settings.

## Verification

The release build and self-tests pass. The stop command unloads the LaunchAgent without changing its plist, and resuming restores the device connection. Menu updates preserve saved settings. Hardware validation is summarized in [firmware validation](../firmware/VALIDATION.md).
