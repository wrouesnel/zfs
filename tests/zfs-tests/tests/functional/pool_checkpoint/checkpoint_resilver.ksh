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

. $STF_SUITE/tests/functional/pool_checkpoint/pool_checkpoint.kshlib

#
# DESCRIPTION:
#	A resilver that completes while the pool has a checkpoint cannot
#	clear the new device's DTL, since it skips blocks that only the
#	checkpoint references.  It must not restart over and over because
#	of that DTL, and the device must be resilvered once the checkpoint
#	is discarded.
#
# STRATEGY:
#	1. Create a single-disk pool and write some data.
#	2. Attach a second disk with the resilver held, take a
#	   checkpoint, write more data, and let the resilver run.
#	3. Verify the resilver ran once and did not restart.
#	4. Discard the checkpoint and verify that the new disk is
#	   resilvered: the original disk can then be detached, and the
#	   data read back from the new disk alone.
#

verify_runnable "global"

CKPOOL=testpool_ckresilver
DISK1=$TEST_BASE_DIR/ckresilver_disk1
DISK2=$TEST_BASE_DIR/ckresilver_disk2

function test_cleanup
{
	restore_tunable SCAN_SUSPEND_PROGRESS
	poolexists $CKPOOL && destroy_pool $CKPOOL
	log_must rm -f $DISK1 $DISK2
}

function scan_setups
{
	zpool history -i $CKPOOL | grep -c "scan setup func=2"
}

log_onexit test_cleanup
log_must save_tunable SCAN_SUSPEND_PROGRESS

log_must truncate -s $MINVDEVSIZE $DISK1 $DISK2
log_must zpool create -o cachefile=none -O compression=off $CKPOOL $DISK1
log_must dd if=/dev/urandom of=/$CKPOOL/before bs=1M count=64
sync_pool $CKPOOL

log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool attach $CKPOOL $DISK1 $DISK2
log_must zpool checkpoint $CKPOOL
log_must dd if=/dev/urandom of=/$CKPOOL/after bs=1M count=32
sync_pool $CKPOOL
typeset sum_before=$(xxh128digest /$CKPOOL/before)
typeset sum_after=$(xxh128digest /$CKPOOL/after)
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0

log_must zpool wait -t resilver $CKPOOL
log_must sleep 15
log_must eval "zpool status -v $CKPOOL"
typeset setups=$(scan_setups)
log_note "resilvers started with the checkpoint present: $setups"
if [[ $setups -ne 1 ]]; then
	zpool history -i $CKPOOL | grep "scan " | tail -20
	log_fail "resilver started $setups times with a checkpoint, expected 1"
fi
log_must is_pool_resilvered $CKPOOL

#
# With the checkpoint gone the skipped blocks can be resilvered.  Until
# they are, the new disk's DTL makes the original disk required.
#
log_must zpool checkpoint -d -w $CKPOOL
typeset -i i=0
while ! zpool detach $CKPOOL $DISK1 2>/dev/null; do
	if ((i++ >= 60)); then
		log_must eval "zpool status -v $CKPOOL"
		zpool history -i $CKPOOL | grep "scan \|checkpoint" | tail -20
		log_fail "$DISK1 still required 60s after the checkpoint discard"
	fi
	sleep 1
done
log_must eval "zpool status -v $CKPOOL"
log_note "resilvers started in all: $(scan_setups)"

log_must zpool export $CKPOOL
log_must zpool import -d $DISK2 $CKPOOL
log_must test "$(xxh128digest /$CKPOOL/before)" = "$sum_before"
log_must test "$(xxh128digest /$CKPOOL/after)" = "$sum_after"
log_must zpool scrub -w $CKPOOL
log_must eval "zpool status -v $CKPOOL"
log_must check_pool_status $CKPOOL "errors" "No known data errors"
log_must check_pool_status $CKPOOL "scan" "with 0 errors"

log_pass "A checkpoint does not make a resilver restart forever."
