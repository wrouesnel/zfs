#!/usr/bin/env bash
# Can GRUB's ZFS reader (grub-fstest, same grub-core/fs/zfs/zfs.c as the
# boot loader) read files written while the only vdev was DEGRADED?
# Pool created with compatibility=grub2 so GRUB accepts its features.
#
# Usage (root, test VM only, with grub-common installed): grub.sh
D=$(cd "$(dirname "$0")" && pwd)
. "$D/lib.sh"

cleanup
mkvdevs 1
zpool create -f -o ashift=12 -o compatibility=grub2 "$P" "$W/d0"
zfs create "$P/fs"
log "grub-fstest $(grub-fstest --version 2>&1 | head -1)"

# file sizes: 1 MB = 8 L0 + 1 small L1; 200 MB = 1600 L0, 2 L1, 1 L2
write() { dd if=/dev/urandom of="/$P/fs/$1" bs=1M count="$2" status=none; }
write h-1m 1; write h-200m 200
zpool sync "$P"
degrade_quick "$W/d0"
write g-1m 1; write g-200m 200
zpool sync "$P"
# multi-member gang blocks (as 2.2 wrote them: up to 3 members each)
echo 4097 >/sys/module/zfs/parameters/metaslab_force_ganging
echo 100 >/sys/module/zfs/parameters/metaslab_force_ganging_pct
write f-200m 200
zpool sync "$P"
echo 16777217 >/sys/module/zfs/parameters/metaslab_force_ganging
echo 3 >/sys/module/zfs/parameters/metaslab_force_ganging_pct
obj=$(stat -c %i "/$P/fs/f-200m")
dva=$(zdb -ddddd "$P/fs" "$obj" | awk '$2 == "L1" && !n++ { print $3 }')
echo "f-200m first L1 $dva, gang header members:"
zdb -R "$P" "${dva%:*}:200:g" 2>&1 | { grep -v "Found vdev" || true; } | sed -n 1,4p
for f in h-1m h-200m g-1m g-200m f-200m; do
	echo "$f: $(gangcount "$f")"
	cp "/$P/fs/$f" "$W/$f.ref"
done
zpool export "$P"
head -c 1048576 /dev/urandom >"$W/wrong.ref"
if grub-fstest "$W/d0" cmp "(loop0)/fs@/g-1m" "$W/wrong.ref" >/dev/null 2>&1
then echo "negative control: cmp did NOT detect a mismatch"
else echo "negative control: cmp detects a mismatch (OK)"; fi
for f in h-1m h-200m g-1m g-200m f-200m; do
	if out=$(grub-fstest "$W/d0" cmp "(loop0)/fs@/$f" "$W/$f.ref" 2>&1); then
		echo "grub-fstest cmp $f: OK"
	else
		echo "grub-fstest cmp $f: FAILED: $(echo "$out" | tail -2 | tr '\n' ' ')"
	fi
done
zpool import -d "$W" "$P"
rm -f "$W"/*.ref
cleanup
