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

#
# Copyright (c) 2026 by Will Rouesnel. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/replacement/replacement.cfg

#
# DESCRIPTION:
# A sequential resilver (rebuild) stops when its top-level vdev cannot
# be written, and stays in progress on disk.  Ensure that it resumes
# once the vdev can be opened again.
#
# STRATEGY:
# 1. Create a pool of a two-way mirror and a single disk, and write data.
# 2. Block scan progress and attach a third disk to the mirror with
#    "zpool attach -s".
# 3. Make every child of the mirror fail to open, reopen the pool, and
#    check that the mirror is unavailable.  Wait for the rebuild to stop.
# 4. Clear the injection, reopen and clear the pool, and unblock scan
#    progress.
# 5. Verify that the rebuild completes, that the mirror and its children
#    are online with no errors, and that a scrub finds no errors.
#

verify_runnable "global"

DEV1="$TEST_BASE_DIR/rbunavail1"
DEV2="$TEST_BASE_DIR/rbunavail2"
DEV3="$TEST_BASE_DIR/rbunavail3"
DEV4="$TEST_BASE_DIR/rbunavail4"

function cleanup
{
	log_must zinject -c all
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	log_must rm -f $DEV1 $DEV2 $DEV3 $DEV4
}
log_onexit cleanup

log_assert "A rebuild resumes after its top-level vdev was unavailable."

log_must truncate -s $VDEV_FILE_SIZE $DEV1 $DEV2 $DEV3 $DEV4
log_must zpool create -f -o ashift=12 $TESTPOOL1 mirror $DEV1 $DEV2
log_must zpool add -f $TESTPOOL1 $DEV4
log_must zfs create $TESTPOOL1/fs
mntpnt=$(get_prop mountpoint $TESTPOOL1/fs)
log_must file_write -o create -f $mntpnt/file -b 1048576 -c 64 -d R
sum=$(xxh128digest $mntpnt/file)
log_must sync_pool $TESTPOOL1

log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool attach -s $TESTPOOL1 $DEV1 $DEV3
log_must is_pool_resilvering $TESTPOOL1

# The rebuild thread checks every second whether it must stop.
for dev in $DEV1 $DEV2 $DEV3; do
	log_must zinject -d $dev -e nxio -T all $TESTPOOL1
done
log_must zpool reopen $TESTPOOL1
log_must check_vdev_state $TESTPOOL1 mirror-0 "UNAVAIL"
log_must sleep 5

log_must zinject -c all
log_must zpool reopen $TESTPOOL1
log_must zpool clear $TESTPOOL1
log_must check_vdev_state $TESTPOOL1 mirror-0 "ONLINE"
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0

if ! timeout 120 zpool wait -t resilver $TESTPOOL1; then
	log_note "$(zpool status $TESTPOOL1)"
	log_fail "The rebuild did not resume after mirror-0 came back"
fi
log_mustnot is_pool_resilvering $TESTPOOL1
log_must eval "zpool status $TESTPOOL1 | grep -q 'resilvered (mirror-0)'"
for dev in mirror-0 $DEV1 $DEV2 $DEV3 $DEV4; do
	log_must check_vdev_state $TESTPOOL1 $dev "ONLINE"
done

log_must zpool scrub -w $TESTPOOL1
log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
log_must eval "zpool status -v $TESTPOOL1 | grep -q 'scrub repaired 0B'"
log_must test "$(xxh128digest $mntpnt/file)" = "$sum"

log_pass "A rebuild resumes after its top-level vdev was unavailable."
