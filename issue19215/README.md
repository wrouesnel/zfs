# openzfs/zfs#19215 reproducer: automounted snapshots never expire

Run as root in a disposable test VM only: the scripts create and destroy
pools and change zfs_expire_snapshot and zfs_flags.

- `repro.sh MODE [EXPIRE] [WAIT]` automounts one snapshot, then runs MODE
  every EXPIRE/3 seconds and reports whether the snapshot is still mounted
  after WAIT seconds.  MODE is quiet, mountinfo, findmnt, df, stat,
  statf (stat -f) or read.  kprobes on zfsctl_snapshot_unmount_delay (2.4.x)
  show which process re-arms the expiry.
- `scenario.sh [df|stat|statf|mount] [N] [POLL] [HOLD]` is the report end to
  end: N automounted snapshots, a poller every POLL seconds, held HOLD seconds
  at zfs_expire_snapshot=300, then the tunable is set to 30.
- `workflow.sh shell|service|user` is the reporter's job (zfs snapshot, then
  rclone reads the snapshot) from a shell, a sandboxed systemd service, or as
  user nobody, with nothing polling afterwards.
- `deb13-prep.sh` installs zfs 2.4.3-2~bpo13+1 on Debian 13 (from
  snapshot.debian.org, since it has left trixie-backports).

`logs/`: Debian 13.7, kernel 6.12.111+deb13-amd64, zfs 2.4.3-2~bpo13+1 and
2.4.4-1~bpo13+1 (`*_243`, `*_244`, `run1`-`run3`), and a debug build of master
4542a317e in an Ubuntu 24.04 VM (`run_master_30.log`).
