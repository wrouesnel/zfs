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
. $STF_SUITE/tests/functional/cli_root/zpool_add/zpool_add.kshlib

#
# DESCRIPTION:
#	'zpool add' accepts a log device whose sector size differs from
#	the pool's: a log never prevents a device removal, which is what
#	the ashift check protects.  Special and dedup devices are still
#	checked.
#
# STRATEGY:
#	1. Create a pool with ashift=12.
#	2. Add a log device with ashift=9 without --allow-ashift-mismatch:
#	   it must work.
#	3. Add a data vdev (ashift=12) and remove it: the log must not
#	   prevent that.
#	4. Remove the log device.
#	5. Adding a special or dedup device with ashift=9 must still fail.
#

verify_runnable "global"

function cleanup
{
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	rm -f $disk1 $disk2 $disk3 $disk4 $disk5
}

log_assert "'zpool add' accepts a log device with a different ashift"
log_onexit cleanup

disk1=$TEST_BASE_DIR/disk1
disk2=$TEST_BASE_DIR/disk2
disk3=$TEST_BASE_DIR/disk3
disk4=$TEST_BASE_DIR/disk4
disk5=$TEST_BASE_DIR/disk5
log_must truncate -s $SIZE $disk1 $disk2 $disk3 $disk4 $disk5

log_must zpool create -o ashift=12 $TESTPOOL $disk1
log_must verify_ashift $disk1 12

log_must zpool add -o ashift=9 $TESTPOOL log $disk2
log_must verify_ashift $disk2 9

log_must zpool add $TESTPOOL $disk3
log_must verify_ashift $disk3 12
log_must zpool remove -w $TESTPOOL $disk3
log_must zpool remove $TESTPOOL $disk2
log_must zpool sync $TESTPOOL
log_mustnot eval "zpool status -P $TESTPOOL | grep -qE '$disk2|$disk3'"

log_mustnot zpool add -o ashift=9 $TESTPOOL special $disk4
log_mustnot zpool add -o ashift=9 $TESTPOOL dedup $disk5

log_pass "'zpool add' accepts a log device with a different ashift"
