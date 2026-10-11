#!/bin/bash
# PR #19262 review: the PR switches dsl_dataset_block_born/kill (livelist),
# dsl_deadlist_insert, process_old_cb and bptree_iterate (TRAVERSE_LOGICAL)
# from BP_GET_BIRTH (physical birth for `zfs rewrite -P` blocks) to the
# logical birth.  Blocks rewritten with `zfs rewrite -P` then escape the
# livelist / bptree / deadlist bucket that should free them.
#
# Each scenario runs on a fresh pool and ends with `zdb -b`, which reports
# leaked space.  Run as root in a test VM, on master and on the PR build.
# Prints one RESULT line per scenario: OK (no leaks) or LEAK.
set -u
P=rwleak; D=/var/tmp/rwleak
M=/sys/module/zfs/parameters
LMP=$(cat $M/zfs_livelist_min_percent_shared)
cleanup() {
	echo $LMP > $M/zfs_livelist_min_percent_shared
	zpool destroy -f $P 2>/dev/null
	rm -rf $D
}

mkpool() { # extra zpool create args
	zpool destroy -f $P 2>/dev/null
	rm -rf $D; mkdir -p $D
	truncate -s 1g $D/d0
	zpool create -f "$@" $P $D/d0 || exit 1
	zfs create -o recordsize=128k -o compression=off $P/fs || exit 1
	for i in $(seq 1 8); do
		dd if=/dev/urandom of=/$P/fs/f$i bs=128k count=32 status=none
	done
	zpool sync $P
}

settle() {
	for i in 1 2 3 4 5 6; do zpool sync $P; done
	zpool wait -t free $P
	for i in 1 2 3; do zpool sync $P; done
}

check() { # name
	settle
	local out
	out=$(zdb -b $P 2>&1)
	echo "$out" | grep -iE "leak|space map|block traversal size|bp count" | sed 's/^/    /'
	zfs list -Hp -o name,used,usedbysnapshots,usedbydataset -r $P | sed 's/^/    /'
	if echo "$out" | grep -q "No leaks"; then
		echo "RESULT: $1: OK no leaks"
	else
		echo "RESULT: $1: LEAK"
	fi
}

cleanup
echo "zfs version: $(cat /sys/module/zfs/version)"

S1() {
	echo "=== S1: clone, rewrite -P 2 of 8 files in the clone, destroy it (livelist)"
	mkpool
	echo 0 > $M/zfs_livelist_min_percent_shared
	zfs snap $P/fs@s
	zfs clone $P/fs@s $P/c
	zpool sync $P
	zfs rewrite -P /$P/c/f1 /$P/c/f2
	zpool sync $P
	echo "    livelist: $(zdb -dddd $P/c 2>/dev/null | grep -ci livelist) zdb lines"
	echo "    $(zpool get -H -o property,value feature@physical_rewrite $P)"
	zdb -ddddd $P/c "$(stat -c %i /$P/c/f1)" 2>/dev/null | grep -m1 " L0 " | sed 's/^/    /'
	zfs destroy $P/c
	check S1-livelist
	echo $LMP > $M/zfs_livelist_min_percent_shared
}

S2() {
	echo "=== S2: clone, rewrite -P all of it, livelist feature disabled (bptree)"
	mkpool -o feature@livelist=disabled
	zfs snap $P/fs@s
	zfs clone $P/fs@s $P/c
	zpool sync $P
	zfs rewrite -P -r /$P/c
	zpool sync $P
	zfs destroy $P/c
	check S2-bptree
}

S3() {
	echo "=== S3: snap s1, rewrite -P, snap s2, delete files, destroy s2"
	mkpool
	zfs snap $P/fs@s1
	zpool sync $P
	zfs rewrite -P -r /$P/fs
	zpool sync $P
	zfs snap $P/fs@s2
	rm /$P/fs/f*
	zpool sync $P
	zfs destroy $P/fs@s2
	check S3-deadlist
	zfs destroy $P/fs@s1
	check S3-deadlist-after-s1
}

S4() {
	echo "=== S4: snap s1, rewrite -P, destroy fs recursively"
	mkpool
	zfs snap $P/fs@s1
	zpool sync $P
	zfs rewrite -P -r /$P/fs
	zpool sync $P
	zfs destroy -r $P/fs
	check S4-destroy-r
}

S5() {
	echo "=== S5: control without -P (S1+S3 shapes)"
	mkpool
	zfs snap $P/fs@s1
	zfs clone $P/fs@s1 $P/c
	zpool sync $P
	zfs rewrite -r /$P/c
	zfs rewrite -r /$P/fs
	zpool sync $P
	zfs snap $P/fs@s2
	rm /$P/fs/f*
	zpool sync $P
	zfs destroy $P/c
	zfs destroy $P/fs@s2
	check S5-control
}

# Usage: rewrite_leak.sh [S1 S2 ...] (default: all, S2 last: it
# panics the PR build)
for sc in ${@:-S1 S3 S4 S5 S2}; do
	$sc
done
cleanup
