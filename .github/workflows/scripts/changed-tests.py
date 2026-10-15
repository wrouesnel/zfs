#!/usr/bin/env python3

"""
Run only the tests a PR changes, when that is all it changes.

Usage:
  changed-tests.py detect BASE HEAD
  changed-tests.py runfile RUNFILE_DIR OUT_DIR RUNFILES TEST...

detect (on the runner, in the source tree): print the tests to run, space
separated, as zfs-tests.sh -t takes them (tests/functional/<area>/<name>.ksh),
if every file changed between the merge base of BASE and HEAD, and HEAD, is
one of:

- a test script (tests/zfs-tests/tests/functional/**.ksh, other than
  setup.ksh and cleanup.ksh) listed as a test in common.run, linux.run or
  freebsd.run at HEAD, or a deleted test script,
- a channel program (.zcp) run by the .ksh test of the same name,
- one of those runfiles or sanity.run, where every section that changed
  keeps its options (setup, cleanup, tags, timeout, user) and only adds
  or removes tests; added tests are run too,
- tests/zfs-tests/tests/Makefile.am, where every added or removed line
  names one of the files the PR adds or deletes.

Otherwise print nothing, and the full suite runs.  Anything shared between
tests (include/, .cfg, .kshlib, setup.ksh, cleanup.ksh, other pre and post
scripts, test commands and data, the test runner) needs the full suite.
The reason goes to stderr.

runfile (in the test VM): write a copy of each runfile in RUNFILES (comma
separated names in RUNFILE_DIR) to OUT_DIR, keeping only the sections that
hold one of TEST..., and in them only those tests, with the sections'
setup, cleanup, tags and timeouts.  Print the written runfiles, comma
separated, for zfs-tests.sh's RUNFILES.  Tests that aren't in these
runfiles (for example Linux-only tests on FreeBSD) are skipped; if none are
left, print nothing.
"""

import ast
import configparser
import os
import re
import subprocess
import sys

# Paths are passed to shell scripts, so only plain names are accepted.
TEST_SCRIPT_RE = re.compile(
    r'^tests/zfs-tests/(tests/functional/[A-Za-z0-9_./-]+\.ksh)$')
# A channel program (.zcp) is run by the .ksh test of the same name.
ZCP_RE = re.compile(
    r'^tests/zfs-tests/(tests/functional/[A-Za-z0-9_./-]+)\.zcp$')
NOT_A_TEST = ('setup.ksh', 'cleanup.ksh')
RUNFILES = ('common.run', 'linux.run', 'freebsd.run')
# sanity.run lists a subset of the tests in the others, for quick CI.
REGISTERED_IN = RUNFILES + ('sanity.run',)
RUNFILE_RE = re.compile(r'^tests/runfiles/([a-z]+\.run)$')
MAKEFILE = 'tests/zfs-tests/tests/Makefile.am'
MAKEFILE_DIR = 'tests/zfs-tests/tests/'


class FullSuite(Exception):
    pass


def git(*args, check=True):
    return subprocess.run(['git'] + list(args), check=check,
                          capture_output=True, text=True)


def changed_files(base, head):
    """Return [(status, path)]; a rename is a delete and an add."""
    out = git('diff', '--name-status', '-M', '-z', base, head).stdout
    fields = out.split('\0')
    files = []
    i = 0
    while i < len(fields) and fields[i]:
        status = fields[i]
        if status[0] in 'RC':
            if status[0] == 'R':
                files.append(('D', fields[i + 1]))
            files.append(('A', fields[i + 2]))
            i += 3
        else:
            files.append((status[0], fields[i + 1]))
            i += 2
    return files


def read_runfile(sha, name):
    """{section: {option: value}} of a runfile at a commit ({} if none)."""
    r = git('show', f'{sha}:tests/runfiles/{name}', check=False)
    if r.returncode != 0:
        return {}
    cp = configparser.ConfigParser(interpolation=None)
    cp.read_string(r.stdout)
    sections = {'DEFAULT': dict(cp.defaults())}
    for s in cp.sections():
        sections[s] = {k: v for k, v in cp.items(s, raw=True)}
    return sections


