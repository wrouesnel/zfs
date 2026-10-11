#!/usr/bin/env bash
# Reproducer for openzfs/zfs#19197: on a pool whose top-level vdev is a single
# leaf disk, once that vdev is DEGRADED every single-copy allocation larger
# than spa_min_alloc becomes a gang block, until `zpool clear`.
#
# Usage (root, test VM only):  repro.sh [zed|quick] [file|disk:/dev/vdX]
#   zed   - degrade the vdev the way the reporter's was: injected read
#           checksum errors until ZED degrades it (aux_state err_exceeded)
#   quick - zinject -A degrade
# Prints, per level, ganged/total block pointers of a $MB MB urandom file
# written while DEGRADED, after export/import, and after `zpool clear`.
# Exit status 1 = bug reproduced (L0 blocks ganged while DEGRADED).
D=$(cd "$(dirname "$0")" && pwd)
. "$D/lib.sh"

how=${1:-zed}
dev=${2:-file}
cleanup
if [ "$dev" = file ]; then
	mkvdevs 1; V=$W/d0
else
	V=${dev#disk:}; wipefs -aq "$V"
fi
mkpool "$V"
V=$(zpool status -P "$P" | awk '$1 ~ /^\// { print $1; exit }')  # vdb -> vdb1
log "pool: single leaf vdev $V, copies=1, ashift=12, compression=off"
zfs get -H -o property,value copies,recordsize,redundant_metadata "$P/fs" |
    tr '\n' ' '; echo

writefile healthy
log "healthy write:   $(gangcount healthy)"

if [ "$how" = zed ]; then degrade_zed "$V"; else degrade_quick "$V"; fi
log "vdev state: $(vstate "$V")"
reimport
log "after export/import: $(vstate "$V") / label: $(persisted "$V")"

s0=$(stats)
writefile degraded
log "degraded write:  $(gangcount degraded)"
log "before: $s0"
log "after:  $(stats)"

zpool clear "$P"
log "after zpool clear: $(vstate "$V")"
writefile cleared
log "after clear:     $(gangcount cleared)"

g=$(gangcount degraded | awk '{ split($2, a, "/"); print a[1] }')
cleanup
if [ "$g" -gt 0 ]; then
	echo "RESULT: REPRODUCED ($g L0 blocks ganged while DEGRADED)"
	exit 1
fi
echo "RESULT: NOT REPRODUCED"
