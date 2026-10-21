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
# dmu_free_long_range() frees a large range in chunks of at most 256
# allocated L1 indirect blocks, which get_next_chunk() finds with a
# backward dnode_next_offset() search.  That search must find the L1s
# of an earlier L2 block even when the first L1 slot of that L2 is
# empty; if it skips them, the whole range becomes one chunk, and the
# transaction that frees it holds and reads every L1 in it
# (openzfs/zfs#19513).
#
# STRATEGY:
# 1. In a file system with recordsize=4k (an L1 covers 4M, an L2 4G),
#    write one block into L1 slots 1-128 of 8 consecutive L2 blocks of a
#    sparse file, leaving slot 0 of every L2 empty: 1024 L1s.
# 2. Set zfs_per_txg_dirty_frees_percent to 1, so that every chunk after
#    the first in a txg waits for the next txg (dmu_tx_dirty_frees_delay).
# 3. Truncate the file to 0.  Freed in chunks of 256 L1s, the frees must
#    have been delayed at least once; a single chunk is never delayed.
#

verify_runnable "both"

typeset fs=$TESTPOOL/$TESTFS/sparse_chunks
typeset mntpnt
typeset -i nl2=8 nl1=128
typeset saved_pct=$(get_tunable PER_TXG_DIRTY_FREES_PERCENT)

function cleanup
{
	log_must set_tunable32 PER_TXG_DIRTY_FREES_PERCENT $saved_pct
	datasetexists $fs && destroy_dataset $fs -r
}

log_onexit cleanup

log_assert "Truncating a sparse file frees it in chunks of at most 256 L1s"

log_must zfs create -o recordsize=4k -o compression=off $fs
mntpnt=$(get_prop mountpoint $fs)
typeset file=$mntpnt/file

# Block numbers in 4K blocks: an L1 holds 1024 block pointers (128K
# indirect blocks), so an L2 spans 1024 * 1024 blocks.
typeset -i l2 l1
for (( l2 = 0; l2 < nl2; l2++ )); do
	for (( l1 = 1; l1 <= nl1; l1++ )); do
		dd if=/dev/urandom of=$file bs=4k count=1 conv=notrunc \
		    seek=$(( (l2 * 1024 + l1) * 1024 )) 2>/dev/null || \
		    log_fail "dd to L2 $l2 L1 $l1 failed"
	done
done
log_note "file size $(stat_size $file), $((nl2 * nl1)) L1 blocks"
sync_all_pools

log_must set_tunable32 PER_TXG_DIRTY_FREES_PERCENT 1
typeset -i before=$(kstat dmu_tx.dmu_tx_dirty_frees_delay)
log_must truncate -s 0 $file
typeset -i after=$(kstat dmu_tx.dmu_tx_dirty_frees_delay)
typeset -i delays=$((after - before))
log_note "dmu_tx_dirty_frees_delay: $before -> $after ($delays)"

(( delays >= 1 )) || log_fail "the $((nl2 * nl1)) L1s were freed in one" \
    "chunk (no dirty frees delay): the backward search skipped L1s"

log_pass "Truncating a sparse file frees it in chunks of at most 256 L1s"
