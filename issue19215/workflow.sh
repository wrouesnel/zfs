#!/usr/bin/env bash
# workflow.sh: the #19215 reporter's daily job (zfs snapshot, then rclone reads
# the files from .zfs/snapshot), then wait and see whether it expires.
# Usage (root): workflow.sh HOW [EXPIRE] [WAIT]
#   HOW shell        rclone run directly from this shell
#   HOW service      rclone run from a transient systemd service (own mount ns:
#                    PrivateTmp, ProtectSystem=strict, PrivateMounts)
#   HOW user         rclone as an unprivileged user (nobody)
# kprobe on zfsctl_snapshot_unmount_delay records which processes re-arm the
# expiry; mountinfo is read once at the end.
set -euo pipefail
HOW=${1:-shell}; EXPIRE=${2:-300}; WAIT=${3:-$((EXPIRE * 2))}
P=r19215; F=/var/tmp/$P.img
zpool list $P >/dev/null 2>&1 || {
	truncate -s 1G $F; zpool create -f -O mountpoint=/$P $P $F; }
zfs list $P/data >/dev/null 2>&1 || {
	zfs create $P/data
	for d in $(seq 1 10); do mkdir -p /$P/data/d$d
		for i in $(seq 1 50); do head -c 16384 /dev/urandom >/$P/data/d$d/f$i; done
	done; chmod -R a+rX /$P/data; }
snap=daily-$(date +%s)
zfs snapshot $P/data@$snap
echo $EXPIRE >/sys/module/zfs/parameters/zfs_expire_snapshot
T=/sys/kernel/tracing
echo 0 >$T/tracing_on; echo >$T/trace
[ -e $T/events/kprobes/enable ] && echo 0 >$T/events/kprobes/enable
echo >$T/kprobe_events
for fn in zfsctl_snapshot_unmount_delay zfsctl_snapshot_unmount; do
	echo "p:z_$fn $fn" >>$T/kprobe_events; echo 1 >$T/events/kprobes/z_$fn/enable
done
echo 1 >$T/tracing_on
src=/$P/data/.zfs/snapshot/$snap; dst=/srv/rclone-dst; rm -rf $dst; mkdir -p $dst; chmod 777 $dst
case $HOW in
shell) rclone copy "$src" "$dst" ;;
user) runuser -u nobody -- rclone --config /dev/null copy "$src" "$dst" ;;
service) systemd-run --wait --quiet -p PrivateTmp=yes -p ProtectSystem=strict \
	-p PrivateMounts=yes -p ReadWritePaths=$dst rclone --config /dev/null copy "$src" "$dst" ;;
esac
echo "copied $(find $dst -type f | wc -l) files; how=$HOW expire=$EXPIRE wait=$WAIT"
t0=$(date +%s); sleep $WAIT
n=$(grep -c " $P/data@$snap " /proc/self/mountinfo || true)
echo "RESULT how=$HOW expire=$EXPIRE waited=$(( $(date +%s) - t0 )) still_mounted=$n"
echo "re-arm/unmount callers (count comm event):"
grep z_zfsctl $T/trace | awk '{print $1, $5}' | sed 's/-[0-9]* / /' | sort | uniq -c
grep z_zfsctl $T/trace | tail -8
echo 0 >$T/tracing_on
