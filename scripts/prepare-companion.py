#!/usr/bin/env python3
"""Install the keymap and two guarded hooks into an isolated, pinned QMK checkout."""
from pathlib import Path
import shutil
import subprocess
import sys

REVISION = '9ada9b7baecb9591c469b9b068146ac5891a480a'
root = Path(sys.argv[1]).resolve()
if subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() != REVISION:
    raise SystemExit('Refusing an unverified QMK revision; use ' + REVISION)
patches = [
    ('keyboards/keychron/common/keychron_raw_hid.c',
     'bool kc_raw_hid_rx(uint8_t src, uint8_t *data, uint8_t length) {',
     '\n#ifdef C100_COMPANION_ENABLE\n    extern bool c100_companion_receive(uint8_t *, uint8_t);\n    if (c100_companion_receive(data, length)) return true;\n#endif\n'),
    ('keyboards/keychron/common/keychron_task.c',
     'bool process_record_keychron(uint16_t keycode, keyrecord_t *record) {',
     '\n#ifdef C100_COMPANION_ENABLE\n    // Input comes from debounced matrix snapshots, never keyboard reports.\n    return false;\n#endif\n'),
]
# Validate every hook before changing any file.
for relative, anchor, addition in patches:
    text = (root / relative).read_text()
    if text.count(anchor) != 1:
        raise SystemExit('Unexpected source: ' + relative)
    if 'C100_COMPANION_ENABLE' in text and anchor + addition not in text:
        raise SystemExit('Conflicting patch: ' + relative)
for relative, anchor, addition in patches:
    path = root / relative
    text = path.read_text()
    if anchor + addition not in text:
        path.write_text(text.replace(anchor, anchor + addition))
source = Path(__file__).resolve().parents[1] / 'firmware/companion'
shutil.copytree(source, root / 'keyboards/keychron/c100_8k/keymaps/companion', dirs_exist_ok=True)
print('Prepared C100 companion keymap at ' + str(root))
