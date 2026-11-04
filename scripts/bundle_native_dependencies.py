#!/usr/bin/env python3
"""Bundle the dependency closure from an explicitly rebuilt runtime prefix."""
from pathlib import Path
import shutil
import subprocess
import sys


def dependencies(binary):
    if binary.read_bytes()[:2] == b'#!':
        return []
    result = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    lines = result.splitlines()[2 if binary.suffix == '.dylib' else 1:]
    return [line.strip().split(' (', 1)[0] for line in lines]


def bundle(app, prefix):
    resources = app / 'Contents/Resources'
    libraries = resources / 'lib'
    libraries.mkdir(exist_ok=True)
    queue = list((resources / 'bin').iterdir())
    visited = set()
    while queue:
        binary = queue.pop()
        if binary in visited or not binary.is_file():
            continue
        visited.add(binary)
        for dependency in dependencies(binary):
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if dependency.startswith('@rpath/libswift'):
                continue  # Swift runtime is supplied by macOS.
            if dependency.startswith('@rpath/'):
                original = prefix / 'lib' / Path(dependency).name
            elif dependency.startswith(str(prefix) + '/'):
                original = Path(dependency)
            else:
                raise RuntimeError('Unexpected external dependency: ' + dependency)
            original = original.resolve(strict=True)
            original.relative_to(prefix.resolve())
            destination = libraries / original.name
            if not destination.exists():
                shutil.copyfile(original, destination)
                queue.append(destination)
            replacement = ('@loader_path/' if binary.parent == libraries else '@loader_path/../lib/') + destination.name
            subprocess.run(['install_name_tool', '-change', dependency, replacement, str(binary)], check=True)
        # Remove build-prefix rpaths, which are unnecessary after rewriting.
        load = subprocess.check_output(['otool', '-l', str(binary)], text=True) if binary.read_bytes()[:2] != b'#!' else ''
        lines = load.splitlines()
        for index, line in enumerate(lines):
            if line.strip() == 'cmd LC_RPATH':
                path = lines[index + 2].strip().split('path ', 1)[1].split(' (offset', 1)[0]
                if path.startswith(str(prefix)):
                    subprocess.run(['install_name_tool', '-delete_rpath', path, str(binary)], check=True)
        if binary.suffix == '.dylib':
            subprocess.run(['install_name_tool', '-id', '@rpath/' + binary.name, str(binary)], check=True)
    license_source = prefix / 'share/dumpshop-licenses'
    if not license_source.is_dir():
        raise RuntimeError('Native dependency licenses missing; rebuild the runtime.')
    shutil.copytree(license_source, resources / 'licenses/native', dirs_exist_ok=True)
    print(f'Bundled native dependency closure: {len(visited)} files')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: bundle_native_dependencies.py APP NATIVE_PREFIX')
    bundle(Path(sys.argv[1]), Path(sys.argv[2]).resolve())
