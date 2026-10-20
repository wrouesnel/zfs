#!/bin/ksh
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
# Description:
# Setting metaslab_force_ganging below the pool's minimum allocation
# size must not fail allocations of blocks that are too small to be
# ganged (or of gang headers), which suspends the pool.
#
# Strategy:
# 1. For ashift=9 with an encrypted dataset, and ashift=12 without:
# 2. Create the pool, set metaslab_force_ganging to 1 and
#    metaslab_force_ganging_pct to 50.
# 3. Create files and sync the pool.
# 4. Verify the pool is not suspended, blocks were ganged, and the
#    files are still there after an export and import.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/gang_blocks/gang_blocks.kshlib

VDEV=$TEST_BASE_DIR/force-small-vdev
KEYFILE=$TEST_BASE_DIR/force-small-key

function cleanup
{
	set_tunable64 METASLAB_FORCE_GANGING 16777217
	set_tunable32 METASLAB_FORCE_GANGING_PCT 0
	destroy_pool $TESTPOOL
	rm -f $VDEV $KEYFILE
}

log_assert "Forced ganging below the minimum allocation size doesn't" \
	"fail allocations"
log_onexit cleanup

log_must eval "dd if=/dev/urandom of=$KEYFILE bs=32 count=1 2>/dev/null"

for ashift in 9 12; do
	log_must truncate -s $MINVDEVSIZE $VDEV
	log_must zpool create -f -o ashift=$ashift $TESTPOOL $VDEV
	if [[ $ashift == 9 ]]; then
		log_must zfs create -o encryption=aes-256-gcm -o keyformat=raw \
		    -o keylocation=file://$KEYFILE $TESTPOOL/$TESTFS
	else
		log_must zfs create $TESTPOOL/$TESTFS
	fi
	mntpnt=$(get_prop mountpoint $TESTPOOL/$TESTFS)

	typeset -i gangs=$(kstat zio_stats.gang_writes)
	log_must set_tunable64 METASLAB_FORCE_GANGING 1
	log_must set_tunable32 METASLAB_FORCE_GANGING_PCT 50

	for i in $(seq 1 100); do
		echo $i > $mntpnt/file$i || break
	done
	log_must dd if=/dev/urandom of=$mntpnt/big bs=128k count=8
	typeset cksum=$(xxh128digest $mntpnt/big)

	# A suspended pool would make 'zpool sync' hang: sync in the
	# background and watch the pool's state.
	zpool sync $TESTPOOL &
	typeset syncpid=$!
	typeset -i n=0
	while kill -0 $syncpid 2>/dev/null && (( n < 120 )); do
		[[ "$(zpool list -H -o health $TESTPOOL)" == "SUSPENDED" ]] && \
		    break
		sleep 0.5
		(( n += 1 ))
	done
	typeset health=$(zpool list -H -o health $TESTPOOL)
	log_must set_tunable64 METASLAB_FORCE_GANGING 16777217
	log_must set_tunable32 METASLAB_FORCE_GANGING_PCT 0
	if [[ "$health" != "ONLINE" ]]; then
		zpool status -v $TESTPOOL
		kstat dbgmsg | grep "allocation failure" | tail -3
		log_fail "ashift=$ashift: pool is $health with forced ganging"
	fi
	log_must wait $syncpid
	typeset -i newgangs=$(kstat zio_stats.gang_writes)
	log_note "ashift=$ashift: $((newgangs - gangs)) gang writes"
	(( newgangs > gangs )) || log_fail "ashift=$ashift: nothing was ganged"

	log_must zpool export $TESTPOOL
	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
	[[ $ashift == 9 ]] && log_must zfs load-key $TESTPOOL/$TESTFS
	log_must zfs mount -a
	log_must test "$(cat $mntpnt/file100)" == "100"
	log_must test "$(xxh128digest $mntpnt/big)" == "$cksum"
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must zpool destroy $TESTPOOL
	log_must rm -f $VDEV
done

log_pass "Forced ganging below the minimum allocation size doesn't" \
	"fail allocations"
