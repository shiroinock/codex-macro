#!/usr/bin/env python3
"""Stage only the source-built release image; never copy device backups."""
import hashlib, json, pathlib, shutil, subprocess, sys
image = pathlib.Path(sys.argv[1]).resolve()
target = pathlib.Path(sys.argv[2]).resolve() / 'firmware'
data = image.read_bytes()
assert 16 < len(data) <= 262144 + 16 and data[-8:-5] == b'UFD' and data[-5] == 16
# Assert the DFU suffix matches the exact downloaded payload.
import zlib
assert int.from_bytes(data[-4:], 'little') == (zlib.crc32(data[:-4]) ^ 0xffffffff)
target.mkdir(parents=True, exist_ok=True)
shutil.copyfile(image, target / 'companion.bin')
manifest = dict(model='keychron/c100_8k', file='companion.bin', bytes=len(data),
                sha256=hashlib.sha256(data).hexdigest(),
                sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
                qmkCommit='9ada9b7baecb9591c469b9b068146ac5891a480a')
(target / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
