# Current validation status

Target: Keychron C100 8K (`3434:042c`), AT32 DFU (`2e3c:df11`), on the tested Mac. Last updated 2026-09-13.

## Verified

- Dedicated firmware and host release builds, firmware handler tests, and host self-tests pass.
- All 100 physical positions were exercised. The user confirmed corner colors, adjacent dim/bright white keys, black on unassigned keys, and suppression of ordinary text input.
- Press/release, quick taps, simultaneous holds, source switching, and task navigation were checked on the device.
- Watchdog expiry was confirmed after 3.3 seconds without host traffic. The firmware clears LEDs and continues suppressing ordinary input.
- The per-user daemon connects with `backend=companion` and `actionTransport=keyboard-hid`; Accessibility is not required for this transport.
- The device lock rejects a competing companion watcher.
- Stopping the LaunchAgent leaves its configuration intact and prevents immediate automatic restart. Resuming reconnects the C100.

## Web Flasher

The user confirmed backup saving, writing, readback comparison, restart, and Companion operation through the published site.

Restoration was also tested using this device's original 262,144-byte stock backup. Before the test, the agent verified its SHA-256 against the saved manifest:

```
453bed79c89de0622cdd9821efba28eec8c0eb6fca84d38ab1b11740f1e2a1c6
```

The user confirmed restoration, readback comparison, restart, and ordinary text input. The user then reinstalled companion firmware through the site and confirmed comparison and restart. The agent checked the running daemon reported `connected=true`, `backend=companion`, `actionTransport=keyboard-hid`, and an empty `actionError`.

Physical browser steps are user-reported. The agent directly checked the backup hash and final daemon state; no browser USB trace was collected. Automated tests also exercise backup selection, rejection of mismatched files, write/readback failure handling, restoration, and restart state using a simulated device.

## Not verified

- Recovery from interruption during erase or writing.
- Restoration using the separately source-built standard-keymap image.
- Other machines, browser/OS versions, and sleep/wake behavior.
- Physical unplug or suspend during a keyboard output pulse.
- Execution of every context-dependent action in each supported application.

## Local evidence

Device backups, manifests, and physical-test logs are kept under ignored `firmware/build/`; they are not published. The original-device backup is the exact device readout. A backup made while companion firmware is installed preserves that state, not stock firmware.
