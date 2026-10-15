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
# DESCRIPTION:
#	Importing a pool whose best uberblock has a valid MMP config but
#	mmp_delay 0 must run the activity check.  Hosts without the fix
#	for this could sync such an uberblock as the first txg after they
#	import a multihost pool, while they are using it.
#
# STRATEGY:
#	1. Decompress a pool image written by hostid $HOSTID1 with
#	   multihost=on, copied while imported (labels say ACTIVE), whose
#	   uberblocks all have a valid MMP config and mmp_delay 0
#	   (blockfiles/mmp_zero_delay.dat.bz2).
#	2. Verify with zdb that the best uberblock is such an uberblock.
#	3. Import it with -f as hostid $HOSTID2 and verify that the
#	   activity check ran (mmp_result: 0), rather than being skipped
#	   as if multihost were off (mmp_result: 3).
#	4. Verify that the pool was imported.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/mmp/mmp.cfg
. $STF_SUITE/tests/functional/mmp/mmp.kshlib

verify_runnable "global"

POOL_NAME=mmp_zero_delay
POOL_FILE=mmp_zero_delay.dat

function cleanup
{
	poolexists $POOL_NAME && destroy_pool $POOL_NAME
	log_must rm -f $MMP_DIR/$POOL_FILE
	log_must mmp_clear_hostid
}

log_assert "a valid MMP config with mmp_delay 0 requires an activity check"
log_onexit cleanup

log_must mkdir -p $MMP_DIR
log_must eval "bzcat $STF_SUITE/tests/functional/mmp/blockfiles/$POOL_FILE.bz2 \
    > $MMP_DIR/$POOL_FILE"

# Every uberblock, so also the best one, has an MMP config and mmp_delay 0.
log_must eval "zdb -luuuu $MMP_DIR/$POOL_FILE > $TEST_BASE_DIR/zdb.$$"
counts=$(awk '/Uberblock\[/ && !/invalid/ { n++ }
    /mmp_delay =/ && $3 != 0 { delay++ } /mmp_valid =/ && $3 != 7 { cfg++ }
    END { print n + 0, delay + 0, cfg + 0 }' $TEST_BASE_DIR/zdb.$$)
rm -f $TEST_BASE_DIR/zdb.$$
log_note "uberblocks, with mmp_delay != 0, without an MMP config: $counts"
[[ "$counts" == +([0-9])" 0 0" && "${counts%% *}" -gt 0 ]] || \
    log_fail "image must only hold uberblocks with mmp_delay 0 and" \
    "a valid MMP config: $counts"

log_must mmp_clear_hostid
log_must mmp_set_hostid $HOSTID2

RESULT=$(ZFS_LOAD_INFO_DEBUG=1 zpool import -f -d $MMP_DIR $POOL_NAME 2>&1)
log_note "$(echo "$RESULT" | grep mmp_)"
if echo "$RESULT" | grep -q "mmp_result: 3"; then
	log_fail "activity check skipped: mmp_delay 0 was read as" \
	    "multihost=off despite the valid MMP config"
fi
echo "$RESULT" | grep -q "mmp_result: 0" || \
    log_fail "expected an activity check that found no activity"
log_must poolexists $POOL_NAME
log_must eval "zpool status $POOL_NAME | grep -q ONLINE"

log_pass "a valid MMP config with mmp_delay 0 requires an activity check"
