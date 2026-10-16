#! /bin/ksh -p
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
. $STF_SUITE/tests/functional/removal/removal.kshlib

#
# DESCRIPTION:
#
# "zpool remove" stops an initialize or a TRIM of the vdev it removes
# and leaves it active, so that it resumes if the removal is canceled.
# Ensure that it does resume after "zpool remove -s".
#
# STRATEGY:
#
# 1. Create a pool of two file vdevs and write some data.
# 2. Start initializing the second vdev, with its I/O slowed down so that
#    the initialize is still running in the next step.
# 3. Block removal progress, start removing the second vdev, and check
#    that the initialize is still reported as active.
# 4. Cancel the removal and remove the delay.
# 5. Verify that the initialize completes, that the vdev is online with no
#    errors, and that it is not being removed.
# 6. Repeat steps 2-5 with a rate-limited TRIM in place of the
#    initialize.
# 7. Verify the data and the pool with zdb.
#

verify_runnable "global"

DISK1="$TEST_BASE_DIR/rmcancel_init1"
DISK2="$TEST_BASE_DIR/rmcancel_init2"

function cleanup
{
	log_must zinject -c all
	log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 0
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	log_must rm -f $DISK1 $DISK2
}
log_onexit cleanup

# The line of a vdev in "zpool status -i" or "zpool status -t".
function vdev_progress # pool disk flag
{
	zpool status $3 $1 | awk -v d="$2" '$1 == d'
}

# Wait up to 120 seconds for a vdev's progress line to match a pattern.
function wait_progress # pool disk flag pattern
{
	typeset -i i=0
	while (( i < 120 )); do
		vdev_progress $1 $2 $3 | grep -q "$4" && return 0
		sleep 1
		(( i += 1 ))
	done
	log_note "$(zpool status $3 $1)"
	return 1
}

# Remove $DISK2 while the operation started by $1 runs on it, cancel the
# removal, and check that the operation completes.
function cancel_during # start-cmd flag active-pattern done-pattern
{
	typeset start="$1" flag=$2 active="$3" done="$4"

	log_must zinject -d $DISK2 -D 50:1 $TESTPOOL1
	log_must eval "$start"
	log_must wait_progress $TESTPOOL1 $DISK2 $flag "$active"

	log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 1
	log_must zpool remove $TESTPOOL1 $DISK2
	log_must is_pool_removing $TESTPOOL1
	log_must eval "vdev_progress $TESTPOOL1 $DISK2 $flag | grep -q removing"

	log_must zpool remove -s $TESTPOOL1
	log_must set_tunable32 REMOVAL_SUSPEND_PROGRESS 0
	log_must zinject -c all
	log_mustnot is_pool_removing $TESTPOOL1
	log_must eval "zpool status $TESTPOOL1 | grep -q 'Removal of .* canceled'"

	# The operation must pick up where it stopped and finish.
	log_must eval "vdev_progress $TESTPOOL1 $DISK2 $flag | grep -q '$active'"
	if ! wait_progress $TESTPOOL1 $DISK2 $flag "$done"; then
		log_fail "'$start' did not resume after the removal was" \
		    "canceled: $(vdev_progress $TESTPOOL1 $DISK2 $flag)"
	fi
	log_must check_vdev_state $TESTPOOL1 $DISK2 "ONLINE"
	log_must eval "vdev_progress $TESTPOOL1 $DISK2 $flag | \
	    grep -E 'ONLINE +0 +0 +0'"
	log_mustnot eval "vdev_progress $TESTPOOL1 $DISK2 $flag | \
	    grep -q removing"
}

log_must truncate -s 1G $DISK1 $DISK2
log_must zpool create -f -o ashift=12 $TESTPOOL1 $DISK1 $DISK2
log_must zfs create $TESTPOOL1/fs
mntpnt=$(get_prop mountpoint $TESTPOOL1/fs)
log_must file_write -o create -f $mntpnt/file -b 1048576 -c 128 -d R
sum=$(xxh128digest $mntpnt/file)
log_must sync_pool $TESTPOOL1

cancel_during "zpool initialize $TESTPOOL1 $DISK2" -i \
    "% initialized, started at" "100% initialized, completed at"

cancel_during "zpool trim -r 64M $TESTPOOL1 $DISK2" -t \
    "% trimmed, started at" "100% trimmed, completed at"

log_must test "$(xxh128digest $mntpnt/file)" = "$sum"
log_must zpool export $TESTPOOL1
log_must zdb -e -p $TEST_BASE_DIR $TESTPOOL1
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL1
log_must test "$(xxh128digest $mntpnt/file)" = "$sum"

log_pass "An initialize or TRIM resumes after a removal is canceled."
