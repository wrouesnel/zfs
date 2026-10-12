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
. $STF_SUITE/tests/functional/replacement/replacement.cfg

#
# DESCRIPTION:
# A healing resilver ends when the devices it was resilvering are
# detached, and a deferred resilver then starts.
#
# STRATEGY:
# 1. Create a mirror pool with some data and suspend scan progress.
# 2. Attach a device, wait for the resilver, detach the device.  The
#    resilver must end and a sequential attach must be allowed.
# 3. Replace a device and cancel the replace by detaching the new
#    device.  The resilver must end.
# 4. Attach a device, then attach a second one, whose resilver is
#    deferred.  Detach the first device.  The resilver must restart for
#    the second device and complete.
#

verify_runnable "global"

function cleanup
{
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS $ORIG_SCAN_SUSPEND_PROGRESS
	log_must set_tunable32 RESILVER_MIN_TIME_MS $ORIG_RESILVER_MIN_TIME
	log_must set_tunable32 RESILVER_DEFER_PERCENT $ORIG_DEFER_PERCENT
	destroy_pool $TESTPOOL1
	rm -f ${VDEV_FILES[@]} $SPARE_VDEV_FILE $SPARE_VDEV_FILE2
}

# Wait up to 30 seconds for the resilver to end.
function wait_resilver_gone
{
	typeset -i i=0
	while is_pool_resilvering $TESTPOOL1 && (( i < 30 )); do
		sleep 1
		(( i += 1 ))
	done
	log_mustnot is_pool_resilvering $TESTPOOL1
}

function wait_resilvering
{
	typeset -i i=0
	while ! is_pool_resilvering $TESTPOOL1 && (( i < 30 )); do
		sleep 1
		(( i += 1 ))
	done
	log_must is_pool_resilvering $TESTPOOL1
}

log_assert "A resilver ends when its target devices are detached"

ORIG_SCAN_SUSPEND_PROGRESS=$(get_tunable SCAN_SUSPEND_PROGRESS)
ORIG_RESILVER_MIN_TIME=$(get_tunable RESILVER_MIN_TIME_MS)
ORIG_DEFER_PERCENT=$(get_tunable RESILVER_DEFER_PERCENT)

log_onexit cleanup

log_must truncate -s $VDEV_FILE_SIZE ${VDEV_FILES[@]} \
    $SPARE_VDEV_FILE $SPARE_VDEV_FILE2
log_must zpool create -f $TESTPOOL1 mirror ${VDEV_FILES[0]} ${VDEV_FILES[1]}
log_must zfs create $TESTPOOL1/$TESTFS
mntpnt=$(get_prop mountpoint $TESTPOOL1/$TESTFS)
log_must dd if=/dev/urandom of=$mntpnt/file bs=1M count=32
sync_pool $TESTPOOL1

log_must set_tunable32 RESILVER_MIN_TIME_MS 50
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1

# Attach, then detach the device being resilvered.
log_must zpool attach $TESTPOOL1 ${VDEV_FILES[0]} $SPARE_VDEV_FILE
wait_resilvering
log_must zpool detach $TESTPOOL1 $SPARE_VDEV_FILE
wait_resilver_gone
log_must zpool attach -s $TESTPOOL1 ${VDEV_FILES[0]} $SPARE_VDEV_FILE
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver $TESTPOOL1
log_must zpool detach $TESTPOOL1 $SPARE_VDEV_FILE
log_must zpool wait $TESTPOOL1
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1

# Cancel a replace by detaching the new device.
log_must zpool replace $TESTPOOL1 ${VDEV_FILES[1]} $SPARE_VDEV_FILE
wait_resilvering
log_must zpool detach $TESTPOOL1 $SPARE_VDEV_FILE
wait_resilver_gone
log_must check_state $TESTPOOL1 ${VDEV_FILES[1]} "ONLINE"

# Detach the device being resilvered while another one is deferred.
log_must set_tunable32 RESILVER_DEFER_PERCENT 0
log_must zpool attach $TESTPOOL1 ${VDEV_FILES[0]} $SPARE_VDEV_FILE
wait_resilvering
log_must zpool attach $TESTPOOL1 ${VDEV_FILES[0]} $SPARE_VDEV_FILE2
log_must eval "zpool status -v $TESTPOOL1 | grep -q 'awaiting resilver'"
log_must zpool detach $TESTPOOL1 $SPARE_VDEV_FILE
typeset -i i=0
while zpool status -v $TESTPOOL1 | grep -q 'awaiting resilver' && \
    (( i < 30 )); do
	sleep 1
	(( i += 1 ))
done
log_mustnot eval "zpool status -v $TESTPOOL1 | grep -q 'awaiting resilver'"
# The deferred resilver is started by the async thread.
wait_resilvering
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver $TESTPOOL1
log_must check_state $TESTPOOL1 $SPARE_VDEV_FILE2 "ONLINE"
log_must zpool scrub -w $TESTPOOL1
log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
log_must eval "zpool status -v $TESTPOOL1 | grep -q 'scan: scrub repaired 0B'"

log_pass "A resilver ends when its target devices are detached"
