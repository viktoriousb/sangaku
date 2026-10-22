#!/usr/bin/env python3
"""
Pins a copy of the hashtag kit into the app: writes sangaku/Resources/Export/HashtagKit.json from a kit folder.

Usage:
    python3 scripts/pin-hashtag-kit.py KIT_FOLDER

The app creates every manuscript from this copy unless Settings names a kit folder. Only what `kit.py new` needs is
copied: kit.py, VERSION, LICENSE, the class, the style and the template. A kit with uncommitted changes is refused,
so a pin always names a commit.
"""
import json, os, subprocess, sys

FILES = ['LICENSE', 'VERSION', 'kit.py', 'htag_paper.cls', 'htag.sty']
TEMPLATE = 'template'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sangaku', 'Resources', 'Export', 'HashtagKit.json')


def git(kit, *args):
    return subprocess.run(['git', '-C', kit] + list(args), capture_output=True, text=True, check=True).stdout.strip()


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    kit = os.path.abspath(sys.argv[1])
    if os.path.exists(os.path.join(kit, 'htag_manual.cls')):
        raise SystemExit('%s holds the earlier kit (htag_manual); pin the current one' % kit)
    if git(kit, 'status', '--porcelain'):
        raise SystemExit('%s has uncommitted changes; commit them first, so the pin names a commit' % kit)
    paths = list(FILES)
    for directory, subdirectories, names in os.walk(os.path.join(kit, TEMPLATE)):
        subdirectories[:] = sorted(d for d in subdirectories if d not in ('.build', '__pycache__'))
        paths += [os.path.relpath(os.path.join(directory, name), kit) for name in names if name != '.DS_Store']
    files = []
    for path in sorted(paths):
        full = os.path.join(kit, path)
        files.append({'path': path, 'executable': os.access(full, os.X_OK),
                      'contents': open(full, encoding='utf-8').read()})
    pin = {'format': 1, 'version': open(os.path.join(kit, 'VERSION'), encoding='utf-8').read().strip(),
           'commit': git(kit, 'rev-parse', '--short', 'HEAD'), 'files': files}
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(pin, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write('\n')
    print('Pinned hashtag %s (commit %s): %d files.' % (pin['version'], pin['commit'], len(files)))


if __name__ == '__main__':
    main()
