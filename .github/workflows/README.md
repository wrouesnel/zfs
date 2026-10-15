
## CI overview

The main test pipeline is `zfs-qemu.yml`. Code checking and other
workflows run independently alongside it.

```mermaid
flowchart TB
subgraph Functional testing
  Setup[test-config: pick ci_type + OS matrix]
  Setup --> Reused[qemu-reused: fork results]
  Setup --> Gate
  Precheck[precheck: zfs-precheck.yml, PRs only] --> Gate
  Gate{{qemu-vm: unless the precheck verdict failed}}
  Gate --> almalinux
  Gate --> centos[centos-stream]
  Gate --> debian
  Gate --> fedora
  Gate --> ubuntu
  Gate --> freebsd
  Reused --> Cleanup[cleanup + summary]
  almalinux --> Cleanup
  centos --> Cleanup
  debian --> Cleanup
  fedora --> Cleanup
  ubuntu --> Cleanup
  freebsd --> Cleanup
end

subgraph Code checking
  checkstyle.yaml
  codeql.yml
  smatch.yml
end

subgraph Other workflows
  zfs-arm.yml
  zloop.yml
  labels.yml
end
```

Every `qemu-vm` matrix entry runs on a fixed `ubuntu-24.04` host.
The steps inside one entry are:

1) set up QEMU and boot the guest (~2-4m)
2) install build dependencies in the guest (~2-4m)
3) build zfs modules in the guest (~8-12m)
4) run functional tests (~2-4h)
5) package and upload per-OS test logs (~10s)

A per-OS entry takes about 3 to 4 hours. Once all entries finish, the
`cleanup` job aggregates the results into a summary.

### `ci_type` selection

`test-config` runs `.github/workflows/scripts/generate-ci-type.py` against
the PR's changed files and picks one of:

| `ci_type` | OS matrix                                  |
|-----------|--------------------------------------------|
| `docs`    | empty (documentation-only PRs)             |
| `quick`   | 6 Linux + 1 FreeBSD                        |
| `linux`   | all supported Linux distros                |
| `freebsd` | all supported FreeBSD versions             |
| default   | cross-platform sample                      |

Pushes to `openzfs/zfs` skip the matrix entirely; only PRs (and pushes to
forks) build.

Authors can force a specific ci_type by adding `ZFS-CI-Type: <type>` to
the most recent commit message. The `ZTS_OS_OVERRIDE` repository variable
can also alter the selection. The `workflow_dispatch` trigger accepts
`fedora_kernel_ver` (Fedora-only run with a chosen kernel) and
`specific_os` (pin the matrix to one OS).

### PRs that only change tests

If a PR only changes test scripts (`scripts/changed-tests.py detect`),
`test-config` passes those tests to the matrix, and each OS runs just
them, on one VM, in their groups from `common.run` and the platform
runfile: with the same setup, cleanup, tags and timeouts as in the full
suite.  A test that isn't in an OS's runfiles is skipped there.  The PR
may also change runfiles, as long as the changed sections only add or
remove tests (added tests run too), and
`tests/zfs-tests/tests/Makefile.am`, as long as it only lists files the
PR adds or deletes.  Anything else, including files shared between tests
(`include/`, `.cfg` and `.kshlib` files, `setup.ksh` and `cleanup.ksh`,
test commands and data, the test runner and `zts-report.py.in`), runs
the full suite, as does a `ZFS-CI-Type` tag.

Only PRs do this.  Pushes always run the full suite, so a fork's push
results can stand in for a PR's (see below), whatever the PR changes.

### Reusing fork QEMU results

PRs can reuse QEMU results from their source fork without a repository
allowlist or additional configuration.

For each requested OS, `test-config` looks for a successful job in the
latest push run for the exact PR head SHA. The run must be completed and
no more than seven days old. Build, test and summary steps must all have
completed successfully on `ubuntu-24.04`.
Push runs use full tests, so they also cover PRs requesting quick tests.
`ZTS_OS_OVERRIDE` in a fork can reduce the available OS results; missing
OS jobs still run in the base repository. Dispatch and PR runs are not
reused because they can select different inputs or test suites.

Reused matrix jobs report success with a link to the original job and
logs. The cleanup summary links to these results; their artifacts remain
in the fork. Failed jobs, unavailable API responses and incomplete runs
fall back to normal testing. Only the latest run and its latest job
results are considered, so an older success cannot replace a
newer failure. Only completed workflows are reused, even if individual
jobs in a running workflow have already finished.

Fork results are reused only on the first workflow attempt. Requested
reruns execute the selected jobs in the base repository, including
selective QEMU matrix reruns that retain the original Setup outputs.

This version checks run and step metadata and assumes the fork uses the
standard full-testing push workflow. It does not compare workflow or
script contents with the PR base, allowing its own PR to demonstrate
reuse. Comparing CI files is deferred to a later change.

