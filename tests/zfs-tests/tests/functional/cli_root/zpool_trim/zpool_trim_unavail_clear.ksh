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
. $STF_SUITE/tests/functional/cli_root/zpool_trim/zpool_trim.kshlib

#
# DESCRIPTION:
# A TRIM stops when its device can't be written, and stays active
# unless the device was faulted.  Ensure that it resumes when the device
# comes back through "zpool clear", not only through "zpool online".
#
# STRATEGY:
# 1. Create a mirror of two file vdevs and write some data.
# 2. Start a rate-limited TRIM of the second vdev, so that it is still
#    running in the next step.
# 3. Make the vdev fail to open and reopen the pool: the vdev can't be
#    opened and the TRIM is still reported as active.
# 4. Clear the injection and run "zpool clear".
# 5. Verify that the TRIM completes, that the vdev is online with
#    no errors, and that a scrub finds no errors.
#

verify_runnable "global"

DEV1="$TEST_BASE_DIR/trimclr1"
DEV2="$TEST_BASE_DIR/trimclr2"

function cleanup_unavail
{
	log_must zinject -c all
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	log_must rm -f $DEV1 $DEV2
}
log_onexit cleanup_unavail

# The line of a vdev in "zpool status -t".
function vdev_line # pool disk
{
	zpool status -t $1 | awk -v d="$2" '$1 == d'
}

log_must truncate -s 1G $DEV1 $DEV2
log_must zpool create -f -o ashift=12 $TESTPOOL1 mirror $DEV1 $DEV2
log_must zfs create $TESTPOOL1/fs
mntpnt=$(get_prop mountpoint $TESTPOOL1/fs)
log_must file_write -o create -f $mntpnt/file -b 1048576 -c 32 -d R
log_must sync_pool $TESTPOOL1

log_must zpool trim -r 64M $TESTPOOL1 $DEV2
log_must eval "vdev_line $TESTPOOL1 $DEV2 | grep -q '% trimmed, started'"
log_must zinject -c all

log_must zinject -d $DEV2 -e nxio -T all $TESTPOOL1
log_must zpool reopen $TESTPOOL1
log_must check_vdev_state $TESTPOOL1 $DEV2 "UNAVAIL"
log_must eval "vdev_line $TESTPOOL1 $DEV2 | grep -q '% trimmed, started'"
# The TRIM thread sees that the device is gone and exits.
log_must sleep 5

log_must zinject -c all
log_must zpool clear $TESTPOOL1
log_must check_vdev_state $TESTPOOL1 $DEV2 "ONLINE"

if ! timeout 120 zpool wait -t trim $TESTPOOL1; then
	log_note "$(zpool status -t $TESTPOOL1)"
	log_fail "The TRIM did not resume after zpool clear"
fi
log_must eval "vdev_line $TESTPOOL1 $DEV2 | \
    grep -q '100% trimmed, completed at'"
log_must eval "vdev_line $TESTPOOL1 $DEV2 | grep -qE 'ONLINE +0 +0 +0'"

log_must zpool scrub -w $TESTPOOL1
log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
log_must eval "zpool status $TESTPOOL1 | grep -q 'scrub repaired 0B'"

log_pass "A TRIM resumes after its device comes back through clear."
