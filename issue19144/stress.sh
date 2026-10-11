#!/usr/bin/env bash
# stress.sh: workload modelled on upstream #19144 (Proxmox host whose
# virtiofsd --cache=always pins many inodes while a small ARC makes
# arc_prune run constantly).  Run as root inside the VM:
#   stress.sh setup            create pool "tank" (mirror vdc vdd) and the file trees
#   stress.sh run SECONDS      run the workload; dmesg/arcstats go to /root/s19144/
# What it does while running:
#   - pinner.py keeps ~40k files open (inode i_count > 0, like virtiofsd) and
#     mmaps+reads a share of them (page cache, i_mmap populated); it rotates
#     the pinned set so pinned inodes get released into the inode LRU;
#   - readers cat files without keeping them open, so unreferenced inodes on the
#     LRU carry page cache (inode_lru_isolate() pins those with I_LRU_ISOLATING);
#   - churn creates/stats/renames/unlinks small files and runs find(1);
#   - mmap writers + truncates on a separate set (zpl_evict_inode truncate path);
#   - snapshots every 30s (sanoid-like) and destroy of old ones;
#   - a memory hog periodically pushes the VM into reclaim (kswapd shrink_slab);
#   - zfs_arc_max is small (default 768 MiB) so arc_evict() calls arc_prune_async().
set -euo pipefail
W=/root/s19144; mkdir -p $W
D=$(cd "$(dirname "$0")" && pwd)
ARCMAX=${ARCMAX:-805306368}
cmd=${1:?setup|run}

setup() {
	modprobe zfs
	echo $ARCMAX >/sys/module/zfs/parameters/zfs_arc_max
	zpool list tank >/dev/null 2>&1 || zpool create -f -o ashift=12 -O atime=off \
	    -O xattr=sa -O compression=lz4 tank mirror \
	    /dev/disk/by-id/virtio-pvedata1 /dev/disk/by-id/virtio-pvedata2
	for fs in small big mm churn; do
		zfs list tank/$fs >/dev/null 2>&1 || zfs create tank/$fs
	done
	# 120k small files (metadata heavy), 1500 x 1 MiB files (page cache),
	# 400 x 4 MiB mmap targets
	python3 - <<'EOF'
import os
for d in range(300):
    p = f"/tank/small/d{d:03d}"
    os.makedirs(p, exist_ok=True)
    for f in range(400):
        fn = f"{p}/f{f:03d}"
        if not os.path.exists(fn):
            with open(fn, "wb") as fh:
                fh.write(os.urandom(512 + (f * 37) % 3000))
blk = os.urandom(1 << 20)
for d in range(15):
    p = f"/tank/big/d{d:02d}"
    os.makedirs(p, exist_ok=True)
    for f in range(100):
        fn = f"{p}/f{f:03d}"
        if not os.path.exists(fn):
            with open(fn, "wb") as fh:
                fh.write(blk)
os.makedirs("/tank/mm", exist_ok=True)
for f in range(400):
    fn = f"/tank/mm/m{f:03d}"
    if not os.path.exists(fn):
        with open(fn, "wb") as fh:
            fh.write(os.urandom(4 << 20))
EOF
	zpool sync tank
	echo setup done
}

run() {
	secs=${1:?seconds}
	echo $ARCMAX >/sys/module/zfs/parameters/zfs_arc_max
	echo 1 >/proc/sys/kernel/panic_on_oops
	ulimit -n 1048576
	end=$(( $(date +%s) + secs ))
	pids=()
	python3 "$D/pinner.py" $end >$W/pinner.log 2>&1 & pids+=($!)
	python3 "$D/mmapper.py" $end >$W/mmapper.log 2>&1 & pids+=($!)
	for r in 1 2; do
		( while [ "$(date +%s)" -lt $end ]; do
			find /tank/big -type f -print0 | shuf -z -n 400 | xargs -0 cat >/dev/null 2>&1 || true
			find /tank/small -type f -print0 | shuf -z -n 4000 | xargs -0 cat >/dev/null 2>&1 || true
		done ) & pids+=($!)
	done
	( n=0; while [ "$(date +%s)" -lt $end ]; do
		d=/tank/churn/c$((n % 20)); mkdir -p $d
		for i in $(seq 1 500); do echo $i >$d/x$i; done
		for i in $(seq 1 500 | shuf -n 200); do mv $d/x$i $d/y$i 2>/dev/null || true; done
		find /tank/small -type f -name 'f1*' | head -20000 | xargs stat >/dev/null 2>&1 || true
		rm -rf $d; n=$((n+1))
	done ) & pids+=($!)
	( n=0; while [ "$(date +%s)" -lt $end ]; do
		zfs snapshot -r tank@s$n; n=$((n+1))
		[ $n -gt 6 ] && zfs destroy -r tank@s$((n-7)) || true
		sleep 30
	done ) & pids+=($!)
	( while [ "$(date +%s)" -lt $end ]; do
		python3 -c 'import time; b=bytearray(3<<30); [b.__setitem__(i,1) for i in range(0,len(b),4096)]; time.sleep(5)' || true
		sleep 20
	done ) & pids+=($!)
	( while [ "$(date +%s)" -lt $end ]; do
		{ date +%s; awk '/^(arc_prune|size|c |c_max|arc_meta_used|dnode_size|metadata_size|memory_throttle_count) /{print $1,$3}' /proc/spl/kstat/zfs/arcstats; } >>$W/arcstats.log
		dmesg --level=emerg,alert,crit,err,warn | grep -viE "taint|loading out-of-tree|license" >$W/dmesg_warn.txt || true
		sleep 60
	done ) & pids+=($!)
	wait "${pids[@]}" || true
	echo "run done $(date)"; dmesg --level=emerg,alert,crit,err,warn | grep -viE "taint|loading out-of-tree|license" | tail -20 || true
	awk '/^arc_prune /{print}' /proc/spl/kstat/zfs/arcstats
}

case $cmd in
setup) setup ;;
run) run "${2:?seconds}" ;;
*) echo "usage: $0 setup|run SECONDS" >&2; exit 1 ;;
esac
