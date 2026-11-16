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
. $STF_SUITE/tests/functional/replacement/replacement.cfg

#
# DESCRIPTION:
# A replacement whose resilver can read every block, but fails to write
# some of them to the new device, waits for another resilver as before.
# "zpool status" must not claim that data could not be read (that is
# only for blocks no device could supply), and once the writes work, a
# resilver completes the replacement.
#
# STRATEGY:
# 1. Create a pool of one data device a and a special device, so that
#    only file data reaches a, and write two files in separate txgs.
# 2. Replace a with c, failing every write to c during the resilver.
# 3. Verify the replacement is still in progress, a can't be detached,
#    and "zpool status" shows no held-replacement status.
# 4. Stop the errors and resilver: the replacement completes, every file
#    is intact and the pool is healthy.
#

verify_runnable "global"

DIR=$TEST_BASE_DIR/replace_write_errors

function cleanup
{
	restore_tunable SCAN_SUSPEND_PROGRESS
	zinject -c all >/dev/null 2>&1
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $DIR
}

log_assert "A replacement whose repair writes failed waits for a resilver" \
    "without a held-replacement status"
log_onexit cleanup
log_must save_tunable SCAN_SUSPEND_PROGRESS

rm -rf $DIR
log_must mkdir -p $DIR
log_must truncate -s $MINVDEVSIZE $DIR/a $DIR/c $DIR/s
log_must zpool create -f $TESTPOOL1 $DIR/a special $DIR/s
mnt=$(get_prop mountpoint $TESTPOOL1)
set -A sums
for i in 1 2; do
	log_must dd if=/dev/urandom of=$mnt/file$i bs=128k count=1 status=none
	sums[$i]=$(xxh128digest $mnt/file$i)
	sync_pool $TESTPOOL1
done

log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool replace $TESTPOOL1 $DIR/a $DIR/c
log_must zinject -d $DIR/c -e io -T write $TESTPOOL1
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver $TESTPOOL1
zpool status -v $TESTPOOL1

errs=$(zpool status -p $TESTPOOL1 | awk -v d=$DIR/c '$1 == d { print $4 }')
(( errs > 0 )) || log_fail "no write errors on $DIR/c"
zpool status $TESTPOOL1 | grep -q "replacing-0" ||
    log_fail "the replacement completed although c lacks the data"
log_mustnot zpool detach $TESTPOOL1 $DIR/a
zpool status $TESTPOOL1 | grep -qF "cannot finish replacing" &&
    log_fail "zpool status says data could not be read"
zpool status $TESTPOOL1 | grep -qF "may hold missing data" &&
    log_fail "a is marked as holding missing data"
zpool status -j $TESTPOOL1 | grep -qF '"replace_held"' &&
    log_fail "zpool status -j has a replace_held vdev"
log_must zinject -c all

# zpool resilver only schedules the resilver, so sync before waiting.
log_must zpool resilver $TESTPOOL1
sync_pool $TESTPOOL1
log_must zpool wait -t resilver $TESTPOOL1
for i in $(seq 30); do
	zpool status $TESTPOOL1 | grep -q "replacing-0" || break
	sleep 1
done
zpool status -v $TESTPOOL1
zpool status $TESTPOOL1 | grep -q "replacing-0" &&
    log_fail "the replacement didn't complete after a clean resilver"
for i in 1 2; do
	[[ "$(xxh128digest $mnt/file$i)" == "${sums[$i]}" ]] ||
	    log_fail "$mnt/file$i is damaged"
done
log_must zpool scrub -w $TESTPOOL1
log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"

log_pass "A replacement whose repair writes failed waits for a resilver" \
    "without a held-replacement status"
