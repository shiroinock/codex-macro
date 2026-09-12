# Notices and protocol references

This repository contains an independent Swift implementation for interoperating with a Keychron C100 8K and local Codex Desktop state. It does not bundle third-party source code or binary artifacts from Keychron, QMK, or OpenAI. The required `firmware/companion` keymap is separately licensed GPL-2.0-or-later and is built against a pinned external QMK checkout; see `firmware/README.md`.

The HID protocol behavior used here was derived from observation of the author's own device and publicly available interoperability references, including:

- [Keychron C100 8K product information](https://www.keychron.com/products/keychron-c100-8k-giant-custom-macro-pad)
- [Keychron's QMK firmware fork](https://github.com/Keychron/qmk_firmware)
- [QMK Firmware](https://github.com/qmk/qmk_firmware)

QMK Firmware is separately licensed under the GNU General Public License version 2. Consult its repository for its license and copyright notices. The Web Flasher distribution includes a built firmware image and its corresponding QMK source archive with licenses. The source checkout is fetched during the Pages build.

Keychron, QMK, OpenAI, and Codex names and marks belong to their respective owners. Their mention describes compatibility only and does not imply affiliation or endorsement.

The Web Flasher includes WebDFU JavaScript under the ISC license. See [the vendored license](web/vendor/LICENSE.webdfu) and [source revision](web/vendor/README.md).
