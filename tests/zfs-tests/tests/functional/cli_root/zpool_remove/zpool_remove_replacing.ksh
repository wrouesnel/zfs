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

#
# DESCRIPTION:
# While a device in a mirror is being replaced, or a hot spare is in use
# in a mirror, 'zpool remove' of a top-level vdev must fail saying so, not
# with "all top-level vdevs must have the same sector size and not be
# raidz", and must succeed once the replacement is done.
#
# STRATEGY:
# 1. Create a pool of a mirror, a single-disk vdev and a spare.
# 2. Replace a mirror disk with the spare: removing the single-disk vdev
#    must fail with the spare message; detach the spare.
# 3. Suspend scans and replace the mirror disk with another disk:
#    removing the single-disk vdev must fail with the same message.
# 4. Let the resilver finish: the removal must succeed.
#

verify_runnable "global"

function cleanup
{
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	rm -f $TEST_BASE_DIR/remove_rs.*
}

function remove_must_fail_busy # <vdev>
{
	typeset out

	out=$(zpool remove $TESTPOOL $1 2>&1) &&
	    log_fail "zpool remove $1 succeeded: $out"
	log_note "zpool remove $1: $out"
	echo "$out" | grep -q "same sector size" &&
	    log_fail "zpool remove $1 blamed the sector size or raidz: $out"
	echo "$out" | grep -q "being replaced or a hot spare is in use" ||
	    log_fail "zpool remove $1 didn't name the replacement: $out"
}

log_assert "'zpool remove' names a replacement or a spare in use in a mirror"
log_onexit cleanup

typeset d=$TEST_BASE_DIR/remove_rs
for i in 0 1 2 3 4; do
	log_must truncate -s $MINVDEVSIZE $d.$i
done

log_must zpool create $TESTPOOL mirror $d.0 $d.1
log_must zpool add -f $TESTPOOL $d.2 spare $d.3
log_must dd if=/dev/urandom of=/$TESTPOOL/file bs=1M count=32
sync_pool $TESTPOOL

# A hot spare in use in the mirror
log_must zpool replace $TESTPOOL $d.1 $d.3
log_must zpool wait -t resilver $TESTPOOL
log_must eval "zpool status -v $TESTPOOL"
remove_must_fail_busy $d.2
log_must zpool detach $TESTPOOL $d.3

# A replacement in progress in the mirror
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool replace $TESTPOOL $d.1 $d.4
log_must eval "zpool status -v $TESTPOOL"
remove_must_fail_busy $d.2

# Once the replacement is done, the removal goes ahead
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver $TESTPOOL
log_must zpool remove $TESTPOOL $d.2
log_must zpool wait -t remove $TESTPOOL
log_must eval "zpool status -v $TESTPOOL"
log_must check_pool_status $TESTPOOL state ONLINE

log_pass "'zpool remove' names a replacement or a spare in use in a mirror"
