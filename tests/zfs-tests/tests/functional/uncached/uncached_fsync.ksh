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
# Committing the ZIL must not change how written records are cached:
# records written uncached must not be left in the dbuf cache because an
# fsync copied them into the log.
#
# STRATEGY:
# 1. Hold the txg open (long zfs_txg_timeout), so that the writes are still
#    in the open txg when they are committed to the ZIL.
# 2. Write a file of whole records in 4k parts with primarycache=none, and
#    then with O_DIRECT, and fsync it at the end.  The fsync copies each
#    4k write into the log with dmu_read(DMU_KEEP_CACHING).
# 3. After each, sync and check that the file reads back intact and that
#    at most 2 of its level 0 dbufs are in the dbuf cache (the allowance
#    uncached_dontcache makes).
# 4. Write the file the same way with ordinary cached writes: its dbufs
#    must stay in the dbuf cache, so the checks can't pass for the wrong
#    reason.
#

verify_runnable "global"

FS=$TESTPOOL/$TESTFS
FILE=$TESTDIR/$TESTFILE0
SRC=$TEST_BASE_DIR/uncached_fsync.src
RECSIZE=131072
NRECS=32
DBUFS_FILE=$(mktemp -t dbufs.out.XXXXXX)
TXG_TIMEOUT_SAVED=$(get_tunable TXG_TIMEOUT)

function cleanup
{
	log_must set_tunable32 TXG_TIMEOUT $TXG_TIMEOUT_SAVED
	log_must rm -f $FILE $SRC $DBUFS_FILE
	log_must zfs inherit primarycache $FS
	log_must zfs inherit recordsize $FS
	log_must zfs inherit compression $FS
}

# Level 0 dbufs of $FILE in the dbuf cache.
function cached_dbufs
{
	typeset obj=$(get_objnum $FILE)

	kstat dbufs > $DBUFS_FILE
	dbufstat -bxn -i $DBUFS_FILE -F "object=$obj,level=0,dbc=1" | wc -l
}

# check_write HOW MIN MAX: sync, check that $FILE reads back intact and
# that the number of its level 0 dbufs in the dbuf cache is between MIN and
# MAX, and remove it.
function check_write
{
	typeset how=$1 min=$2 max=$3

	sync_pool $TESTPOOL
	sync_pool $TESTPOOL
	typeset n=$(cached_dbufs)
	log_must cmp $SRC $FILE
	log_note "$how: $n of $NRECS level 0 dbufs cached"
	[[ $n -ge $min && $n -le $max ]] || log_fail \
	    "$how: $n of $NRECS level 0 dbufs cached, expected $min to $max"
	log_must rm -f $FILE
	sync_pool $TESTPOOL
}

log_assert "An fsync doesn't leave uncached records in the dbuf cache"

log_onexit cleanup

log_must zfs set recordsize=$RECSIZE $FS
log_must zfs set compression=off $FS
log_must dd if=/dev/urandom of=$SRC bs=$RECSIZE count=$NRECS
log_must set_tunable32 TXG_TIMEOUT 600
sync_pool $TESTPOOL

log_must zfs set primarycache=none $FS
log_must dd if=$SRC of=$FILE bs=4096 conv=fsync
check_write "primarycache=none, 4k writes, fsync" 0 2

log_must zfs set primarycache=all $FS
log_must stride_dd -i $SRC -o $FILE -b 4096 -c $((NRECS * RECSIZE / 4096)) -D
log_must dd if=/dev/null of=$FILE count=0 conv=notrunc,fsync
check_write "O_DIRECT 4k writes, fsync" 0 2

log_must dd if=$SRC of=$FILE bs=4096 conv=fsync
check_write "cached 4k writes, fsync" $((NRECS / 2)) $NRECS

log_pass "An fsync doesn't leave uncached records in the dbuf cache"