### Reusing fork zloop results

The `zloop` job uses the same helper, `reuse-ci.py zloop`, to find a
successful push job for the exact PR head SHA. Push and PR jobs use
the same build configuration (debug, ASAN and UBSAN) and test command.
Dependency installation, autogen, configure, make, install and tests
must all have succeeded on `ubuntu-24.04`. The same run age and source
repository checks apply as for QEMU.

A matching result skips build and testing in the PR job and links to
the original job logs. Otherwise the usual zloop steps run. Successful
zloop jobs do not upload artifacts, so reuse needs no artifact transfer.

### Reusing other fork results

`unit-tests`, `zfs-arm` and `checkstyle` also use `reuse-ci.py`, passing
their workflow name. The helper specifies each workflow's file, runner,
job name and required successful steps. All use the same SHA, run age,
source repository and first-attempt checks as QEMU and zloop.

Unit tests require the complete userspace build and test sequence on
`ubuntu-24.04`. ARM requires dependency installation and the build/sanity
test step on `ubuntu-24.04-arm`; manual runs with a custom GCC are not
reused. Checkstyle requires prepare, configure, build, style, lint and
ABI checks on `ubuntu-22.04`. Missing or failed results run normally,
as do manually requested reruns.

### Supported guests

Auto-selected:

- Linux: almalinux 8/9/10, centos-stream 9/10, debian 11/12/13,
  fedora 43/44, ubuntu 22/24/26
- FreeBSD: 14.4-RELEASE, 14.5-STABLE, 15.1-RELEASE/STABLE, 16.0-CURRENT

Available via `specific_os` or `ZTS_OS_OVERRIDE`:

- archlinux, tumbleweed

### Code checking

- `checkstyle.yaml`: source-style checks
- `codeql.yml`: CodeQL analysis
- `smatch.yml`: smatch analysis

### Other workflows

- `zfs-arm.yml`: ARM build on `ubuntu-24.04-arm`
- `zloop.yml`: host-side zloop
- `labels.yml`: maintains PR status labels
- `zfs-precheck.yml`: quick checks on one VM, called by `zfs-qemu.yml`
  for PRs before its matrix; for PRs that add a test in one commit and
  fix the bug in a later commit, checks that the test fails on the test
  commit and passes on the PR head (see below)
- `zfs-qemu-packages.yml`: manually dispatched, builds release RPMs or
  tests RPM installation from the ZFS yum repo

### Failing test, then fix (`zfs-precheck.yml`)

A bug fix is easiest to review when the PR first adds a test that shows
the bug, then fixes it.  `zfs-precheck.yml` checks that pattern.  Its
`Detect` job runs `scripts/failfirst-detect.py` over the PR's commits and
looks for a *test commit*:

- it changes only files under `tests/`,
- it adds or modifies at least one test script (other than `setup.ksh`
  and `cleanup.ksh`), or a channel program (`.zcp`) that is run by the
  `.ksh` test of the same name, and
- a later commit in the PR changes files outside `tests/`.

For each test commit (up to four), a `Verify` job builds that commit with
`--enable-debug` in one `ubuntu24` VM and runs the tests it adds or
modifies; at least one of them must fail, be killed, hang or crash the
kernel.  Another `Verify` job builds the PR head and runs the same tests;
all of them must pass without kernel errors.  Tests run one at a time
with `zfs-tests.sh -t`, and the VM is restarted after a crash or hang.
The `Verdict` job collects the results.  PRs without a test commit finish
after `Detect`.

For a PR, `zfs-qemu.yml` calls `zfs-precheck.yml` as its `Precheck` job,
and the `qemu-vm` matrix waits for it:

- no test commit: the matrix starts once `Detect` has finished (about a
  minute),
- the verdict passed: the matrix runs,
- the verdict failed: the matrix is skipped, so a PR whose test doesn't
  catch the bug, or whose fix doesn't fix it, gets that answer in about
  half an hour without a full test run.

Any failure of the precheck skips the matrix, including a broken VM in a
`Verify` job.  Re-running the failed jobs of the `zfs-qemu` run reruns
the precheck and then the matrix.

OSes whose QEMU results are reused from the fork don't wait: they are a
separate matrix job, `qemu-reused`, with the same name and steps as
`qemu-vm`, so the checks are `qemu-x86 (<os>)` either way, and a
requested rerun of one of them runs its tests.  If every OS is reused,
nothing waits for the precheck.

Pushes (to forks) don't call the precheck from `zfs-qemu.yml`:
`zfs-precheck.yml` runs on its own alongside it, and the matrix always
runs in full, so the fork's push results stay complete for reuse.
`zfs-precheck.yml` can also be run by hand with `workflow_dispatch`.

The repository variables `FAILFIRST_OS` and `FAILFIRST_UPSTREAM` change
the test OS and the repository whose `master` is the base for pushes.
