# Configuration

Run `c100-status config init` to create a starting file and `c100-status config show` to inspect effective settings. `init --dry-run` prints the example without writing; init never overwrites an existing file.

File selection: `--config PATH` > `C100_STATUS_CONFIG` > `$XDG_CONFIG_HOME/c100-status/config.json` (or `~/.config/c100-status/config.json`). An absent default file uses defaults; an explicitly selected missing file is an error.

Setting precedence: explicit CLI flag > JSON field > supported environment variable > default. Paths accept `~`; relative JSON paths resolve against the configuration file's directory, while CLI/environment paths resolve against the working directory. Environment variable interpolation inside JSON strings is not supported. Unknown keys, null values, invalid types and unsupported versions fail validation. The file must be regular JSON of at most 64 KiB.

| JSON field | Default / meaning |
| --- | --- |
| `schemaVersion` | `1` |
| `layoutPath` | `layout.json` next to the selected config; editable from the companion app |
| `backend` | `companion` (the only supported backend); custom firmware is required |
| `locationID` | `"auto"`; optionally a quoted decimal or `0x` USB location ID |
| `claudeConfigDirs` | `[CLAUDE_CONFIG_DIR]`, otherwise `["~/.claude"]`; replaces the entire profile list; `[]` disables terminal catalog scanning and default Claude hook installation |
| `claudeDesktopSessionsDir` | `~/Library/Application Support/Claude/claude-code-sessions` |
| `claudeDesktopConfigDir` | `~/.claude`; Desktop transcript/profile root |
| `codexHome` | `CODEX_HOME`, otherwise `~/.codex`; also used for rollout discovery |
| `codexCatalogDatabase` | `<codexHome>/sqlite/codex-dev.db` |
| `codexStateDatabase` | `<codexHome>/state_5.sqlite` |
| `codexSidebarState` | `<codexHome>/.codex-global-state.json` |
| `herdrBinary` | `HERDR_BIN`, then absolute `PATH` directories, Homebrew locations, `~/.cargo/bin/herdr` |
| `herdrRowGrouping` | `workspace` (one row per herdr workspace, at its display number); `repository` folds linked-worktree workspaces into their parent checkout's row, mirroring herdr's sidebar tree |
| `defaultLayer` | `codex`; alternatives: `claude-herdr`, `claude-terminal`, `claude-desktop`; saved layer selection wins |
| `socketPath` | `/tmp/keychron-c100-status-<uid>.sock` |
| `logPath` | `/tmp/keychron-c100-status-<uid>.log` |

Use `HERDR_SOCKET_PATH` to override the herdr service socket.

An explicitly configured missing herdr executable disables that adapter rather than selecting another installation. Database path overrides select locations, not alternate database schemas. The adapters still target Codex, Claude Desktop, herdr and Ghostty on macOS.

## LaunchAgent and hooks

`c100-status install-agent --config PATH` retains the absolute file reference in the LaunchAgent. Explicit CLI overrides are also retained. The installer forwards only `PATH`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `HERDR_BIN`, `HERDR_SOCKET_PATH` and `XDG_CONFIG_HOME` from its environment. Edit the file and rerun the same install command to restart and apply changes; configuration is not hot-reloaded. `--dry-run` previews the generated plist.

`c100-status install-claude-hooks --config PATH --dry-run` previews hooks for exactly `claudeConfigDirs`. Remove `--dry-run` to install. Each command retains the configuration reference and its profile directory, plus an explicit `--socket` override if supplied. Runtime `CLAUDE_CONFIG_DIR` still identifies the invoking profile. A malformed configuration in a hook is diagnosed on stderr and the hook exits successfully so the agent is not blocked.

Manually installed hook commands, including Codex hooks, should pass the same `--config PATH` when it is outside the default location. Configuration changes do not rewrite existing hooks; rerun the Claude hook installer when needed. A separate Desktop profile must also be listed in `claudeConfigDirs` to install its hooks.

## Profile configuration

Register each desired profile explicitly in `claudeConfigDirs`. For example:

```json
{
  "schemaVersion": 1,
  "backend": "companion",
  "locationID": "auto",
  "claudeConfigDirs": ["~/.claude", "~/profiles/claude-work"],
  "codexHome": "~/agent-data/codex",
  "defaultLayer": "codex"
}
```

## Service settings in Companion

The settings window has separate Layout and Services tabs. Services stores
`enabledServices` and `defaultLayer` in config.json, independent of switch parts.
Select at least one service. With one enabled service no switch part is needed;
with several, the menu bar can also switch services. Disabled services' physical
switch keys stay dark and do nothing. Existing configurations without
`enabledServices` retain their layout selection until Services is saved; without
any switch part they fall back to `defaultLayer`.

The Services tab also edits Claude CLI's multiple `claudeConfigDirs` (one per line),
Codex's home and optional database paths, Claude Desktop directories, and herdr's
binary path. Codex and Claude Desktop currently each have one configured home;
multiple concurrent profile directories are supported for Claude CLI. Saving
restarts the daemon and preserves the layout. It does not install profile hooks.
If restart fails, the UI distinguishes saved settings from pending activation.
