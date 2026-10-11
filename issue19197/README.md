# openzfs/zfs#19197 reproducer: every block ganged on a degraded single-disk vdev

Run as root in a disposable test VM only: the scripts create and destroy
pools, start and stop `zed`, and use `zinject`.

- `repro.sh [zed|quick] [file|disk:/dev/vdX]` creates a single-vdev pool,
  degrades the vdev (`zed`: injected read checksum errors until ZED degrades
  it; `quick`: `zinject -A degrade`), writes a 200 MB random file and counts
  ganged block pointers per level while DEGRADED, after export/import and
  after `zpool clear`.  Exit status 1 means the bug reproduced.
- `measure.sh` compares space, kstats, ZIL blocks and cold reads between a
  healthy and a degraded copy, and tries `zfs_metaslab_try_hard_before_gang=1`.
- `variants.sh` runs the topology variants (two vdevs, mirror, raidz,
  copies=2, special vdev).
- `grub.sh` reads healthy and ganged files back with `grub-fstest`.
- `lib.sh` holds the shared helpers (pool `t197`, file vdevs in
  `/var/tmp/g197`).

`logs/` has the runs quoted in the issue: `master_*` on master 4542a317e and
`244_*` on zfs-2.4.4, both debug builds in an Ubuntu 24.04 VM (Linux 6.8).
