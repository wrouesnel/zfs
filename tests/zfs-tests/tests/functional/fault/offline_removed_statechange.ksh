#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/fault/fault.cfg

#
# DESCRIPTION:
# Offlining a REMOVED device posts a statechange event (REMOVED -> OFFLINE).
#
# STRATEGY:
# 1. Create a mirror of a file and a scsi_debug device.
# 2. Simulate physical removal of the scsi_debug device; wait for REMOVED.
# 3. Clear the events and 'zpool offline' the removed device.
# 4. Verify the device is OFFLINE and a statechange event with
#    vdev_state OFFLINE and vdev_laststate REMOVED was posted for it.
#

verify_runnable "both"

if is_linux; then
	# one 512b scsi_debug device, larger than the file vdev
	load_scsi_debug $(($MINVDEVSIZE/1024/1024+32)) 1 1 1 '512b'
else
	log_unsupported "scsi debug module unsupported"
fi

function cleanup
{
	destroy_pool $TESTPOOL
	rm -f $filedev
	unload_scsi_debug
}

log_assert "Offlining a REMOVED device posts a REMOVED -> OFFLINE statechange"
log_onexit cleanup

filedev="$TEST_BASE_DIR/file-vdev-1"
removedev=$(get_debug_device)
log_must truncate -s $MINVDEVSIZE $filedev

log_must zpool create -f $TESTPOOL mirror $filedev $removedev
block_device_wait ${DEV_DSKDIR}/${removedev}
mntpnt=$(get_prop mountpoint /$TESTPOOL)

remove_disk $removedev
log_must mkfile 1m $mntpnt/file
sync_pool $TESTPOOL
log_must wait_vdev_state $TESTPOOL $removedev "REMOVED"
log_must zpool status -v $TESTPOOL

log_must zpool events -c
log_must zpool offline $TESTPOOL $removedev
log_must wait_vdev_state $TESTPOOL $removedev "OFFLINE"
log_must zpool status -v $TESTPOOL

# zpool events -v prints one paragraph per event
typeset found=""
for i in {1..10}; do
	found=$(zpool events -v $TESTPOOL | awk -v RS= \
	    '/class = "resource.fs.zfs.statechange"/ &&
	    /vdev_state = "OFFLINE"/ && /vdev_laststate = "REMOVED"/')
	[[ -n "$found" ]] && break
	sleep 1
done
if [[ -z "$found" ]]; then
	log_note "$(zpool events -v $TESTPOOL)"
	log_fail "no REMOVED -> OFFLINE statechange event for $removedev"
fi
log_note "$found"
log_must grep -q "vdev_path = \".*$removedev" <<<"$found"

log_pass "Offlining a REMOVED device posts a REMOVED -> OFFLINE statechange"
