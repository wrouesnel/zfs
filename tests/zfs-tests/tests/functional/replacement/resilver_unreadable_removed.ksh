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
# Blocks whose DVAs point at an indirect vdev (left by "zpool remove")
# have their data on other vdevs.  A resilver that can't read them must
# still keep them in the new device's DTL, so that the device holding
# them can't be detached until they have been copied.
#
# STRATEGY:
# 1. Create a pool on r, fill it with files, add a and remove r, so that
#    every file block is remapped from the indirect vdev to a.
# 2. Make some files unreadable and attach b to a.
# 3. Verify the resilver reports errors and "zpool detach" of a fails.
# 4. Stop the errors and scrub: the blocks are copied to b, the detach
#    then succeeds and every file is intact on b alone.
#

verify_runnable "global"

DIR=$TEST_BASE_DIR/resilver_unreadable_removed
NFILES=16
NBAD=4

function cleanup
{
	restore_tunable SCAN_SUSPEND_PROGRESS
	zinject -c all >/dev/null 2>&1
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $DIR
}

function check_files # mode
{
	typeset i

	for i in $(seq $NFILES); do
		[[ "$(xxh128digest $mnt/f$i)" == "${sums[$i]}" ]] ||
		    log_fail "$1: $mnt/f$i is damaged"
	done
}

log_assert "A resilver that can't read blocks remapped from a removed" \
    "vdev keeps them in the new device's DTL"
log_onexit cleanup
log_must save_tunable SCAN_SUSPEND_PROGRESS

rm -rf $DIR
log_must mkdir -p $DIR
log_must truncate -s 512M $DIR/r $DIR/a $DIR/b
log_must zpool create -f -o ashift=12 -O compression=off \
    -O primarycache=metadata $TESTPOOL1 $DIR/r
mnt=$(get_prop mountpoint $TESTPOOL1)
set -A sums
for i in $(seq $NFILES); do
	log_must dd if=/dev/urandom of=$mnt/f$i bs=128k count=8 status=none
	sums[$i]=$(xxh128digest $mnt/f$i)
done
sync_pool $TESTPOOL1
log_must zpool add -o ashift=12 $TESTPOOL1 $DIR/a
log_must zpool remove -w $TESTPOOL1 $DIR/r
zpool status $TESTPOOL1 | grep -q "Removal of vdev 0 copied" ||
    log_fail "r wasn't removed"
log_must zpool export $TESTPOOL1
log_must zpool import -d $DIR $TESTPOOL1

# Hold the resilver until the errors are in place.
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool attach $TESTPOOL1 $DIR/a $DIR/b
for i in $(seq $NBAD); do
	log_must zinject -t data -e io -f 100 $mnt/f$i
done
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver $TESTPOOL1
zpool status -v $TESTPOOL1
errs=$(zpool status $TESTPOOL1 |
    sed -n 's/.*resilvered.* with \([0-9]*\) errors.*/\1/p')
(( errs > 0 )) || log_fail "the resilver reported no errors"

# b lacks the remapped blocks the resilver couldn't read.
if zpool detach $TESTPOOL1 $DIR/a; then
	log_must zinject -c all
	check_files "after the detach"
	log_fail "detach of the only device holding blocks remapped from" \
	    "a removed vdev succeeded"
fi
log_must zinject -c all

log_must zpool scrub -w $TESTPOOL1
log_must zpool detach $TESTPOOL1 $DIR/a
log_must zpool export $TESTPOOL1
log_must zpool import -d $DIR $TESTPOOL1
check_files "on b alone"
log_must zpool scrub -w $TESTPOOL1
log_must zpool scrub -w $TESTPOOL1
zpool status -v $TESTPOOL1
log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"

log_pass "A resilver that can't read blocks remapped from a removed" \
    "vdev keeps them in the new device's DTL"
