# Physical validation — 2026-09-12 (Asia/Tokyo)

C100 8K `3434:042c`, this Mac's location `0x02110000`; DFU `2e3c:df11`
at USB path `2-1.1`. The main README's other-machine location was preserved.

- Read and saved the original **262,144-byte flash** before modification.
- Flashed companion firmware, then read back **60,488 bytes**, exactly matching
  the binary's firmware payload (excluding its 16-byte DFU suffix).
- Normal USB enumeration and companion protocol v1 negotiation succeeded.
- The initial 90-second test recorded **650 presses and 650 releases**, no
  held keys remaining, across 97 distinct keys. A follow-up recorded keys
  85, 94 and 95, covering **all 100 physical positions** in total.
- The user confirmed all four corner colors, adjacent dim/bright white LEDs,
  all other LEDs off, and no normal text input from any of the 100 keys.
- One complete 100-key staged frame + commit round trip took **10 ms**.
  This is a host-side sample, not a worst-case input or optical LED latency.
- After **3.3 seconds without host traffic**, the device reported that its
  watchdog had expired. No synthetic watchdog state was injected.
- The real daemon ran as **uid 501**, with firmware input capture and matrix
  polling disabled. No root grabber was installed or leased.
- Physical presses switched all four source layers. Task navigation from keys
  0, 10 and 20 returned `opened=true`; the user completed the navigation check.
- The foreground test daemon shut down normally. The per-user LaunchAgent was
  installed with `run --companion --location 0x02110000`, started successfully,
  and answered `ping` using the normal daemon socket. A concurrent
  `companion-watch` was rejected by the per-device lock before taking control.

Builds of both the dedicated and standard-keymap firmware succeeded. Swift
Release build, existing self-tests, firmware command-handler tests and the
LaunchAgent dry-run check passed. The standard-keymap binary is a separate
source build; the original-device backup is the exact readout of this device.

Local evidence is under ignored `firmware/build/`: `manifest.json`,
`physical-test.log`, `daemon-test.log`, `flash.log`, `readback.log`,
`original-device-flash.bin`, and both built firmware images. The backup and
logs are user-readable only. These artifacts are not committed to the repo.

The standalone DFU leave request returned a final get-status error as the
device disconnected; successful USB re-enumeration and the new protocol
handshake confirmed the firmware booted. The flash download and readback had
already completed successfully.

Not tested in this run: physical unplug/replug while the daemon is active,
sleep/wake, other Macs/OS versions, and a fresh macOS privacy-permission profile.
No new lifecycle hooks were installed as part of this firmware validation.
