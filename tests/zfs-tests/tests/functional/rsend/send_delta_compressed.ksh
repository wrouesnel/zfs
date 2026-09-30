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
# Verify that "zfs send -c --delta" sends patches of compressed blocks,
# computed on their logical data.
#
# Strategy:
# 1. Create a compression=lz4 filesystem with a compressible file,
#    snapshot @a and replicate it.
# 2. Overwrite a few bytes in some records; snapshot @b.
# 3. Send -c -i @a @b --delta: the stream has the COMPRESSED and
#    WRITE_DELTA features, the modified records are DRR_WRITE_DELTA
#    records, and it is much smaller than without --delta.
# 4. Receive it, also into a filesystem whose copy of @a was received
#    without -c and stored with another compression; both are identical
#    to the sent snapshots.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
recvfs2=$POOL2/refs_recv_gzip
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

log_assert "zfs send -c --delta sends patches of compressed blocks"
log_onexit cleanup

log_must zfs create -o compression=lz4 -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
# Compressible text in which no two records are alike.
typeset prog='BEGIN { srand() } { print "record", $1, int(rand() * 100000) }'
log_must eval "seq 1 200000 | awk '$prog' | \\
    head -c $((nrec * REFS_RECSIZE)) >$mntpnt/f1"
log_must test $(stat_size $mntpnt/f1) -eq $((nrec * REFS_RECSIZE))
log_must zfs snapshot $sendfs@a
sync_pool $POOL
log_note "compressratio $(get_prop compressratio $sendfs)"
log_must test "$(get_prop compressratio $sendfs | tr -d x)" != "1.00"
log_must eval "zfs send -c $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u -o compression=gzip $recvfs2 <$BACKDIR/full"

typeset -i ndelta=0
for rec in 0 4 8 12 15; do
	refs_poke $mntpnt/f1 $rec 2000 8
	(( ndelta += 1 ))
done
log_must zfs snapshot $sendfs@b

log_must eval "zfs send -c --delta -i @a $sendfs@b >$delta"
log_must eval "zfs send -c -i @a $sendfs@b >$plain"
log_must stream_has_features $delta compressed write_delta
log_must test "$(stream_delta_records $delta)" -eq $ndelta
typeset -i delta_size=$(stat_size $delta)
typeset -i plain_size=$(stat_size $plain)
log_note "stream size: $delta_size with --delta, $plain_size without"
log_must test $((delta_size * 4)) -lt $plain_size

log_must eval "zfs recv -u $recvfs <$delta"
refs_cmp_snaps $sendfs $recvfs a b
log_must eval "zfs recv -u $recvfs2 <$delta"
refs_cmp_snaps $sendfs $recvfs2 a b

log_pass "zfs send -c --delta sends patches of compressed blocks"
