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
. $STF_SUITE/tests/functional/redundancy/redundancy.kshlib

#
# DESCRIPTION:
#	A scrub that heals a cleared vdev must not report the data which
#	the vdev's DTL says it is missing as checksum errors.
#
# STRATEGY:
#	For a mirror and a dRAID top-level vdev, each in a pool with a
#	second mirror top-level vdev:
#	1. Fault the first child and write while it is faulted.  For dRAID,
#	   replace it with distributed spare 0, then fault two more children
#	   and rebuild distributed spares 1 and 2 onto them sequentially.
#	   Their spare columns which map to the faulted child are written to
#	   spare 0 only, and the faulted child's DTL records that.
#	2. Start a sequential rebuild of the second mirror, hold it with
#	   zfs_scan_suspend_progress, and clear the faulted child.  The
#	   resilver the clear requests is dropped while a rebuild is active.
#	3. Let the rebuild finish and scrub.  The scrub covers the cleared
#	   child's DTL range and heals it.
#	4. Verify the scrub repaired data without reporting checksum errors,
#	   and that a second scrub finds nothing to repair.
#
# NOTES:
#	redundancy_draid_spare1 reaches the same scrub by a race: its
#	'zpool scrub' right after 'zpool clear' can be set up in the txg
#	in which the requested resilver was to start, which cancels the
#	resilver.
#

verify_runnable "global"

function cleanup
{
	restore_tunable SCAN_SUSPEND_PROGRESS
	restore_tunable REBUILD_SCRUB_ENABLED
	destroy_pool $TESTPOOL
	rm -rf $BASEDIR $TESTDIR
}

function cksum_errors # pool
{
	zpool status -p $1 | awk '!NF { v = 0 } v { e += $NF } /CKSUM$/ { v = 1 }
	    END { print e + 0 }'
}

function fill # count of 10M files
{
	typeset -i i=0
	while (( i < $1 )); do
		log_must dd if=/dev/urandom of=$TESTDIR/file.$RANDOM.$i \
		    bs=1024k count=10
		(( i += 1 ))
	done
	sync_pool $TESTPOOL
}

#
# $1 the top-level vdev: mirror or draid
#
function test_scrub_heal
{
	typeset type=$1
	typeset fault=$BASEDIR/vdev0
	typeset -i cksum

	log_must rm -rf $BASEDIR $TESTDIR
	log_must mkdir -p $BASEDIR
	log_must truncate -s $MINVDEVSIZE $BASEDIR/vdev{0..12} \
	    $BASEDIR/m{0..2}

	if [[ $type == "mirror" ]]; then
		log_must zpool create -f -O compression=off -m $TESTDIR \
		    $TESTPOOL mirror $BASEDIR/vdev0 $BASEDIR/vdev1 \
		    mirror $BASEDIR/m0 $BASEDIR/m1
		fill 10
		log_must zpool offline -f $TESTPOOL $fault
		fill 10
	else
		log_must zpool create -f -O compression=off -m $TESTDIR \
		    $TESTPOOL draid2:8d:13c:3s $BASEDIR/vdev{0..12} \
		    mirror $BASEDIR/m0 $BASEDIR/m1
		fill 100
		typeset -i i=0
		while (( i < 3 )); do
			log_must zpool offline -f $TESTPOOL $BASEDIR/vdev$i
			log_must zpool replace -w -s $TESTPOOL \
			    $BASEDIR/vdev$i draid2-0-$i
			(( i == 0 )) || log_must zpool detach $TESTPOOL \
			    $BASEDIR/vdev$i
			(( i += 1 ))
		done
	fi
	log_must zpool scrub -w $TESTPOOL
	log_must test "$(cksum_errors $TESTPOOL)" -eq 0

	# Clear the faulted child while a rebuild is active.
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	log_must zpool replace -s $TESTPOOL $BASEDIR/m1 $BASEDIR/m2
	log_must zpool clear $TESTPOOL $fault
	log_must check_vdev_state $TESTPOOL $fault "ONLINE"
	# Let spa_async_thread() take the resilver request.
	sync_all_pools true
	sync_all_pools true
	sync_all_pools true
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	log_must zpool wait -t resilver $TESTPOOL

	# Only the rebuild may have run; the cleared child is not healed yet.
	if zpool status $TESTPOOL | grep "scan:" | grep -v "(" | \
	    grep -q resilver; then
		log_fail "a resilver ran, the setup did not reach the scrub"
	fi

	log_must zpool scrub -w $TESTPOOL
	typeset status=$(zpool status -p $TESTPOOL)
	cksum=$(cksum_errors $TESTPOOL)
	log_note "$status"
	if check_pool_status $TESTPOOL "scan" "repaired 0B"; then
		log_fail "the scrub did not heal $fault"
	fi
	if (( cksum != 0 )); then
		log_fail "$type: the scrub that healed $fault reported" \
		    "$cksum checksum errors"
	fi

	log_must zpool clear $TESTPOOL
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "scan" "repaired 0B"
	log_must test "$(cksum_errors $TESTPOOL)" -eq 0
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"

	destroy_pool $TESTPOOL
}

log_assert "A scrub that heals a cleared vdev reports no checksum errors"
log_onexit cleanup

log_must save_tunable SCAN_SUSPEND_PROGRESS
log_must save_tunable REBUILD_SCRUB_ENABLED
log_must set_tunable32 REBUILD_SCRUB_ENABLED 0

test_scrub_heal mirror
test_scrub_heal draid

log_pass "A scrub that heals a cleared vdev reports no checksum errors"
