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
# Copyright (c) 2026 by Will Rouesnel.
#

. $STF_SUITE/tests/functional/slog/slog.kshlib

#
# DESCRIPTION:
#	Concurrent sync writes into a new block of a new file are logged
#	and replayed with their data, and a hole punched over one of them
#	frees it.
#
#	The first writer to dirty a block past dn_maxblkid publishes its
#	dirty record before it raises dn_maxblkid.  A second writer can
#	find the block already dirty in that window, copy its data in, and
#	read it back for its WR_COPIED log record, or punch a hole over it,
#	while dn_maxblkid still says the block can't exist: the read
#	returns zeros, which the log records and replay writes back, and
#	the free is skipped (openzfs/zfs#19766).
#
# STRATEGY:
#	1. Create a pool with a slog, a dataset with a 128K recordsize, and
#	   freeze the pool, so everything after is replayed.
#	2. For each of many new O_DSYNC files, start 8 threads together,
#	   each writing 4K (WR_COPIED) into the file's second block.
#	3. Check the data in the live files, then that no TX_WRITE in the
#	   log has an all-zero payload (zdb).
#	4. Export and import to replay the log; every range must hold the
#	   data written.
#	5. Repeat with each thread punching a hole over its range as soon
#	   as its write returns: every range must read as zeros, in the
#	   live files and after replay.
#
# The race is not forced, so the test runs enough files for the window to
# be hit several times on an unfixed build.  The punch window (the hole
# punched before the first writer raises dn_maxblkid) is much narrower and
# is not expected to be hit here; step 5 checks the punch still frees each
# range.
#

verify_runnable "global"

NFILES=400
NTHREADS=8
LEN=4096
BLKSZ=131072

function cleanup_fs
{
	cleanup
}

#
# Freeze the pool, run concurrent_sync_write with $1 (-w or -p) into
# $TESTDIR/$2, check the live files with $3 (-v or -z), then replay the
# log and check them again.
#
function write_frozen_and_replay
{
	typeset wmode=$1
	typeset dir=/$TESTPOOL/$TESTFS/$2
	typeset vmode=$3
	typeset zdbout=$TESTDIR/zdb.$2

	log_must mkdir $dir
	# Make sure the dataset has a ZIL header before freezing.
	log_must dd if=/dev/zero of=/$TESTPOOL/$TESTFS/sync \
	    conv=fdatasync,fsync bs=1 count=1
	log_must zpool freeze $TESTPOOL

	log_must concurrent_sync_write $wmode $dir $NFILES $NTHREADS $LEN \
	    $BLKSZ
	log_must concurrent_sync_write $vmode $dir $NFILES $NTHREADS $LEN \
	    $BLKSZ

	log_must zfs unmount $TESTPOOL/$TESTFS
	log_must eval "zdb -ivvvv $TESTPOOL/$TESTFS >$zdbout"
	typeset writes=$(grep -c "TX_WRITE" $zdbout)
	log_note "$writes TX_WRITE records in the log"
	log_must test $writes -ge $((NFILES * NTHREADS))
	if [[ $wmode == "-w" ]]; then
		# Each record's payload starts with "file=", never with zeros.
		typeset zero=$(awk '/TX_WRITE/ {getline; getline;
		    if ($1 == "0" && $2 == "0" && $3 == "0") n++}
		    END {print n + 0}' $zdbout)
		[[ $zero -eq 0 ]] || \
		    log_fail "$zero TX_WRITE records were logged as zeros"
	fi

	log_must zpool export $TESTPOOL
	log_must zpool import -f -d $VDIR $TESTPOOL
	concurrent_sync_write $vmode $dir $NFILES $NTHREADS $LEN $BLKSZ \
	    >$TESTDIR/verify.$2
	typeset rc=$?
	head -20 $TESTDIR/verify.$2
	(( rc == 0 )) || \
	    log_fail "after replay: $(tail -1 $TESTDIR/verify.$2)"
}

log_assert "Concurrent sync writes into a new block are logged and" \
    "replayed with their data."
log_onexit cleanup_fs
log_must setup

log_must zpool create $TESTPOOL $VDEV log mirror $LDEV
log_must zfs create -o compression=off -o recordsize=$BLKSZ \
    -o logbias=latency $TESTPOOL/$TESTFS
log_must mkdir -p $TESTDIR

write_frozen_and_replay -w write -v

log_must zpool destroy $TESTPOOL
log_must zpool create $TESTPOOL $VDEV log mirror $LDEV
log_must zfs create -o compression=off -o recordsize=$BLKSZ \
    -o logbias=latency $TESTPOOL/$TESTFS
log_must mkdir -p $TESTDIR

write_frozen_and_replay -p punch -z

log_pass "Concurrent sync writes into a new block are logged and" \
    "replayed with their data."
