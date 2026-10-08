#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	A block written by dmu_sync() (an fsync'd write, which reaches
#	syncing context as an override BP) can be deduplicated against an
#	existing entry that has fewer copies than the block needs.  The
#	extra copies must be written from the compressed data, so the block
#	reads back correctly (openzfs/zfs#19226).
#
# STRATEGY:
#	1. Create a pool with fast dedup (one phys slot per entry) and a
#	   dataset with dedup=on, lz4 compression and copies=1.
#	2. Write a compressible block and fsync it, then sync the pool, so
#	   the DDT entry has one DVA.
#	3. Set copies=2 and write the same data to a second file with fsync,
#	   then sync the pool.  The entry needs another DVA.
#	4. Both files must read back intact after a remount, a scrub must
#	   find no errors, and zdb must find no leaks.
#

verify_runnable "global"

log_assert "Dedup of an fsync'd block that needs more copies succeeds"

# Flush DDT log every TXG so entries appear in the ZAP immediately.
log_must save_tunable DEDUP_LOG_TXG_MAX
log_must set_tunable32 DEDUP_LOG_TXG_MAX 1

typeset src=$TEST_BASE_DIR/dedup_override_copies.src

function cleanup
{
	if poolexists $TESTPOOL ; then
		destroy_pool $TESTPOOL
	fi
	rm -f $src
	log_must restore_tunable DEDUP_LOG_TXG_MAX
}

log_onexit cleanup

log_must zpool create -f -o feature@fast_dedup=enabled $TESTPOOL $DISKS
log_must zfs create -o dedup=on -o compression=lz4 -o copies=1 \
    -o recordsize=256k $TESTPOOL/$TESTFS
typeset mntpnt=$(get_prop mountpoint $TESTPOOL/$TESTFS)

# One compressible, non-zero record.
head -c 262144 /dev/zero | tr '\0' 'A' > $src || log_fail "can't create $src"

# The fsync makes the ZIL write the block with dmu_sync(), so it reaches
# syncing context as an override BP.  The first one creates the entry.
log_must dd if=$src of=$mntpnt/file1 bs=256k conv=fsync
sync_pool $TESTPOOL
log_must eval "zdb -D $TESTPOOL | grep -q 'DDT-.*-unique:.*entries=1'"

# The second one finds the entry with one DVA, but needs two.
log_must zfs set copies=2 $TESTPOOL/$TESTFS
log_must dd if=$src of=$mntpnt/file2 bs=256k conv=fsync
sync_pool $TESTPOOL

# Read back from disk, not the ARC.
log_must zfs unmount $TESTPOOL/$TESTFS
log_must zfs mount $TESTPOOL/$TESTFS
log_must cmp $src $mntpnt/file1
log_must cmp $src $mntpnt/file2

log_must zpool scrub -w $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"
log_must eval "zpool status -v $TESTPOOL | grep -q 'repaired 0B'"
log_must zdb -b $TESTPOOL

log_pass "Dedup of an fsync'd block that needs more copies succeeds"
