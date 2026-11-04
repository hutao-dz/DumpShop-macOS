#!/usr/bin/env python3
"""Build pinned native libraries and Python with a macOS 15 deployment target."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request

repo = Path(__file__).resolve().parents[1]
root = Path(os.environ.get('DUMPSHOP_RUNTIME_BUILD', str(repo / '.build/macos15'))).resolve()

def licenses():
    dest = root / 'prefix/share/dumpshop-licenses'
    for entry in json.loads((repo / 'scripts/macos15-sources.json').read_text()):
        source = root / 'src' / entry['name']
        for path in source.iterdir():
            if path.is_file() and path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
                directory = dest / entry['name']
                directory.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, directory / path.name)
    shutil.copyfile(repo / 'scripts/macos15-sources.json', dest / 'SOURCES.json')


def main():
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        raise SystemExit('Requires Apple Silicon macOS with Xcode build tools')
    for directory in ('downloads', 'src', 'logs'):
        (root / directory).mkdir(parents=True, exist_ok=True)
    for entry in json.loads((repo / 'scripts/macos15-sources.json').read_text()):
        name = entry['name']
        archive = root / 'downloads' / (name + '.source.tar')
        if not archive.exists():
            print('Downloading ' + name, flush=True)
            temporary = archive.with_suffix('.part')
            with urllib.request.urlopen(entry['url'], timeout=120) as response, temporary.open('wb') as output:
                shutil.copyfileobj(response, output)
            temporary.replace(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != entry['sha256']:
            raise SystemExit('Checksum mismatch: ' + name)
        destination = root / 'src' / name
        if destination.exists():
            continue
        destination.mkdir()
        with tarfile.open(archive) as bundle:
            for member in bundle.getmembers():
                parts = Path(member.name).parts[1:]
                if not parts:
                    continue
                if member.issym() or member.islnk() or '..' in parts:
                    raise SystemExit('Unsafe source archive member')
                member.name = str(Path(*parts))
                bundle.extract(member, destination)
        if 'codeload.github.com/libimobiledevice/' in entry['url']:
            (destination / '.tarball-version').write_text(entry['url'].rsplit('/', 1)[1] + '\n')
    env = dict(os.environ, DUMPSHOP_RUNTIME_BUILD=str(root))
    subprocess.run([sys.executable, str(repo / 'scripts/build_macos15_native.py')], env=env, check=True)
    licenses()
    subprocess.run([sys.executable, str(repo / 'scripts/build_macos15_python.py')], env=env, check=True)
    print('Runtime ready. Continue with: bash scripts/prepare_dependencies.sh')


if __name__ == '__main__':
    main()
