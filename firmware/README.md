# C100 companion firmware (experimental)

A dedicated task controller for the **Keychron C100 8K, VID 3434 / PID 042c**.
Physical switches do not emit ordinary keyboard input automatically. With the
keyboard-output extension, the daemon can authorize a mapped shortcut after a
physical press; without the daemon the switches remain silent. The host receives debounced physical matrix snapshots over Raw HID.
The existing stock-firmware daemon remains the default; select this backend
explicitly with `run --companion` after flashing. When moving this flashed
keyboard to another machine, update that machine's daemon and enable
`--companion` there too; its old stock-backend setup is not the companion mode.

See [physical validation results](VALIDATION.md) for the completed device test.

## Build from pinned source

The source reviewed here is Keychron `2025q3`, commit
`9ada9b7baecb9591c469b9b068146ac5891a480a`.
The build image used is
`ghcr.io/qmk/qmk_cli@sha256:b7d7fa8fb4432b569931de5ad59098cb788f440ed61a62c5126746b71aee0f4a`.

Use an isolated checkout. From this repository:

```sh
git clone --branch 2025q3 --single-branch https://github.com/Keychron/qmk_firmware.git /tmp/c100-qmk
git -C /tmp/c100-qmk checkout 9ada9b7baecb9591c469b9b068146ac5891a480a
git -C /tmp/c100-qmk submodule update --init lib/chibios lib/chibios-contrib lib/printf lib/lufa
python3 scripts/prepare-companion.py /tmp/c100-qmk
docker run --rm --network none -e SKIP_GIT=yes -e QMK_USERSPACE= \
  -v /tmp/c100-qmk:/qmk_firmware -w /qmk_firmware \
  ghcr.io/qmk/qmk_cli@sha256:b7d7fa8fb4432b569931de5ad59098cb788f440ed61a62c5126746b71aee0f4a \
  make keychron/c100_8k:companion -j4
```

Build `keychron/c100_8k:keychron` with the same command for the standard-keymap
recovery image. This is a build of published Keychron source, **not a backup of
your device's original binary or saved settings**. Build timestamps can change
binary hashes even with the same source and compiler.

The preparation script adds two hooks, both conditional on
`C100_COMPANION_ENABLE`, and copies our keymap. One intercepts the private Raw
HID commands before Keychron/VIA dispatch; the other suppresses key processing
before Keychron shortcuts, factory-reset combinations, or normal keyboard output.
The standard `keychron` build does not define that flag.

## Protocol v1

All packets are 32 bytes, on the existing usage page `FF60`, usage `61`.
Bytes 0–3 are `C9 43 31 30`, byte 4 is version `1`, byte 5 is command,
byte 6 is a request sequence, byte 7 is zero in requests / status in replies.
Replies use `command | 80` and echo the request sequence. Payload starts at byte 8.

| Command | Meaning |
| --- | --- |
| `01` | Read-only capabilities: `10, 10, 7, 3` (rows, columns, capability bits, watchdog seconds). Does not activate the controller. |
| `02` | Activate/renew the watchdog and return a 13-byte bitmap. Byte 21 reports whether control was active before this request. |
| `03` | Stage HSV colors: start index, count 1–7, then H/S/V triples. A chunk at index 0 begins a new frame. |
| `04` | Commit only if all 100 colors have been staged. Partial frames never change the displayed frame. |
| `05` | Release control, clear display and staging buffers. |
| `06` | Keyboard extension: configure RAM slot (index, USB modifier byte, keyboard usage). Usage zero clears a slot. |
| `07` | Keyboard extension: authorize one tap of a configured slot after a fresh physical press. |
| `08` | Keyboard extension: release held output, clear queued taps and RAM assignments. |
| `40` | Unsolicited full matrix bitmap on change; byte 6 is an event counter. |

Status values: `0` success, `1` malformed/unsupported, `2` inactive,
`3` incomplete frame, `4` keyboard queue full, `5` no fresh physical press. Bitmap index is `row * 10 + column`; bit zero is the
low bit of each byte. Unused high bits of the last bitmap byte are zero.
HSV uses the existing host's 0–255 scale. The renderer maps physical positions
through QMK's LED map and respects each key's value, including zero.

