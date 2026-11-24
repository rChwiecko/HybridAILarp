#!/usr/bin/env python3
"""Prepare the Flutter web build for the existing Firebase Hosting target.

Pass --sample to package a build without Firebase configuration for a local preview.
"""
from pathlib import Path
import shutil
import hashlib
import json
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source, target = root / 'app/build/web', root / 'dist'
if not (source / 'flutter_bootstrap.js').is_file():
    raise SystemExit('Build Flutter web before packaging.')
# Without the public web configuration and App Check key, live plans, accounts
# and AI are disabled in the browser, so never package that for deployment.
config = json.loads((source / 'assets/assets/firebase.json').read_text())
if '--sample' not in sys.argv and not (config['web'].get('appId') and config.get('appCheckSiteKey')):
    raise SystemExit('This web build has no Firebase configuration or App Check key. Add '
                     'web/firebase-config.local.json (see docs/RELEASE.md) and rebuild, or '
                     'pass --sample for a local-only preview.')
# Android packaging adds App Links verification and release metadata to dist/.
# Keep them when only the web app is rebuilt.
with tempfile.TemporaryDirectory() as scratch:
    kept = [name for name in ['.well-known', 'downloads'] if (target / name).is_dir()]
    for name in kept:
        shutil.copytree(target / name, Path(scratch) / name)
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)
    for name in kept:
        if not (target / name).exists():
            shutil.copytree(Path(scratch) / name, target / name)
# Precache the app shell and the CanvasKit renderer that this dart2js build
# loads. Debug symbols, licences and the skwasm/wimp/webparagraph renderers
# stay on the network, which keeps each update a few megabytes per visitor.
renderer = {'canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm',
            'canvaskit/chromium/canvaskit.js', 'canvaskit/chromium/canvaskit.wasm'}
def precached(name):
    path = Path(name)
    if path.parts[0] in ['.well-known', 'downloads'] or path.suffix in ['.map', '.symbols']:
        return False
    if path.name in ['sw.js', 'flutter_service_worker.js', 'NOTICES', '.last_build_id']:
        return False
    return path.parts[0] != 'canvaskit' or name in renderer
files = sorted(name for name in (p.relative_to(target).as_posix()
                                 for p in target.rglob('*') if p.is_file()) if precached(name))
# Version the app shell, leaving model caches owned by the inference runtime.
digest = hashlib.sha256()
for name in files:
    digest.update(name.encode())
    digest.update((target / name).read_bytes())
worker = (root / 'app/web/sw.js').read_text()
worker = worker.replace("'meethalfway-shell-development'", repr('meethalfway-shell-' + digest.hexdigest()[:16]))
worker = worker.replace('const SHELL = [];', 'const SHELL = ' + json.dumps(files) + ';')
(target / 'sw.js').write_text(worker)
size = sum((target / name).stat().st_size for name in files)
print(f'Packaged Flutter web in dist/ ({len(files)} files, {size / 1e6:.1f} MB precached).')
