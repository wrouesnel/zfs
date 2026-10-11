#!/usr/bin/env bash
# Topology variants for openzfs/zfs#19197. For each case: build the pool,
# degrade the listed leaf vdevs (zinject -A degrade), export/import, write a
# $MB MB urandom file and count ganged block pointers per level, plus which
# top-level vdev holds the L0 blocks. Also checks metadata in a special vdev.
#
# Usage (root, test VM only): variants.sh [CASE...]
D=$(cd "$(dirname "$0")" && pwd)
. "$D/lib.sh"
MB=${MB:-100}

# L0 blocks per top-level vdev id (first DVA)
l0vdevs() {
	local obj
	obj=$(stat -c %i "/$P/fs/$1")
	zdb -ddddd "$P/fs" "$obj" | awk '$2 == "L0" { split($3, a, ":"); n[a[1]]++ }
	    END { for (v in n) printf "vdev%s=%d ", v, n[v]; print "" }'
}

# ganged blocks per object type, from zdb -bbb
gangtypes() {
	zdb -bbb "$P" 2>/dev/null | awk '/number of ganged blocks/ {
	    sub(/^.*[0-9.]+ +[0-9.]+ +/, "", prev); print "   ganged:", $NF, "in", prev }
	    { prev = $0 }' | grep -v Total || true
}

# allocated space per vdev
valloc() {
	zpool list -vHp -o name,alloc "$P" | awk 'NR > 1 && $1 ~ /^\// {
	    printf "   alloc %s %d KiB\n", $1, $2 / 1024 }'
}

# run NAME "VDEVSPEC" "DEGRADE-LEAVES" [zfs create options for fs]
run() {
	local name=$1 spec=$2 deg=$3 v
	shift 3
	cleanup
	mkvdevs 4
	# shellcheck disable=SC2086
	zpool create -f -o ashift=12 -O compression=off "$P" $spec
	zfs create "$@" "$P/fs"
	for v in $deg; do degrade_quick "$W/$v"; done
	reimport
	writefile f
	printf "%-28s %-34s | %s| %s\n" "$name" \
	    "$(zpool list -H -o health "$P") $(zpool status "$P" |
	    awk '$2 == "DEGRADED" && $1 != "'"$P"'" { printf "%s ", $1 }')" \
	    "$(gangcount f)" "$(l0vdevs f)"
}

# special2 hangs txg_sync on master (z_wr_iss spins in zio_dva_allocate,
# see master_special2_hang_stacks.txt): run it only when asked by name.
cases=${*:-two1 two2 mirror copies2 raidz special specialsmall}
for c in $cases; do
	case $c in
	two1)	run "2 disks, 1 degraded" "$W/d0 $W/d1" d0 ;;
	two2)	run "2 disks, both degraded" "$W/d0 $W/d1" "d0 d1" ;;
	mirror)	run "mirror, 1 child degraded" "mirror $W/d0 $W/d1" d0 ;;
	copies2) run "1 disk degraded, copies=2" "$W/d0" d0 -o copies=2 ;;
	raidz)	run "raidz1, 1 child degraded" "raidz $W/d0 $W/d1 $W/d2" d0 ;;
	special)
		run "special degraded" "$W/d0 special $W/d1" d1
		gangtypes; valloc ;;
	special2)
		run "special+normal degraded" "$W/d0 special $W/d1" "d0 d1"
		gangtypes; valloc ;;
	specialsmall)
		run "special degr, small_blocks" "$W/d0 special $W/d1" d1 \
		    -o special_small_blocks=128K
		gangtypes; valloc ;;
	esac
done
cleanup
