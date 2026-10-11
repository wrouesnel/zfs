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
# Copyright (c) 2026 by Will Rouesnel. All rights reserved.
#

. $STF_SUITE/tests/functional/slog/slog.kshlib

#
# DESCRIPTION:
#	Replay ends before an indirect (WR_INDIRECT) write whose dmu_sync()
#	block could not be allocated, leaving the data it would have
#	overwritten as it was, and doesn't apply the records after it.  The
#	log stays readable, and nothing allocated for the failed write leaks.
#
#	The log block holding such a record would carry a hole, or an
#	incomplete gang block, so it isn't written, and the log ends before
#	it.  Its commit, and every commit after it, wait for the txg to sync,
#	so none of the records lost with it were acknowledged.
#
# STRATEGY:
#	For a dmu_sync() write whose gang header allocates but whose members
#	don't, then for one whose gang header fails to allocate as well (see
#	slog_replay_fs_003, which tests the second case first):
#	1. Create a pool with a small normal vdev for file data, a special
#	   vdev for metadata and small blocks and a log vdev, and a file of 4
#	   records.
#	2. Freeze the pool, overwrite record 1 (logbias=throughput), and
#	   sync the txg.  Then use up all but 8K (nothing) of the normal
#	   vdev.
#	3. fsync the file: the record's dmu_sync() write fails to allocate.
#	4. Create and write a small new file with O_SYNC and
#	   logbias=latency.  Its commit must fall back to waiting for the txg
#	   to sync (zil_commit_error_count).
#	5. zdb must read the log, without a hole where record 1's data would
#	   be.  (A debug zdb asserts on an incomplete gang block.)
#	6. Export and import the pool, which replays the log.  Record 1
#	   holds the old data, and the new file doesn't exist.
#	7. The pool is healthy, a scrub finds nothing, record 1 can be
#	   rewritten, and zdb finds no leaked space.
#

verify_runnable "global"

function cleanup_fs
{
	cleanup
}

function nfree
{
	zpool list -Hpv $TESTPOOL | awk -v d=$VDIR/a '$1 == d { print $4 }'
}

log_assert "Replay ends before an indirect write whose block failed to" \
    "allocate."
log_onexit cleanup_fs

typeset file=/$TESTPOOL/$TESTFS/file
typeset later=/$TESTPOOL/$TESTFS/later
typeset zdbout=$TEST_BASE_DIR/zdb.failed_write.$$
typeset -i f n i e0 e1 target

for target in 8192 0; do
	log_note "Normal vdev left with $target bytes free"
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	log_must setup

	#
	# 1. The pool, with file data alone in the normal vdev.
	#
	log_must truncate -s 128m $VDIR/a
	log_must truncate -s 512m $VDIR/d
	log_must zpool create -o ashift=12 $TESTPOOL $VDIR/a \
	    special $VDIR/d log $VDIR/e
	log_must zfs create -o recordsize=128k -o compression=off \
	    -o logbias=throughput -o special_small_blocks=4k \
	    $TESTPOOL/$TESTFS
	log_must zfs create -o recordsize=4k -o compression=off \
	    $TESTPOOL/fill

	log_must rm -rf $TESTDIR
	log_must mkdir -p $TESTDIR
	log_must dd if=/dev/urandom of=$TESTDIR/old bs=128k count=4
	log_must dd if=/dev/urandom of=$TESTDIR/new bs=128k count=1
	log_must dd if=/dev/urandom of=$TESTDIR/later bs=4k count=1
	log_must cp $TESTDIR/old $file
	log_must dd if=/dev/urandom of=/$TESTPOOL/fill/f bs=4k count=8192

	# Create the ZIL header, so that log records are written after the
	# freeze.
	log_must dd if=/dev/zero of=/$TESTPOOL/$TESTFS/sync \
	    conv=fdatasync,fsync bs=1 count=1
	log_must sync_pool $TESTPOOL

	#
	# 2. Freeze, overwrite record 1, sync, and use up all but $target
	#    bytes of the normal vdev.
	#
	log_must zpool freeze $TESTPOOL
	log_must dd if=$TESTDIR/new of=$file bs=128k seek=1 count=1 \
	    conv=notrunc
	log_must sync_pool $TESTPOOL
	for ((i = 0; i < 100; i++)); do
		f=$(nfree)
		((f <= target)) && break
		((n = (f - target) / 4096))
		((n > 8192)) && n=8192
		log_must dd if=/dev/urandom of=/$TESTPOOL/fill/f bs=4k \
		    count=$n conv=notrunc
		log_must sync_pool $TESTPOOL
	done
	f=$(nfree)
	log_note "normal vdev free: $f"
	((f == target)) || log_unsupported "could not leave $target free"

	#
	# 3. Commit record 1; its dmu_sync() write fails.
	#
	log_must dd if=/dev/null of=$file conv=notrunc,fsync

	#
	# 4. A later synchronous write, whose commit must fall back.
	#
	log_must zfs set logbias=latency $TESTPOOL/$TESTFS
	e0=$(kstat zil.zil_commit_error_count)
	log_must dd if=$TESTDIR/later of=$later bs=4k count=1 oflag=sync
	e1=$(kstat zil.zil_commit_error_count)
	((e1 > e0)) || log_fail "Commit after the failed write didn't fall back"
	log_must zfs unmount /$TESTPOOL/$TESTFS

	#
	# 5. zdb reads the log, and finds no hole in it.
	#
	log_must eval "zdb -ivvvv $TESTPOOL/$TESTFS > $zdbout"
	log_must cat $zdbout
	grep -q '<hole>' $zdbout && log_fail "The log holds a hole"

	#
	# 6. Export and import, replaying the log.
	#
	log_must zpool export $TESTPOOL
	log_must zpool import -f -d $VDIR $TESTPOOL

	log_must dd if=$file of=$TESTDIR/r1 bs=128k skip=1 count=1
	log_must dd if=$TESTDIR/old of=$TESTDIR/old1 bs=128k skip=1 count=1
	log_must dd if=/dev/zero of=$TESTDIR/zeros bs=128k count=1
	if cmp -s $TESTDIR/r1 $TESTDIR/zeros; then
		log_fail "Record 1 was replayed as zeros"
	fi
	cmp -s $TESTDIR/r1 $TESTDIR/old1 || \
	    log_fail "Record 1 doesn't hold the old data"
	log_must cmp $file $TESTDIR/old
	[[ -e $later ]] && log_fail "Replay went past the failed write"

	#
	# 7. A healthy pool, a clean scrub, a rewrite, and no leaks.
	#
	log_must check_pool_status $TESTPOOL state ONLINE
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL errors "No known data errors"
	log_must is_pool_scrubbed $TESTPOOL
	log_must eval "zpool status -v $TESTPOOL | grep -q 'repaired 0B'"
	log_must dd if=$TESTDIR/new of=$file bs=128k seek=1 count=1 \
	    conv=notrunc oflag=sync
	log_must sync_pool $TESTPOOL
	log_must dd if=$file of=$TESTDIR/r1 bs=128k skip=1 count=1
	log_must cmp $TESTDIR/r1 $TESTDIR/new
	log_must zpool export $TESTPOOL
	log_must zdb -e -p $VDIR -b $TESTPOOL
	log_must zpool import -d $VDIR $TESTPOOL
	rm -f $zdbout
done

log_pass "Replay ends before an indirect write whose block failed to" \
    "allocate."
