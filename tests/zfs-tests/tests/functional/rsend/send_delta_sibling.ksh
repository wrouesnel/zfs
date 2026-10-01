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
# Verify that "zfs send --refs --delta" sends the modified blocks of a copy
# of a file in the incremental source as patches against the file it was
# copied from, and its unmodified blocks as references; and that --delta
# alone sends no references.
#
# Strategy:
# 1. Create a dedup=on filesystem with a file of random data, snapshot @a
#    and replicate it.
# 2. Copy the file with plain writes (dedup hits), then overwrite a few
#    bytes in some records of the copy; snapshot @b.
# 3. Send -i @a @b --refs --delta: the unmodified records of the copy are
#    DRR_WRITE_BYREF records, the modified ones DRR_WRITE_DELTA records
#    against the original ("sibling" hits).
# 4. Receive it; the received snapshots are identical to the sent ones.
# 5. Send -i @a @b --delta alone: the stream has no FROMSNAP_REFS feature
#    and no DRR_WRITE_BYREF records, and no sibling candidates are used.
#    It is received too.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
delta=$BACKDIR/delta
typeset -i nrec=16

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $delta $BACKDIR/full
}

log_assert "zfs send --refs --delta sends modified blocks of a copied file" \
	"as patches against the original"
log_onexit cleanup

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

refs_copy $mntpnt/f1 $mntpnt/f2
typeset -i ndelta=0
for rec in 2 3 10 15; do
	refs_poke $mntpnt/f2 $rec 4000 16
	(( ndelta += 1 ))
done
log_must zfs snapshot $sendfs@b

typeset -i sibling=$(send_refs_stat send_delta_sibling_hits)
log_must eval "zfs send --refs --delta -i @a $sendfs@b >$delta"
log_must stream_has_features $delta fromsnap_refs write_delta
log_must test "$(stream_byref_records $delta)" -eq $((nrec - ndelta))
log_must test "$(stream_delta_records $delta)" -eq $ndelta
log_must test $(send_refs_stat send_delta_sibling_hits) -eq \
	$((sibling + ndelta))
# The deltas are against f1.
typeset -i f1obj=$(get_objnum $mntpnt/f1)
typeset refobjs=$(zstream dump -v $delta | \
	awk '/^WRITE_DELTA / { print $22 }' | sort -u)
log_must test "$refobjs" = "$f1obj"
typeset -i size=$(stat_size $delta)
log_note "stream size: $size"
log_must test $size -lt $((2 * REFS_RECSIZE))

typeset -i recv=$(send_refs_stat recv_delta_records)
log_must eval "zfs recv -u $recvfs <$delta"
log_must test $(send_refs_stat recv_delta_records) -eq $((recv + ndelta))
refs_cmp_snaps $sendfs $recvfs a b

# --delta without --refs
log_must zfs rollback -r $recvfs@a
sibling=$(send_refs_stat send_delta_sibling_hits)
log_must eval "zfs send --delta -i @a $sendfs@b >$delta"
log_must stream_has_features $delta write_delta
log_mustnot stream_has_features $delta fromsnap_refs
log_must test "$(stream_byref_records $delta)" -eq 0
log_must test $(send_refs_stat send_delta_sibling_hits) -eq $sibling
log_must eval "zfs recv -u $recvfs <$delta"
refs_cmp_snaps $sendfs $recvfs a b

log_pass "zfs send --refs --delta sends modified blocks of a copied file" \
	"as patches against the original"
