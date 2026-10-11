#!/usr/bin/env bash
# Consequences of openzfs/zfs#19197 (gang blocks on a degraded single-disk
# vdev): space, gang headers, which object types gang, cold-read I/O counts
# and time, ZIL, logging, kstats, persistence across a module reload, and
# zfs_metaslab_try_hard_before_gang=1.
#
# Usage (root, test VM only): measure.sh /dev/vdX
# The disk is used whole so that /sys/block/<disk>/stat counts the pool's I/O.
D=$(cd "$(dirname "$0")" && pwd)
. "$D/lib.sh"

DISK=${1:?usage: measure.sh /dev/vdX}
blk=$(basename "$DISK")
REPS=${REPS:-3}

# disk reads, sectors read (512 B)
dstat() { awk '{ print $1, $3 }' "/sys/block/$blk/stat"; }

# ZFS read I/Os issued to the vdevs (sync+async, individual+aggregated)
zreads() {
	zpool iostat -rHp "$P" | awk 'NR > 1 && NF == 0 { exit }
	    NF == 15 { n += $2 + $3 + $6 + $7 } END { print n }'
}

alloc() { zpool list -Hp -o allocated "$P"; }

# timed write of $MB MB urandom (data pre-generated so urandom isn't timed)
twrite() {
	local a0 t0 t1
	a0=$(alloc); t0=$(date +%s.%N)
	dd if="$W/src" of="/$P/fs/$1" bs=1M status=none
	zpool sync "$P"
	t1=$(date +%s.%N)
	printf "write %-9s %5.2fs  pool alloc delta %d KiB\n" "$1" \
	    "$(echo "$t1 - $t0" | bc)" $((($(alloc) - a0) / 1024))
}

# cold read: export/import empties the ARC for the pool
cread() {
	local s0 s1 t0 t1 z0
	reimport
	z0=$(zreads); read -r -a s0 < <(dstat); t0=$(date +%s.%N)
	cat "/$P/fs/$1" >/dev/null
	t1=$(date +%s.%N); read -r -a s1 < <(dstat)
	printf "cold read %-9s %5.2fs  zfs vdev reads %5d  disk reads %5d  KiB read %7d\n" \
	    "$1" "$(echo "$t1 - $t0" | bc)" $(($(zreads) - z0)) \
	    $((s1[0] - s0[0])) $(((s1[1] - s0[1]) / 2))
}

dsize() {
	local obj
	obj=$(stat -c %i "/$P/fs/$1")
	zdb -dd "$P/fs" "$obj" | awk '$1 == "'"$obj"'" { print "dsize", $5, "lsize", $6 }'
	echo "du -k: $(du -k "/$P/fs/$1" | cut -f1)"
}

cleanup
wipefs -aq "$DISK"
dd if=/dev/urandom of="$W/src" bs=1M count="$MB" status=none
mkpool "$DISK"
V=$(zpool status -P "$P" | awk '$1 ~ /^\// { print $1; exit }')
zfs create -o recordsize=8k "$P/small"

log "healthy writes"
twrite h1
a0=$(alloc)
for i in $(seq 1 500); do
	head -c 8192 "$W/src" >"/$P/small/h$i"
done
zpool sync "$P"
echo "500 x 8K files, pool alloc delta $((($(alloc) - a0) / 1024)) KiB"

degrade_quick "$V"
reimport
log "state: $(vstate "$V") / label: $(persisted "$V")"
zpool events -c >/dev/null
echo 0 >/proc/spl/kstat/zfs/dbgmsg
dmesg -C
s0=$(stats)

log "degraded writes"
twrite g1
a0=$(alloc)
for i in $(seq 1 500); do
	head -c 8192 "$W/src" >"/$P/small/g$i"
done
zpool sync "$P"
echo "500 x 8K files, pool alloc delta $((($(alloc) - a0) / 1024)) KiB"

log "kstats: before $s0"
log "kstats: after  $(stats)"
log "logging while ganging:"
echo "zpool events (non-history): $(zpool events -H | grep -vc history_event || true)"
{ zpool events -H | grep -v history_event || true; } | awk '{ print $NF }' |
    sort | uniq -c
echo "dbgmsg lines mentioning gang/alloc: $(grep -ciE 'gang|alloc' /proc/spl/kstat/zfs/dbgmsg || true) (zfs_flags=$(cat /sys/module/zfs/parameters/zfs_flags)), sample:"
grep -iE 'gang|alloc' /proc/spl/kstat/zfs/dbgmsg | sed -n '1,3p' || true
echo "dmesg lines: $(dmesg | wc -l)"
zpool status "$P" | sed -n '1,/^errors/p'

log "gang counts"
for f in h1 g1; do echo "$f: $(gangcount "$f")"; done
echo "small/h1: $(gangcount h1 "$P/small")  small/g1: $(gangcount g1 "$P/small")"
for f in h1 g1; do echo "$f $(dsize "$f")"; done

log "one ganged L0 block pointer"
zdb -ddddd "$P/fs" "$(stat -c %i "/$P/fs/g1")" | awk '$2 == "L0" && $3 ~ /G$/ && !n++' 

log "zdb -bbb: ganged blocks by type"
zdb -bbb "$P" >"$W/zdb-b.txt" 2>&1 || true
grep -E "ganged count|bp count" "$W/zdb-b.txt" || true
awk '/number of ganged blocks/ { print prev; print } { prev = $0 }' \
    "$W/zdb-b.txt"

log "ZIL: 64 x 128K O_SYNC writes (sync=always) on a frozen pool"
zfs create -o sync=always "$P/zil"
echo x >"/$P/zil/first"; zpool sync "$P"; echo y >"/$P/zil/second"
g0=$(kst zio_stats gang_writes)
zpool freeze "$P"
dd if="$W/src" of="/$P/zil/f" bs=128k count=64 oflag=sync status=none
echo "gang_writes delta during sync writes: $(($(kst zio_stats gang_writes) - g0))"
zdb -ivvv "$P/zil" >"$W/zil.txt" 2>&1 || true
echo "WR_INDIRECT block pointers in the ZIL: $(grep -c 'DVA\[0\]' "$W/zil.txt" || true)," \
    "ganged: $(grep 'DVA\[0\]' "$W/zil.txt" | grep -c ' gang ' || true)"
grep -m1 'DVA\[0\]' "$W/zil.txt" || true
reimport
echo "after ZIL replay: f $(gangcount f "$P/zil")"

log "cold reads (reps=$REPS)"
for ((r = 0; r < REPS; r++)); do cread h1; cread g1; done

log "persistence: export, module reload, import"
zpool export "$P"
modprobe -r zfs && modprobe zfs
zpool import -d /dev "$P"
log "state: $(vstate "$V")"
twrite g2
echo "g2: $(gangcount g2)"

log "zfs_metaslab_try_hard_before_gang=1"
echo 1 >/sys/module/zfs/parameters/zfs_metaslab_try_hard_before_gang
s0=$(stats)
twrite th
echo "th: $(gangcount th)"
echo "before $s0"; echo "after  $(stats)"
echo 0 >/sys/module/zfs/parameters/zfs_metaslab_try_hard_before_gang

log "zpool clear"
zpool clear "$P"
log "state: $(vstate "$V")"
twrite c1
echo "c1: $(gangcount c1)"
cread c1
cleanup
rm -f "$W/src"
