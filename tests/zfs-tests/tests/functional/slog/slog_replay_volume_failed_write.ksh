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
#	Replay of a volume ends at an indirect (WR_INDIRECT) write whose
#	dmu_sync() block could not be allocated, leaving the block it would
#	have overwritten as it was, and doesn't apply the records after it.
#	(A volume replays whole blocks, so a hole would zero the block.)
#
# STRATEGY:
#	For a dmu_sync() write and its gang header that both fail to
#	allocate, and for one whose gang header allocates but whose members
#	don't (see slog_replay_fs_003):
#	1. Create a pool with a small normal vdev for volume data, a special
#	   vdev for metadata and a log vdev, and a volume with 128K blocks,
#	   sync=always and logbias=throughput.  Write 4 blocks.
#	2. Freeze the pool, and use up all but 128K (136K) of the normal
#	   vdev.
#	3. Overwrite block 1: its dmu_sync() write fails to allocate.
#	4. Discard block 3, which needs no space in the normal vdev.  Its
#	   commit must fall back to waiting for the txg to sync
#	   (zil_commit_error_count).
#	5. zdb shows the overwrite's record as a failed write, followed by
#	   the discard's TX_TRUNCATE.
#	6. Export and import the pool, which replays the log.  Replay must
#	   end at the failed write (zil_replay_write_failed): the volume
#	   holds the old data in all 4 blocks.
#	7. The pool is healthy, a scrub finds nothing, block 1 can be
#	   rewritten, and zdb finds no leaked space.
#

verify_runnable "global"

# The discard uses blkdiscard(8).
is_linux || log_unsupported "Linux only"

typeset VOLUME=$ZVOL_DEVDIR/$TESTPOOL/$TESTVOL

function cleanup_volume
{
	exec 5<&-
	cleanup
}

# zil_replay_write_failed, or nothing if this build lacks it.
function replay_failed
{
	kstat -g zil | awk '$1 == "zil_replay_write_failed" { print $2 }'
}

function nfree
{
	zpool list -Hpv $TESTPOOL | awk -v d=$VDIR/a '$1 == d { print $4 }'
}

log_assert "Replay of a volume ends at an indirect write whose block" \
    "failed to allocate."
log_onexit cleanup_volume

typeset zdbout=$TEST_BASE_DIR/zdb.failed_write.$$
typeset -i f n i e0 e1 extra target
typeset r0 r1

for extra in 0 8192; do
	((target = 131072 + extra))
	log_note "Normal vdev left with $target bytes free"
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	log_must setup

	#
	# 1. The pool, with volume data alone in the normal vdev.
	#
	log_must truncate -s 128m $VDIR/a
	log_must truncate -s 512m $VDIR/d
	log_must zpool create -o ashift=12 $TESTPOOL $VDIR/a \
	    special $VDIR/d log $VDIR/e
	log_must zfs create -s -V 16m -o volblocksize=128k \
	    -o compression=off -o sync=always -o logbias=throughput \
	    $TESTPOOL/$TESTVOL
	log_must zfs create -o recordsize=4k -o compression=off \
	    $TESTPOOL/fill
	block_device_wait $VOLUME

	log_must rm -rf $TESTDIR
	log_must mkdir -p $TESTDIR
	log_must dd if=/dev/urandom of=$TESTDIR/old bs=128k count=4
	log_must dd if=/dev/urandom of=$TESTDIR/new bs=128k count=1
	log_must dd if=$TESTDIR/old of=$VOLUME bs=128k count=4 \
	    oflag=direct conv=fsync
	log_must dd if=/dev/urandom of=/$TESTPOOL/fill/f bs=4k count=8192
	log_must sync_pool $TESTPOOL

	#
	# 2. Freeze, and use up all but $target bytes of the normal vdev.
	#    Keep the volume open until the export: in a frozen pool, the
	#    log's state isn't kept on disk when it's closed.
	#
	exec 5<$VOLUME
	log_must zpool freeze $TESTPOOL
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
	# 3. Overwrite block 1; its dmu_sync() write fails.
	#
	log_must dd if=$TESTDIR/new of=$VOLUME bs=128k seek=1 count=1 \
	    oflag=direct conv=notrunc

	#
	# 4. Discard block 3, whose commit must fall back.
	#
	e0=$(kstat zil.zil_commit_error_count)
	log_must blkdiscard -o $((3 * 131072)) -l 131072 $VOLUME
	e1=$(kstat zil.zil_commit_error_count)
	((e1 > e0)) || log_fail "Commit after the failed write didn't fall back"

	#
	# 5. The log holds the failed write, then the TX_TRUNCATE (checked
	#    after the data, below).
	#
	log_must eval "zdb -ivvvv $TESTPOOL/$TESTVOL > $zdbout"
	log_must cat $zdbout

	#
	# 6. Export and import, replaying the log up to the failed write.
	#
	exec 5<&-
	r0=$(replay_failed)
	log_must zpool export $TESTPOOL
	log_must zpool import -f -d $VDIR $TESTPOOL
	block_device_wait $VOLUME
	r1=$(replay_failed)

	log_must dd if=$VOLUME of=$TESTDIR/r bs=128k count=4 iflag=direct
	log_must dd if=$TESTDIR/r of=$TESTDIR/r1 bs=128k skip=1 count=1
	log_must dd if=$TESTDIR/old of=$TESTDIR/old1 bs=128k skip=1 count=1
	log_must dd if=/dev/zero of=$TESTDIR/zeros bs=128k count=1
	if cmp -s $TESTDIR/r1 $TESTDIR/zeros; then
		log_fail "Block 1 was replayed as zeros"
	fi
	cmp -s $TESTDIR/r1 $TESTDIR/old1 || \
	    log_fail "Block 1 doesn't hold the old data"
	cmp -s $TESTDIR/r $TESTDIR/old || \
	    log_fail "Replay went past the failed write"
	((r1 == r0 + 1)) || log_fail "zil_replay_write_failed $r0 -> $r1"
	n=$(grep -c '<failed write: replay ends here>' $zdbout)
	((n == 1)) || log_fail "$n failed writes in the log, expected 1"
	log_must eval "awk '/<failed write: replay ends here>/ { m = 1 }" \
	    "m && /TX_TRUNCATE/ { c = 1 } END { exit !c }' $zdbout"

	#
	# 7. A healthy pool, a clean scrub, a rewrite, and no leaks.
	#
	log_must check_pool_status $TESTPOOL state ONLINE
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL errors "No known data errors"
	log_must is_pool_scrubbed $TESTPOOL
	log_must eval "zpool status -v $TESTPOOL | grep -q 'repaired 0B'"
	log_must dd if=$TESTDIR/new of=$VOLUME bs=128k seek=1 count=1 \
	    oflag=direct conv=notrunc
	log_must sync_pool $TESTPOOL
	log_must dd if=$VOLUME of=$TESTDIR/r1 bs=128k skip=1 count=1 \
	    iflag=direct
	log_must cmp $TESTDIR/r1 $TESTDIR/new
	log_must zpool export $TESTPOOL
	log_must zdb -e -p $VDIR -b $TESTPOOL
	log_must zpool import -d $VDIR $TESTPOOL
	rm -f $zdbout
done

log_pass "Replay of a volume ends at an indirect write whose block" \
    "failed to allocate."
