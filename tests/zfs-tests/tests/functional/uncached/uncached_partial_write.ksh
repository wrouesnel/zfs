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
# Uncached writes smaller than a record must not leave the records in the
# dbuf cache once the writes have completed them.
#
# STRATEGY:
# 1. Write a file of whole records in parts smaller than a record, so that
#    each record is first dirtied by a partial write and then redirtied by
#    the following writes in the same txg, in three ways that ask for no
#    caching: 1k writes with primarycache=none, 4k O_DIRECT writes (which
#    are smaller than a record, so they go through the ARC as Uncached I/O)
#    and, where the kernel supports it, 4k RWF_DONTCACHE writes.
# 2. After each, sync and check that the file reads back intact and that
#    at most 2 of its level 0 dbufs are in the dbuf cache (the allowance
#    uncached_dontcache makes).
# 3. Write the file the same way with ordinary cached 1k writes: its dbufs
#    must stay in the dbuf cache, so the checks can't pass for the wrong
#    reason.
#

verify_runnable "global"

FS=$TESTPOOL/$TESTFS
FILE=$TESTDIR/$TESTFILE0
SRC=$TEST_BASE_DIR/uncached_partial_write.src
RECSIZE=131072
NRECS=32
DBUFS_FILE=$(mktemp -t dbufs.out.XXXXXX)

function cleanup
{
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
	if [[ $how == RWF_DONTCACHE* ]]; then
		log_must file_uncached -r -f $FILE -b 4096 \
		    -c $((NRECS * RECSIZE / 4096))
	else
		log_must cmp $SRC $FILE
	fi
	log_note "$how: $n of $NRECS level 0 dbufs cached"
	[[ $n -ge $min && $n -le $max ]] || log_fail \
	    "$how: $n of $NRECS level 0 dbufs cached, expected $min to $max"
	log_must rm -f $FILE
	sync_pool $TESTPOOL
}

log_assert "Uncached writes in parts don't leave records in the dbuf cache"

log_onexit cleanup

log_must zfs set recordsize=$RECSIZE $FS
log_must zfs set compression=off $FS
log_must dd if=/dev/urandom of=$SRC bs=$RECSIZE count=$NRECS

log_must zfs set primarycache=none $FS
log_must dd if=$SRC of=$FILE bs=1024
check_write "primarycache=none, 1k writes" 0 2

log_must zfs set primarycache=all $FS
log_must stride_dd -i $SRC -o $FILE -b 4096 -c $((NRECS * RECSIZE / 4096)) -D
check_write "O_DIRECT 4k writes" 0 2

file_uncached -d -f $FILE -b 4096 -c $((NRECS * RECSIZE / 4096))
ret=$?
if [[ $ret -eq 2 ]]; then
	log_note "RWF_DONTCACHE is not supported, skipping"
elif [[ $ret -ne 0 ]]; then
	log_fail "file_uncached write failed with $ret"
else
	check_write "RWF_DONTCACHE 4k writes" 0 2
fi

log_must dd if=$SRC of=$FILE bs=1024
check_write "cached 1k writes" $((NRECS / 2)) $NRECS

log_pass "Uncached writes in parts don't leave records in the dbuf cache"