The host renews every 750ms, with periodic snapshots to reconcile held state.
Each changed-state packet is queued separately, so a press and release between
host loop iterations are not collapsed. The bounded host queue fails closed on
overflow. Events and heartbeat snapshots enter the queue in callback order.
Startup-held keys are seeded without navigating them. A lost watchdog causes the
host to exit so a restart can repaint the entire display; it does not silently
keep a stale frame cache. A per-user, per-location lock prevents this backend's
watcher and daemon from controlling the same device simultaneously.

The optional keyboard-output extension advertises version `1` in capability
reply byte 12; older firmware returns zero and the host retains its software
shortcut path. Slot configuration is lazy on the first press or a changed
shortcut, and cached until a revoke/reconnect. The host resolves current Codex
bindings, verifies Codex is foreground, configures the slot, rechecks foreground,
and authorizes that slot. Physical presses alone never send ordinary keys.
Each authorization consumes one physical press ticket no older than 500 ms;
replayed commands cannot mint new tickets. The queue is bounded to eight taps,
with 20 ms down and at least 5 ms release between taps. Overflow is reported.
Leaving Codex's foreground cancels output at the next daemon input poll; as with
ordinary keyboards, focus changes at the instant of delivery can race input.
Release, watchdog expiry and USB suspend cancel held output and queued taps,
forget mappings and invalidate tickets. No EEPROM writes are used. New mappings
are re-established by the daemon as needed. This path needs no macOS synthetic
keyboard/Accessibility permission; it still needs the existing USB connection.

After 3 seconds without a heartbeat or valid color/commit operation, the device
blacks out. It continues suppressing keyboard input. Suspend follows QMK's RGB
suspend behavior. Keychron Launcher should be closed: its RGB commands can
interfere with the dedicated renderer. This is not a general keyboard mode.

## Flash and test

Flashing replaces the device firmware. Enter its ROM DFU mode by disconnecting
USB, holding the top-left K00 key, and reconnecting. Verify the device before
using a compatible AT32 DFU tool; no flashing is performed by the build script.
To recover, enter the same bootloader and flash the standard-keymap image.
Do not use the C100 images on any other model.

After flashing, use `list` to get **this machine's** location (the location in
the main README is from a different machine):

```sh
.build/release/c100-status list
.build/release/c100-status companion-info --location 0x02110000
.build/release/c100-status companion-watch 20 --location 0x02110000
.build/release/c100-status run --companion --location 0x02110000
```

`companion-test 90 --location ...` displays a corner/brightness pattern, records
input, and deliberately withholds host traffic for 3.3 seconds to check watchdog
expiry. It clears the display on normal exit. Stop the daemon before running a
watcher or diagnostic against the same device.

`companion-info` is a read-only protocol check. `companion-watch` temporarily
activates the controller, prints presses/releases, and clears LEDs on exit.
`run --companion` requires successful capability negotiation and does not acquire
the root grabber lease. All other task collection, hooks, layout, and navigation
continue in the logged-in user's daemon. Missing or stock firmware fails the
handshake instead of falling back to input without suppression.

After foreground validation, login startup can be configured using
`install-agent --companion --location ...` (preview with `--dry-run`). Reinstall
without `--companion` when returning to stock firmware. This Mac successfully ran the vendor HID path as a per-user LaunchAgent without
a root grabber. A fresh macOS privacy-permission profile has not been tested.

Check corners, center keys, quick taps, simultaneous holds, release, per-key
brightness and black, source-layer switching, task navigation, unplug/replug,
normal shutdown and crash/watchdog blackout. Firmware flashing and these
physical checks are distinct from the tests below.

## Automated checks

```sh
cc -std=c11 -Wall -Wextra -Werror -DQMK_KEYBOARD_H='"qmk_stub.h"' \
  -Ifirmware/tests firmware/tests/companion_test.c -o /tmp/c100-firmware-test
/tmp/c100-firmware-test
swift build -c release
.build/release/c100-status self-test
```

The C test compiles the actual firmware handler with stubbed hardware APIs. It
checks packet rejection, frame bounds/completeness, atomic commit, true zero
value, input snapshots, unchanged-state suppression, release, watchdog expiry,
and timer wrap. It cannot verify USB transport, actual LEDs, or key suppression
through the complete QMK event pipeline; those require the target build and
physical checks.

## License

`companion/keymap.c` and `companion/rules.mk` are GPL-2.0-or-later. The compiled
firmware also contains QMK/Keychron code under its respective licenses. The host
Swift code remains under the repository's MIT license. The pinned source,
preparation script and keymap identify the corresponding firmware source;
retain those sources and licenses when redistributing firmware binaries.
