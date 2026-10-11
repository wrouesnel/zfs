# Reproducers for the review of openzfs/zfs#19262

This branch is the PR head (800b95c8a) plus this directory.  The scripts
create and destroy pools named `rwleak` and `rzdet`, back them with files in
`/var/tmp`, and write module parameters, so run them as root in a disposable
VM only.  They need Linux (`/sys/module/zfs/parameters`).

Build and load the module from this checkout, once as a debug build and once
as a release build, and for comparison from master:

```sh
./autogen.sh
./configure --enable-debug        # or without --enable-debug for release
make -j$(nproc)
sudo make install && sudo ldconfig && sudo depmod
sudo ./scripts/zfs.sh             # (re)load the modules
```

## rewrite_leak.sh: space leaked after `zfs rewrite -P`

```sh
sudo ./pr19262-review/rewrite_leak.sh            # S1 S3 S4 S5 S2
sudo ./pr19262-review/rewrite_leak.sh S1         # or one case
```

Each case uses a fresh 1G pool and ends with `zdb -b`, then prints a line
`RESULT: <case>: OK no leaks` or `RESULT: <case>: LEAK`.  On master every case
is OK.  On a release build of the PR, S1, S2 and S3 leak.  On a debug build of
the PR, S1, S2 and S3 fail an `ASSERT`/`VERIFY` in `txg_sync` and panic, so
run one case per boot there.

## raidz_detach.sh: detaching the last raidz child

```sh
sudo ./pr19262-review/raidz_detach.sh
```

Case 0 imports an existing 4-wide raidz1 with `raidz_force_width=3`.  Cases
1-3 arm `raidz_contract_guid` with `raidz_force_width=3` or
`raidz_contracting=1`, and `zpool detach` the last child of a 4-wide raidz1
(case 2 with another child offline first), then re-import and read the data
back.  On master the detach is refused.  On the PR it succeeds, and the pool
can't be imported afterwards (`RESULT: ...: DATA LOSS after detach`).
