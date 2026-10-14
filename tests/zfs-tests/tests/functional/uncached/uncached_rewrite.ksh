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
# zfs rewrite uses Uncached I/O, so it must not leave the blocks it
# rewrites in the dbuf cache, and must not evict blocks that were cached.
#
# STRATEGY:
# 1. Write a file of whole records with O_DIRECT, so that none of its
#    blocks are cached.
# 2. zfs rewrite it, sync, and check that its blocks were rewritten, that
#    it reads back intact and that none of its level 0 dbufs are in the
#    dbuf cache.  Repeat with zfs rewrite -P.
# 3. Read the file with cached I/O, rewrite it again and check that its
#    level 0 dbufs are still cached, so the checks can't pass for the wrong
#    reason.
#

verify_runnable "global"

FS=$TESTPOOL/$TESTFS
FILE=$TESTDIR/$TESTFILE0
RECSIZE=131072
NRECS=8
DBUFS_FILE=$(mktemp -t dbufs.out.XXXXXX)
BPS0=$(mktemp -t bps.XXXXXX)
BPS1=$(mktemp -t bps.XXXXXX)
COPY=$TEST_BASE_DIR/uncached_rewrite.copy

function cleanup
{
	log_must rm -f $FILE $COPY $DBUFS_FILE $BPS0 $BPS1
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

# The file's level 0 block pointers, one per line.
function file_bps
{
	zdb -Ovv $FS $TESTFILE0 | awk '/ L0 / { print $3 }'
}

# Hash of $FILE, read with O_DIRECT so that the read doesn't cache it.
function file_hash
{
	stride_dd -i $FILE -o $COPY -b $RECSIZE -c $NRECS -d || \
	    log_fail "O_DIRECT read of $FILE failed"
	xxh128digest $COPY
	rm -f $COPY
}

# rewrite_and_check HOW MIN MAX [zfs rewrite options]: rewrite $FILE, sync,
# and check that all its blocks moved, that it reads back intact, and that
# the number of its level 0 dbufs in the dbuf cache is between MIN and MAX.
function rewrite_and_check
{
	typeset how=$1 min=$2 max=$3
	shift 3

	log_must eval "file_bps > $BPS0"
	log_must zfs rewrite "$@" $FILE
	sync_pool $TESTPOOL
	sync_pool $TESTPOOL
	typeset n=$(cached_dbufs)
	log_must eval "file_bps > $BPS1"
	typeset same=$(sort $BPS0 $BPS1 | uniq -d | wc -l)
	[[ $(wc -l < $BPS1) -eq $NRECS && $same -eq 0 ]] || \
	    log_fail "$how: $same of $NRECS blocks were not rewritten"
	typeset hash=$(file_hash)
	[[ $hash == $HASH ]] || log_fail "$how: contents changed"
	log_note "$how: $n of $NRECS level 0 dbufs cached"
	[[ $n -ge $min && $n -le $max ]] || log_fail \
	    "$how: $n of $NRECS level 0 dbufs cached, expected $min to $max"
}

log_assert "zfs rewrite doesn't leave the blocks it rewrites in the dbuf cache"

log_onexit cleanup

log_must zfs set recordsize=$RECSIZE $FS
log_must zfs set compression=off $FS
log_must zfs set primarycache=all $FS

log_must stride_dd -i /dev/urandom -o $FILE -b $RECSIZE -c $NRECS -D
sync_pool $TESTPOOL
typeset n=$(cached_dbufs)
[[ $n -le 1 ]] || log_fail "$n level 0 dbufs cached after the O_DIRECT write"
HASH=$(file_hash)

rewrite_and_check "zfs rewrite" 0 0
if is_global_zone && \
    [[ $(get_pool_prop feature@physical_rewrite $TESTPOOL) != "disabled" ]]
then
	rewrite_and_check "zfs rewrite -P" 0 0 -P
fi

log_must eval "cat $FILE > /dev/null"
rewrite_and_check "zfs rewrite of a cached file" $((NRECS / 2)) $NRECS

log_pass "zfs rewrite doesn't leave the blocks it rewrites in the dbuf cache"
