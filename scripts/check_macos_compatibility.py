#!/usr/bin/env python3
"""Reject host Mach-O deployment targets newer than the supported macOS."""
import argparse
from pathlib import Path
import struct
import sys


def versions(data, offset=0):
    magic = data[offset:offset+4]
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack_from('>I', data, offset+4)[0]
        size = 32 if magic[-1] == 0xbf else 20
        for i in range(count):
            start = offset + 8 + size*i
            position = struct.unpack_from('>Q' if size == 32 else '>I', data, start+8)[0]
            yield from versions(data, offset+position)
        return
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
        return
    ncmds = struct.unpack_from('<I', data, offset+16)[0]
    cursor = offset + (32 if magic[0] == 0xcf else 28)
    found = False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or cursor+size > len(data):
            raise ValueError('Invalid Mach-O load command')
        if cmd == 0x32:
            platform, version = struct.unpack_from('<II', data, cursor+8)
            if platform != 1:
                raise ValueError('Unexpected non-macOS host binary')
            found = True
            yield (version >> 16, (version >> 8) & 255, version & 255)
        elif cmd == 0x24:
            version = struct.unpack_from('<I', data, cursor+8)[0]
            found = True
            yield (version >> 16, (version >> 8) & 255, version & 255)
        cursor += size
    if not found:
        raise ValueError('Mach-O has no deployment target')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', type=Path)
    parser.add_argument('--maximum', default='15.0')
    parser.add_argument('--embedded', action='store_true')
    args = parser.parse_args()
    root = Path(sys._MEIPASS) if args.embedded else args.root
    if root is None:
        parser.error('Specify root or --embedded')
    maximum = tuple(map(int, args.maximum.split('.')))
    maximum += (0,)*(3-len(maximum))
    count = 0
    failures = []
    for path in root.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        if 'device-bundle' in path.parts:
            continue
        try:
            for version in versions(path.read_bytes()):
                count += 1
                if version > maximum:
                    failures.append(f'{path.relative_to(root)} requires {version}')
        except (ValueError, struct.error) as error:
            failures.append(f'{path.relative_to(root)}: {error}')
    if not count:
        failures.append('No host Mach-O binaries found')
    if failures:
        raise SystemExit('\n'.join(failures))
    print(f'macOS {args.maximum} deployment targets verified: {count} Mach-O slices')


if __name__ == '__main__':
    main()