def listed_tests(section, options):
    """Test paths (tests/functional/<area>/<name>.ksh) of a section."""
    # platform runfiles name sections "<dir>:Linux" and so on
    path = section.split(':')[0]
    return {f'{path}/{t}.ksh' for t in
            ast.literal_eval(options.get('tests', '[]'))}


def runfile_changes(base, head, name):
    """Tests a runfile change adds; FullSuite for any other change."""
    old, new = read_runfile(base, name), read_runfile(head, name)
    added = set()
    for section in set(old) | set(new):
        o, n = old.get(section, {}), new.get(section, {})
        if o == n:
            continue
        if section == 'DEFAULT':
            raise FullSuite(f'{name}: DEFAULT changed')
        if o and n and \
                {k: v for k, v in o.items() if k != 'tests'} != \
                {k: v for k, v in n.items() if k != 'tests'}:
            raise FullSuite(f'{name}: [{section}] options changed')
        if not n:
            continue        # section removed with its tests
        added |= listed_tests(section, n) - \
            (listed_tests(section, o) if o else set())
    return added


def makefile_ok(base, head, files):
    """Every added or removed line names a file the PR adds or deletes."""
    changed = {p[len(MAKEFILE_DIR):] for s, p in files
               if s in 'AD' and p.startswith(MAKEFILE_DIR)}
    diff = git('diff', '-U0', base, head, '--', MAKEFILE).stdout
    for line in diff.splitlines():
        if line.startswith(('+++', '---')) or \
                not line.startswith(('+', '-')):
            continue
        entry = line[1:].replace('\\', '').strip()
        if entry and entry not in changed:
            raise FullSuite(f'{MAKEFILE}: "{entry}" is not a file the PR '
                            'adds or deletes')


def detect(base, head):
    base = git('merge-base', base, head).stdout.strip()
    files = changed_files(base, head)
    if not files:
        raise FullSuite('no changed files')

    at_head = {}
    for name in RUNFILES:
        for section, options in read_runfile(head, name).items():
            if section != 'DEFAULT':
                at_head.update((t, section) for t in
                               listed_tests(section, options))

    tests = set()
    for status, path in files:
        m = RUNFILE_RE.match(path)
        if m and m.group(1) in REGISTERED_IN:
            tests |= runfile_changes(base, head, m.group(1))
            continue
        if path == MAKEFILE:
            makefile_ok(base, head, files)
            continue
        m = TEST_SCRIPT_RE.match(path)
        if m and os.path.basename(path) not in NOT_A_TEST:
            if status == 'D':
                continue
            if m.group(1) not in at_head:
                raise FullSuite(f'{path} is not a test in {RUNFILES}')
            tests.add(m.group(1))
            continue
        m = ZCP_RE.match(path)
        if m and m.group(1) + '.ksh' in at_head:
            tests.add(m.group(1) + '.ksh')
            continue
        raise FullSuite(f'{path} is not a test script')

    tests &= set(at_head)
    if not tests:
        raise FullSuite('no tests to run')
    return sorted(tests)


def runfile(runfile_dir, out_dir, runfiles, tests):
    wanted = {}
    for t in tests:
        section, name = os.path.split(t)
        wanted.setdefault(section, set()).add(os.path.splitext(name)[0])

    written = []
    found = set()
    for name in runfiles.split(','):
        src = configparser.ConfigParser(interpolation=None)
        if not src.read(os.path.join(runfile_dir, name)):
            continue
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
    if len(sys.argv) == 4 and sys.argv[1] == 'detect':
        try:
            tests = detect(sys.argv[2], sys.argv[3])
            print(f'{sys.argv[0]}: only the changed tests run',
                  file=sys.stderr)
            print(' '.join(tests))
        except FullSuite as e:
            print(f'{sys.argv[0]}: full suite: {e}', file=sys.stderr)
            print()
    elif len(sys.argv) >= 6 and sys.argv[1] == 'runfile':
        runfile(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
