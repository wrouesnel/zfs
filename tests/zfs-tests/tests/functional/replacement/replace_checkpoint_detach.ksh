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
# When a resilver completes, the replaced disk is detached.  A disk
# can't be detached while the pool has a checkpoint, and a healing
# resilver can't clear the DTLs then (it skips blocks that only the
# checkpoint references), so a replacement that completes while the
# pool has a checkpoint keeps both disks.  Ensure that the replaced disk
# is detached once the checkpoint is discarded, after a sequential and
# after a healing resilver.
#
# STRATEGY:
# 1. Create a mirror pool and write data.
# 2. Block scan progress and replace a disk ("zpool replace -s", then
#    "zpool replace").
# 3. Checkpoint the pool and unblock scan progress.
# 4. Wait for the resilver to complete once (and for the scrub that
#    follows a sequential resilver).  Check that both disks are still in
#    the pool.
# 5. Discard the checkpoint.
# 6. Verify that the replaced disk is detached within a minute, that the
#    mirror and the new disk are online, that a scrub finds no errors,
#    and that the data is intact.
#

verify_runnable "global"

DEV1="$TEST_BASE_DIR/repckpt1"
DEV2="$TEST_BASE_DIR/repckpt2"
DEV3="$TEST_BASE_DIR/repckpt3"

function cleanup
{
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	log_must rm -f $DEV1 $DEV2 $DEV3
}
log_onexit cleanup

# Wait up to 60 seconds for a command to succeed.
function wait_until # command...
{
	typeset -i i=0
	while ! "$@"; do
		(( i += 1 ))
		(( i > 60 )) && return 1
		sleep 1
	done
	return 0
}

function not_replacing # pool
{
	! is_pool_replacing $1
}

function replace_checkpoint_discard # replace-flags
{
	typeset flags=$1

	log_must truncate -s 512M $DEV1 $DEV2 $DEV3
	log_must zpool create -f -o ashift=12 $TESTPOOL1 mirror $DEV1 $DEV2
	log_must zfs create $TESTPOOL1/fs
	typeset mntpnt=$(get_prop mountpoint $TESTPOOL1/fs)
	log_must file_write -o create -f $mntpnt/file -b 1048576 -c 64 -d R
	typeset sum=$(xxh128digest $mntpnt/file)
	log_must sync_pool $TESTPOOL1

	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	log_must zpool replace $flags $TESTPOOL1 $DEV2 $DEV3
	log_must zpool checkpoint $TESTPOOL1
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	if [[ -n "$flags" ]]; then
		log_must zpool wait -t resilver,scrub $TESTPOOL1
		log_must eval "zpool status $TESTPOOL1 | \
		    grep -q 'resilvered (mirror-0)'"
	else
		# Don't wait for "no resilver": with the checkpoint, a
		# healing resilver may start again when it completes.
		log_must wait_until eval "zpool status $TESTPOOL1 | \
		    grep -q 'scan: resilvered'"
	fi

	# The checkpoint keeps the replaced disk in the pool.
	log_must is_pool_replacing $TESTPOOL1

	log_must zpool checkpoint -d -w $TESTPOOL1

	if ! wait_until not_replacing $TESTPOOL1; then
		log_note "$(zpool status $TESTPOOL1)"
		log_fail "$DEV2 was not detached after the checkpoint was" \
		    "discarded (zpool replace $flags)"
	fi
	log_must zpool wait -t resilver $TESTPOOL1
	log_mustnot eval "zpool status -P $TESTPOOL1 | grep -q '$DEV2'"
	log_must check_vdev_state $TESTPOOL1 mirror-0 "ONLINE"
	log_must check_vdev_state $TESTPOOL1 $DEV1 "ONLINE"
	log_must check_vdev_state $TESTPOOL1 $DEV3 "ONLINE"

	log_must zpool scrub -w $TESTPOOL1
	log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
	log_must eval "zpool status $TESTPOOL1 | grep -q 'scrub repaired 0B'"
	log_must test "$(xxh128digest $mntpnt/file)" = "$sum"

	log_must destroy_pool $TESTPOOL1
	log_must rm -f $DEV1 $DEV2 $DEV3
}

log_assert "A replaced disk is detached after the checkpoint is discarded."

replace_checkpoint_discard "-s"
replace_checkpoint_discard ""

log_pass "A replaced disk is detached after the checkpoint is discarded."
