#!/bin/bash
# PR #19262 review: spa_vdev_detach() gains a raidz-shrink path, armed by
# the module tunables raidz_contract_guid + raidz_force_width (or
# raidz_contracting), that detaches the last child of a raidz and skips
# vdev_dtl_required().  Nothing checks that the child holds no live data.
#
# Case 1: raidz1 of 4, data written at full width, arm the tunables and
#         detach the last child.  Then read back / scrub.
# Case 2: the same with child 0 offline first (degraded raidz1, so the
#         last child holds the only remaining redundancy).
# On master the detach must fail (ENOTSUP: raidz children can't be
# detached).  Run as root in a test VM.  Prints RESULT lines.
set -u
P=rzdet; D=/var/tmp/rzdet
M=/sys/module/zfs/parameters
reset_tun() {
	for t in raidz_force_width raidz_contracting raidz_contract_guid; do
		[ -e $M/$t ] && echo 0 > $M/$t
	done
}
cleanup() {
	reset_tun
	zpool destroy -f $P 2>/dev/null
	rm -rf $D
}

run() { # case-name offline-child0(0/1) tunable(force_width|contracting)
	cleanup; mkdir -p $D
	for i in 0 1 2 3; do truncate -s 512m $D/d$i; done
	zpool create -f $P raidz1 $D/d0 $D/d1 $D/d2 $D/d3 || exit 1
	zfs create -o compression=off $P/fs
	dd if=/dev/urandom of=/$P/fs/f bs=1M count=64 status=none
	zpool sync $P
	local sum=$(md5sum < /$P/fs/f)
	[ "$2" = 1 ] && zpool offline $P $D/d0
	local g=$(zpool get -Hp -o value guid $P raidz1-0)
	echo "  top-level guid $g"
	if [ -e $M/raidz_contract_guid ]; then
		echo $g > $M/raidz_contract_guid
		if [ "$3" = force_width ]; then
			echo 3 > $M/raidz_force_width
		else
			echo 1 > $M/raidz_contracting
		fi
	fi
	if zpool detach $P $D/d3; then
		echo "  detach of the last raidz child SUCCEEDED"
		zpool status $P | sed -n '/config:/,$p' | sed 's/^/    /'
		reset_tun
		zpool export $P && zpool import -d $D $P
		local rd
		rd=$(md5sum < /$P/fs/f 2>&1)
		zpool scrub -w $P 2>/dev/null
		zpool status -v $P | grep -E "state:|errors:|scan:" | sed 's/^/    /'
		if [ "$rd" = "$sum" ] && \
		    zpool status $P | grep -q "No known data errors"; then
			echo "RESULT: $1: detach allowed, data intact"
		else
			echo "RESULT: $1: DATA LOSS after detach (read: $rd)"
		fi
	else
		echo "RESULT: $1: detach refused"
	fi
}

readonly_check() {
	cleanup; mkdir -p $D
	for i in 0 1 2 3; do truncate -s 512m $D/d$i; done
	zpool create -f $P raidz1 $D/d0 $D/d1 $D/d2 $D/d3 || exit 1
	zfs create -o compression=off $P/fs
	dd if=/dev/urandom of=/$P/fs/f bs=1M count=64 status=none
	zpool sync $P
	local sum=$(md5sum < /$P/fs/f)
	zpool export $P
	[ -e $M/raidz_force_width ] && echo 3 > $M/raidz_force_width
	if zpool import -d $D $P; then
		local rd
		rd=$(md5sum < /$P/fs/f 2>&1)
		zpool status -v $P | grep -E "state:|errors:" | sed 's/^/    /'
		reset_tun
		if [ "$rd" = "$sum" ]; then
			echo "RESULT: force_width-only: reads intact"
		else
			echo "RESULT: force_width-only: READS WRONG with raidz_force_width=3 set ($rd)"
		fi
	else
		reset_tun
		echo "RESULT: force_width-only: import failed with raidz_force_width=3"
	fi
}

echo "zfs version: $(cat /sys/module/zfs/version)"
echo "=== case 0: existing 4-wide raidz1 imported with raidz_force_width=3 (no guid, no detach)"
readonly_check
echo "=== case 1: healthy raidz1, raidz_force_width=3"
run healthy-force_width 0 force_width
echo "=== case 2: degraded raidz1 (d0 offline), raidz_force_width=3"
run degraded-force_width 1 force_width
echo "=== case 3: healthy raidz1, raidz_contracting=1"
run healthy-contracting 0 contracting
cleanup
