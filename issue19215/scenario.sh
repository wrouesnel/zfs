#!/usr/bin/env bash
# scenario.sh: the #19215 report end to end. N snapshots are automounted (as
# the reporter's daily rclone job does), while a background poller runs CMD on
# every mounted filesystem every POLL seconds (what df, monitoring agents,
# desktop free-space checks do). At the default zfs_expire_snapshot=300 the
# snapshots stay mounted; dropping the tunable to 30 then unmounts them,
# as the reporter saw.
# Usage (root): scenario.sh [CMD] [N] [POLL] [HOLD]
#   CMD: df (statfs, default) | statf (stat -f) | stat (stat) | mount (read mountinfo)
set -euo pipefail
CMD=${1:-df}; N=${2:-5}; POLL=${3:-60}; HOLD=${4:-600}
P=r19215s; F=/var/tmp/$P.img
zpool destroy $P 2>/dev/null || true
truncate -s 512M $F; zpool create -f -O mountpoint=/$P $P $F
zfs create $P/data; for i in $(seq 1 20); do head -c 65536 /dev/urandom >/$P/data/f$i; done
echo 300 >/sys/module/zfs/parameters/zfs_expire_snapshot
for s in $(seq 1 $N); do zfs snapshot $P/data@day$s; cat /$P/data/.zfs/snapshot/day$s/f* >/dev/null; done
count() { grep -c " $P/data@" /proc/self/mountinfo || true; }
poll_one() {
	awk '{print $5}' /proc/self/mountinfo | while read -r m; do
		case $CMD in
		statf) stat -f "$m" >/dev/null 2>&1 ;;
		stat) stat "$m" >/dev/null 2>&1 ;;
		esac
	done
	case $CMD in df) df >/dev/null 2>&1 ;; mount) mount >/dev/null ;; esac
	true
}
( while :; do poll_one; sleep $POLL; done ) & poller=$!
trap 'kill $poller 2>/dev/null' EXIT
t0=$(date +%s)
echo "cmd=$CMD n=$N poll=$POLL: $(count) snapshots mounted at t=0, expire=300"
sleep $HOLD
echo "t=$(( $(date +%s) - t0 )) mounted=$(count) (expire=300, held $HOLD s)"
echo 30 >/sys/module/zfs/parameters/zfs_expire_snapshot
t1=$(date +%s)
for w in 45 90 180 300; do
	sleep $(( w - ($(date +%s) - t1) ))
	echo "t=$(( $(date +%s) - t0 )) mounted=$(count) ($w s after expire=30)"
done
echo 300 >/sys/module/zfs/parameters/zfs_expire_snapshot
zpool destroy $P; rm -f $F
