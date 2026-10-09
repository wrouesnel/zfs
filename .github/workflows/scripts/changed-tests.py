#!/usr/bin/env python3

"""
Run only the tests a PR changes, when that is all it changes.

Usage:
  changed-tests.py detect BASE HEAD
  changed-tests.py runfile RUNFILE_DIR OUT_DIR RUNFILES TEST...

detect (on the runner): if every file changed in BASE..HEAD is a test
script, a channel program (.zcp) of a test, a runfile or the tests'
Makefile.am, print the test scripts to run, space separated, as
zfs-tests.sh -t takes them (tests/functional/<area>/<name>.ksh).
Otherwise print nothing, and the full suite runs.  Anything shared
between tests (include/, .cfg, .kshlib, setup.ksh, cleanup.ksh, test
data, test commands) needs the full suite.

runfile (in the test VM): write a copy of each runfile in RUNFILES (comma
separated names in RUNFILE_DIR) to OUT_DIR, keeping only the sections and
tests named by TEST..., with their setup, cleanup, tags and timeouts.
Print the written runfiles, comma separated, for zfs-tests.sh -r.  Tests
that aren't in these runfiles (for example Linux-only tests on FreeBSD)
are skipped; if none are left, print nothing.
"""

import ast
import configparser
import os
import re
import subprocess
import sys

TEST_SCRIPT_RE = re.compile(
    r'^tests/zfs-tests/(tests/functional/[A-Za-z0-9_./-]+\.ksh)$')
ZCP_RE = re.compile(
    r'^tests/zfs-tests/(tests/functional/[A-Za-z0-9_./-]+)\.zcp$')
NOT_A_TEST = ('setup.ksh', 'cleanup.ksh')
# Files that may change along with the tests without affecting other tests.
REGISTRATION_RE = re.compile(
    r'^tests/(runfiles/[A-Za-z0-9_.-]+\.run|zfs-tests/tests/Makefile\.am)$')


def git(*args):
    return subprocess.run(['git'] + list(args), check=True,
                          capture_output=True, text=True).stdout


def exists_at(sha, path):
    return subprocess.run(['git', 'cat-file', '-e', f'{sha}:{path}'],
                          capture_output=True).returncode == 0


def detect(base, head):
    base = git('merge-base', base, head).strip()
    out = git('diff', '--name-status', '-M', '-z', base, head)
    fields = out.split('\0')
    changes = []
    i = 0
    while i < len(fields) and fields[i]:
        status = fields[i]
        if status[0] in 'RC':
            changes.append(('D', fields[i + 1]))
            changes.append(('A', fields[i + 2]))
            i += 3
        else:
            changes.append((status[0], fields[i + 1]))
            i += 2

    tests = []
    for status, path in changes:
        if REGISTRATION_RE.match(path):
            continue
        m = TEST_SCRIPT_RE.match(path)
        if m and os.path.basename(path) not in NOT_A_TEST:
            if status != 'D':
                tests.append(m.group(1))
            continue
        m = ZCP_RE.match(path)
        if m and exists_at(head, f'tests/zfs-tests/{m.group(1)}.ksh'):
            tests.append(m.group(1) + '.ksh')
            continue
        print(f'{path} is not a test script: running the full suite',
              file=sys.stderr)
        return []
    tests = sorted(set(tests))
    if not tests:
        print('no test scripts to run: running the full suite',
              file=sys.stderr)
    return tests


def runfile(runfile_dir, out_dir, runfiles, tests):
    wanted = {}
    for t in tests:
        section, name = os.path.split(t)
        wanted.setdefault(section, set()).add(os.path.splitext(name)[0])

    written = []
    found = set()
    for name in runfiles.split(','):
        src = configparser.ConfigParser(interpolation=None)
        src.read(os.path.join(runfile_dir, name))
        dst = configparser.ConfigParser(interpolation=None)
        dst.read_dict({'DEFAULT': dict(src.defaults())})
        for section in src.sections():
            # platform runfiles name sections "<dir>:Linux" and so on
            path = section.split(':')[0]
            if path not in wanted:
                continue
            listed = ast.literal_eval(src.get(section, 'tests',
                                              fallback='[]'))
            keep = [t for t in listed if t in wanted[path]]
            if not keep:
                continue
            found.update(f'{path}/{t}.ksh' for t in keep)
            # Only the section's own options; DEFAULT is written once.
            own = {k: v for k, v in src.items(section, raw=True)
                   if k not in src.defaults() or
                   v != src.defaults()[k]}
            own['tests'] = repr(keep)
            dst.read_dict({section: own})
        if dst.sections():
            path = os.path.join(out_dir, 'changed-' + name)
            with open(path, 'w') as f:
                dst.write(f)
            written.append(path)

    for t in tests:
        if t not in found:
            print(f'{t} is not in {runfiles}: skipped', file=sys.stderr)
    print(','.join(written))


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == 'detect':
        print(' '.join(detect(sys.argv[2], sys.argv[3])))
    elif len(sys.argv) >= 6 and sys.argv[1] == 'runfile':
        runfile(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
