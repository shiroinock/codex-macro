# C100 Web Flasher

Static GitHub Pages app, initially targeting Chrome on macOS. No backend,
analytics, CDN dependencies, or backup uploads. The WebUSB picker requires a
physical user gesture. AT32 DFU IDs are shared across models; the user must
confirm the model, then the adapter requires alt 0, DfuSe 1.1a, read/write
capabilities, and a contiguous 256 KiB readable/erasable/writable flash at
0x08000000. Other layouts fail closed.

A connection-scoped backup must be downloaded and reselected byte-for-byte
before either install or restore. Disconnect clears that authorization. Released
images require SHA-256 and DFU suffix CRC verification. Write and readback are
separate from manifestation; only successful comparison enables restart. A
restart request is not proof of successful normal USB enumeration.

## Development

Run `node --test web/tests/*.test.mjs` from the repository root. Build the pinned
firmware as described in `firmware/README.md`, then stage it using:

```
python3 scripts/package-web-firmware.py /path/to/keychron_c100_8k_companion.bin web
python3 -m http.server 8765 --bind 127.0.0.1 --directory web
```

Use localhost or HTTPS. With Playwright and Chrome installed, run
`node web/tests/browser-smoke.cjs` (or set `NODE_PATH` to the Playwright package
parent). This test replaces only the USB adapter in its own browser session; it
never accesses a physical device. It covers download/reselection, wrong backup
rejection, write/readback, restore and restart reset, mobile layout, and JS errors.
Its synthetic backup and screenshots go to `/private/tmp`.

## Publication and verification boundary

`.github/workflows/pages.yml` builds the pinned QMK source in the pinned container,
stages only the resulting binary and manifest, and provides a corresponding
source archive including libraries and licenses. Device backups under
`firmware/build` are never publication inputs. Enable Pages with GitHub Actions
as the build source. Workflow dispatch can republish; relevant main pushes also
trigger it.

Automated tests and simulated browser flow pass. Actual WebUSB on the C100 AT32
bootloader, disconnect recovery during erase/write, and hardware restore are
still unverified. Keep the experimental notice until those checks are recorded.
Do not equate prior dfu-util validation with browser validation.
