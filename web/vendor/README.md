# WebDFU

`dfu.js` and `dfuse.js` are vendored from https://github.com/devanlai/webdfu
commit `56d5d1d961587aca381a1ce97acbc8ff5d807acd` under the ISC license
in `LICENSE.webdfu`. No CDN or runtime third-party scripts are used.

Our adapter uses the low-level DfuSe API instead of `do_download`, because
readback must finish before manifestation. It bounds state polling and rejects
unexpected memory layouts. Upstream source files are otherwise unchanged.
