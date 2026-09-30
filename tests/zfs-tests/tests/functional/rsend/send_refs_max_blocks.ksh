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

. $STF_SUITE/tests/functional/rsend/rsend.kshlib

#
# Description:
# Verify that zfs_send_refs_max_blocks limits the number of blocks that
# "zfs send --refs" tracks, and that the blocks beyond it are sent in full.
#
# Strategy:
# 1. Create a dedup=on filesystem with a file of random data, snapshot @a
#    and replicate it.  Copy the file and snapshot @b.
# 2. With zfs_send_refs_max_blocks=4, send -i @a @b --refs: 4 blocks are
#    sent as references, the others in full, and send_refs_truncated
#    increases.  The stream is received and verified.
# 3. With zfs_send_refs_max_blocks=0 no block is tracked, and a regular
#    stream is sent.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
stream=$BACKDIR/refs
typeset -i nrec=16
typeset -i max=4

function cleanup
{
	[[ -n "$saved_max" ]] && set_tunable64 SEND_REFS_MAX_BLOCKS $saved_max
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $stream $BACKDIR/full
}

log_assert "zfs_send_refs_max_blocks limits the blocks zfs send --refs tracks"
log_onexit cleanup

saved_max=$(get_tunable SEND_REFS_MAX_BLOCKS)

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
refs_copy $mntpnt/f1 $mntpnt/f2
log_must zfs snapshot $sendfs@b
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

# All blocks are references with the default limit.
log_must eval "zfs send --refs -i @a $sendfs@b >$stream"
log_must test "$(stream_byref_records $stream)" -eq $nrec
typeset -i full_size=$(stat_size $stream)

log_must set_tunable64 SEND_REFS_MAX_BLOCKS $max
typeset -i truncated=$(send_refs_stat send_refs_truncated)
typeset -i candidates=$(send_refs_stat send_refs_candidates)
log_must eval "zfs send --refs -i @a $sendfs@b >$stream"
log_must test $(send_refs_stat send_refs_truncated) -gt $truncated
log_must test $(send_refs_stat send_refs_candidates) -eq $((candidates + max))
log_must stream_has_features $stream fromsnap_refs
log_must test "$(stream_byref_records $stream)" -eq $max
# the others are sent in full
log_must test $(stat_size $stream) -gt \
	$((full_size + (nrec - max - 1) * REFS_RECSIZE))
log_must eval "zfs recv -u $recvfs <$stream"
refs_cmp_snaps $sendfs $recvfs a b
log_must zfs rollback -r $recvfs@a

log_must set_tunable64 SEND_REFS_MAX_BLOCKS 0
truncated=$(send_refs_stat send_refs_truncated)
log_must eval "zfs send --refs -i @a $sendfs@b >$stream"
log_must test $(send_refs_stat send_refs_truncated) -gt $truncated
log_mustnot stream_has_features $stream fromsnap_refs
log_must test "$(stream_byref_records $stream)" -eq 0
log_must eval "zfs recv -u $recvfs <$stream"
refs_cmp_snaps $sendfs $recvfs a b

log_pass "zfs_send_refs_max_blocks limits the blocks zfs send --refs tracks"
