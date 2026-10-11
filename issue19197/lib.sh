#!/usr/bin/env bash
# Shared helpers for the openzfs #19197 reproducers (run as root in a test VM,
# never on a host with real pools). Sourced by repro.sh, measure.sh, variants.sh.
set -euo pipefail

P=${P:-t197}                    # pool name
W=${W:-/var/tmp/g197}           # work dir for file vdevs
MB=${MB:-200}                   # size of each test file
SZ=${SZ:-4G}                    # size of each file vdev
mkdir -p "$W"

log() { echo "== $*"; }

cleanup() {
	pkill -x zed 2>/dev/null || true
	zinject -c all >/dev/null 2>&1 || true
	zpool destroy -f "$P" >/dev/null 2>&1 || true
	rm -f "$W"/d*
}

# mkvdevs N: create N sparse file vdevs $W/d0..d(N-1)
mkvdevs() {
	local i
	for ((i = 0; i < $1; i++)); do
		rm -f "$W/d$i"; truncate -s "$SZ" "$W/d$i"
	done
}

# mkpool <zpool create vdev spec...>
mkpool() {
	zpool create -f -o ashift=12 -O compression=off "$P" "$@"
	zfs create "$P/fs"
}

# degrade_quick VDEV: mark VDEV degraded like ZED does, without errors
degrade_quick() {
	zinject -d "$1" -A degrade "$P" >/dev/null
}

# degrade_zed VDEV: start ZED and inject read checksum errors on VDEV until
# ZED's diagnosis engine degrades it (checksum_N/T thresholds), the way the
# reporter's vdev became DEGRADED (aux_state err_exceeded).
degrade_zed() {
	local vdev=$1 i
	pkill -x zed 2>/dev/null || true
	zed -p "$W/zed.pid" -s "$W/zed.state" >/dev/null 2>&1
	sleep 2
	zpool set checksum_n=5 "$P" "$vdev"
	zpool set checksum_t=60 "$P" "$vdev"
	# data to read back: data uncached so every read hits the disk, but
	# the indirect blocks cached (read once before injecting) so that each
	# read fails on a different data block (identical ereports are dropped)
	zfs create -o primarycache=metadata -o compression=off "$P/victim"
	dd if=/dev/urandom of="/$P/victim/f" bs=1M count=8 status=none
	zpool sync "$P"
	cat "/$P/victim/f" >/dev/null
	zinject -d "$vdev" -e corrupt -T read -f 100 "$P" >/dev/null
	for ((i = 0; i < 64; i++)); do
		dd if="/$P/victim/f" of=/dev/null bs=128k skip=$i count=1 \
		    status=none 2>/dev/null || true
		if vstate "$vdev" | grep -q DEGRADED; then break; fi
		sleep 0.2
	done
	zinject -c all >/dev/null
	pkill -x zed 2>/dev/null || true
	zfs destroy "$P/victim"
	zpool sync "$P"
	echo "ZED degraded the vdev after $((i + 1)) block reads (checksum_n=5)"
}

# vstate VDEV: state column of VDEV in zpool status
vstate() {
	zpool status -P "$P" | awk -v v="$1" '$1 == v { print $2, $6, $7, $8 }'
}

# writefile NAME: write $MB MB of urandom to /$P/fs/NAME and sync
writefile() {
	dd if=/dev/urandom of="/$P/fs/$1" bs=1M count="$MB" status=none
	zpool sync "$P"
}

# gangcount NAME [DATASET]: per level, ganged/total block pointers of the file
gangcount() {
	local ds=${2:-$P/fs} obj
	obj=$(stat -c %i "/$ds/$1")
	zdb -ddddd "$ds" "$obj" | awk '
	    $2 ~ /^L[0-9]$/ && $3 ~ /^[0-9]+:[0-9a-f]+:[0-9a-f]+G?$/ {
		t[$2]++; if ($3 ~ /G$/) g[$2]++ }
	    END { for (l = 0; l < 7; l++) { k = "L" l
		if (k in t) printf "%s %d/%d ", k, g[k] + 0, t[k] } print "" }'
}

# kst FILE KEY: value of a named kstat
kst() { awk -v k="$2" '$1 == k { print $3 }' "/proc/spl/kstat/zfs/$1"; }

stats() {
	echo "zio_stats gang_writes=$(kst zio_stats gang_writes)" \
	    "gang_multilevel=$(kst zio_stats gang_multilevel)" \
	    "metaslab_stats try_hard=$(kst metaslab_stats try_hard)"
}

# persisted DEV: degraded/aux_state of DEV in the on-disk label config
persisted() {
	zdb -l "$1" | grep -E "^ +(degraded|aux_state):" | sort -u | tr -s ' ' |
	    tr '\n' ' '
	echo
}

reimport() {
	zpool export "$P"
	zpool import -d "$W" -d /dev "$P"
}
