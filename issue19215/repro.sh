#!/usr/bin/env bash
# repro.sh: #19215 automounted snapshots never expire.
# Usage (root): repro.sh MODE [EXPIRE] [WAIT]
#   MODE quiet     access the snapshot, then nothing touches it
#   MODE mountinfo access it, then read /proc/self/mountinfo every POLL s
#   MODE df        access it, then statfs every mount (df) every POLL s
#   MODE findmnt   like mountinfo but via findmnt (libmount)
#   MODE stat      stat(1) the snapshot mountpoint every POLL s
#   MODE statf     stat -f (statfs) the snapshot mountpoint every POLL s
#   MODE read      read a file inside the snapshot every POLL s (must stay mounted)
# Reading /proc/self/mountinfo does not defer expiry (zpl_show_devname uses
# zpl_exit), so the mount id is recorded after the first access and compared
# at the end: same id = the original automount never expired (statf can
# re-automount after an expiry; that shows up as a different id).
set -euo pipefail
MODE=${1:-quiet}; EXPIRE=${2:-30}; WAIT=${3:-$((EXPIRE * 3))}; POLL=${POLL:-$((EXPIRE / 3))}
P=r19215; F=/var/tmp/$P.img
zpool list $P >/dev/null 2>&1 || {
	truncate -s 512M $F; zpool create -f -O mountpoint=/$P $P $F; }
zfs destroy -r $P/fs 2>/dev/null || true
zfs create $P/fs
for i in $(seq 1 20); do head -c 65536 /dev/urandom >/$P/fs/f$i; done
zfs snapshot $P/fs@s1
echo $EXPIRE >/sys/module/zfs/parameters/zfs_expire_snapshot
echo 1 >/sys/module/zfs/parameters/zfs_flags
echo 0 >/proc/spl/kstat/zfs/dbgmsg
# kprobes log each expiry re-arm (zfsctl_snapshot_unmount_delay, 2.4.x only)
# and each unmount attempt (zfsctl_snapshot_unmount; zfsctl_snapshot_invalidate
# on master) and automount (zpl_snapdir_automount).
snapmounted() { grep -c " $P/fs@s1 " /proc/self/mountinfo || true; }
mntid() { awk -v d=$P/fs@s1 '{for (i = 7; i <= NF; i++) if ($i == "-") break; if ($(i+2) == d) print $1}' /proc/self/mountinfo | xargs; }
T=/sys/kernel/tracing
if [ -d $T ]; then
	echo 0 >$T/tracing_on; echo >$T/trace
	[ -e $T/events/kprobes/enable ] && echo 0 >$T/events/kprobes/enable
	echo >$T/kprobe_events
	for fn in zfsctl_snapshot_unmount_delay zfsctl_snapshot_unmount \
	    zpl_snapdir_automount zfsctl_snapshot_invalidate; do
		echo "p:z_$fn $fn" >>$T/kprobe_events 2>/dev/null && echo 1 >$T/events/kprobes/z_$fn/enable || true
	done
	echo 1 >$T/tracing_on
fi
cat /$P/fs/.zfs/snapshot/s1/f* >/dev/null
id0=$(mntid)
t0=$(date +%s)
echo "mode=$MODE expire=$EXPIRE wait=$WAIT poll=$POLL"
while [ $(( $(date +%s) - t0 )) -lt $WAIT ]; do
	case $MODE in
	quiet) ;;
	mountinfo) cat /proc/self/mountinfo >/dev/null ;;
	df) df >/dev/null 2>&1 || true ;;
	findmnt) findmnt >/dev/null ;;
	stat) stat /$P/fs/.zfs/snapshot/s1 >/dev/null ;;	# getattr only
	statf) stat -f /$P/fs/.zfs/snapshot/s1 >/dev/null ;;	# statfs only
	read) cat /$P/fs/.zfs/snapshot/s1/f1 >/dev/null ;;	# real use (control)
	esac
	sleep $POLL
done
res=$(snapmounted)
echo "RESULT mode=$MODE expire=$EXPIRE waited=$(( $(date +%s) - t0 )) still_mounted=$res mntid_start=$id0 mntid_end=$(mntid)"
grep -a -E 'unmount; path=|mount; name=' /proc/spl/kstat/zfs/dbgmsg | tail -5 || true
[ -d $T ] && { grep -E "z_(zfsctl|zpl)" $T/trace | awk '{print $4, $5, $1}' | tail -30; echo 0 >$T/tracing_on; }
umount /$P/fs/.zfs/snapshot/s1 2>/dev/null || true
