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
# Verify that "zfs send --delta" sends blocks of a file modified in place
# as patches against the same blocks of the incremental source.
#
# Strategy:
# 1. Create a filesystem with a file of random data, snapshot @a and
#    replicate it.
# 2. Overwrite a few bytes in some records of the file; snapshot @b.
# 3. Send -i @a @b with and without --delta.  The --delta stream has the
#    WRITE_DELTA feature and one DRR_WRITE_DELTA record per modified record
#    (all "same" hits), and is much smaller.  All new data is in a file
#    the fromsnap has, so the similarity index is not built.
# 4. Receive it; the received snapshots are identical to the sent ones.
# 5. An incremental with only new data (a new file) still has the
#    WRITE_DELTA feature, without DRR_WRITE_DELTA records, and is received;
#    the similarity index is built for it.
# 6. send -I --delta sends deltas too.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
recvfs2=$POOL2/refs_recv_I
delta=$BACKDIR/delta
plain=$BACKDIR/plain
typeset -i nrec=16

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	datasetexists $recvfs2 && destroy_dataset $recvfs2 -r
	rm -f $delta $plain $BACKDIR/full
}

log_assert "zfs send --delta sends blocks modified in place as patches"
log_onexit cleanup

log_must zfs create -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"
log_must eval "zfs recv -u $recvfs2 <$BACKDIR/full"

typeset -i ndelta=0
for rec in 1 5 9 13; do
	refs_poke $mntpnt/f1 $rec $((rec * 100)) 8
	(( ndelta += 1 ))
done
log_must zfs snapshot $sendfs@b

typeset -i records=$(send_refs_stat send_delta_records)
typeset -i same=$(send_refs_stat send_delta_same_hits)
typeset -i skipped=$(send_refs_stat send_delta_sketch_skipped)
typeset -i sketched=$(send_refs_stat send_delta_sketch_blocks)
log_must eval "zfs send --delta -i @a $sendfs@b >$delta"
log_must eval "zfs send -i @a $sendfs@b >$plain"
log_must stream_has_features $delta write_delta
log_mustnot stream_has_features $plain write_delta
log_must test "$(stream_delta_records $delta)" -eq $ndelta
log_must test "$(stream_delta_records $plain)" -eq 0
log_must test $(send_refs_stat send_delta_records) -eq $((records + ndelta))
log_must test $(send_refs_stat send_delta_same_hits) -eq $((same + ndelta))
log_must test $(send_refs_stat send_delta_sketch_skipped) -eq $((skipped + 1))
log_must test $(send_refs_stat send_delta_sketch_blocks) -eq $sketched

typeset -i delta_size=$(stat_size $delta)
typeset -i plain_size=$(stat_size $plain)
log_note "stream size: $delta_size with --delta, $plain_size without"
log_must test $((delta_size * 10)) -lt $plain_size

typeset -i recv=$(send_refs_stat recv_delta_records)
log_must eval "zfs recv -u $recvfs <$delta"
log_must test $(send_refs_stat recv_delta_records) -eq $((recv + ndelta))
refs_cmp_snaps $sendfs $recvfs a b

# Nothing similar: the feature is set, but there are no delta records.
refs_mkfile $mntpnt/f2 4
log_must zfs snapshot $sendfs@c
skipped=$(send_refs_stat send_delta_sketch_skipped)
sketched=$(send_refs_stat send_delta_sketch_blocks)
log_must eval "zfs send --delta -i @b $sendfs@c >$delta"
log_must test $(send_refs_stat send_delta_sketch_skipped) -eq $skipped
log_must test $(send_refs_stat send_delta_sketch_blocks) -gt $sketched
log_must stream_has_features $delta write_delta
log_must test "$(stream_delta_records $delta)" -eq 0
log_must eval "zfs recv -u $recvfs <$delta"
refs_cmp_snaps $sendfs $recvfs c

# send -I
log_must eval "zfs send --delta -I @a $sendfs@c >$delta"
log_must test "$(stream_delta_records $delta)" -eq $ndelta
log_must eval "zfs recv -u $recvfs2 <$delta"
refs_cmp_snaps $sendfs $recvfs2 a b c

log_pass "zfs send --delta sends blocks modified in place as patches"
