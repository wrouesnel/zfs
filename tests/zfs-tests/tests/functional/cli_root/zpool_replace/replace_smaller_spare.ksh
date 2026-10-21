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
#	A mirror stays usable when it is reopened while a hot spare that is
#	smaller than the faulted device it replaced is in use.
#
# STRATEGY:
#	1. Create a mirror of two 1G file vdevs with a hot spare 8M smaller
#	   (still above the mirror's metaslab-rounded minimum size), write a
#	   file, and export and import the pool so the minimum size is
#	   rounded to a metaslab
#	2. Fault one side of the mirror and replace it with the spare
#	3. Reopen the pool ('zpool reopen', which 'zpool scrub' also does)
#	4. Verify the mirror is DEGRADED, not UNAVAIL ("cannot open"), the
#	   pool is DEGRADED and the file is still readable
#	5. Repeat 3-4 with 'zpool scrub'
#	6. Detach the faulted device; verify the pool is ONLINE
#

verify_runnable "global"

function cleanup
{
	if poolexists $TESTPOOL1; then
		zpool clear $TESTPOOL1
		destroy_pool $TESTPOOL1
	fi
	rm -f $disk1 $disk2 $spare
}

function check_degraded # step
{
	typeset step=$1
	typeset mstate=$(zpool status $TESTPOOL1 | \
	    awk '$1 ~ /^mirror-0$/ {print $2}')
	typeset pstate=$(get_pool_prop health $TESTPOOL1)

	if [[ $mstate != "DEGRADED" || $pstate != "DEGRADED" ]]; then
		zpool status $TESTPOOL1
		log_fail "after $step: mirror-0 is $mstate, pool is $pstate" \
		    "(expected DEGRADED)"
	fi
	log_must eval "cat $mntpnt/file > /dev/null"
	log_note "after $step: mirror-0 and the pool are DEGRADED"
}

log_assert "A mirror using a smaller hot spare survives a reopen."
log_onexit cleanup

disk1=$TEST_BASE_DIR/disk1
disk2=$TEST_BASE_DIR/disk2
spare=$TEST_BASE_DIR/spare
log_must truncate -s 1G $disk1 $disk2
log_must truncate -s $((1024 - 8))M $spare

log_must zpool create -f -o failmode=continue $TESTPOOL1 \
    mirror $disk1 $disk2 spare $spare
mntpnt=$(get_prop mountpoint $TESTPOOL1)
log_must dd if=/dev/urandom of=$mntpnt/file bs=1M count=16
log_must zpool export $TESTPOOL1
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL1

log_must zpool offline -f $TESTPOOL1 $disk2
log_must zpool replace $TESTPOOL1 $disk2 $spare
log_must zpool wait -t resilver $TESTPOOL1
check_degraded "replacing with the spare"

log_must zpool reopen $TESTPOOL1
check_degraded "zpool reopen"

log_must zpool scrub -w $TESTPOOL1
check_degraded "zpool scrub"

log_must zpool detach $TESTPOOL1 $disk2
log_must check_state $TESTPOOL1 "" "ONLINE"
log_must eval "cat $mntpnt/file > /dev/null"

log_pass "A mirror using a smaller hot spare survives a reopen."
