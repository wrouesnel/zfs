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
# Verify that the zstream subcommands handle "zfs send --delta" streams.
#
# Strategy:
# 1. Create a --refs --delta stream with both references and deltas.
# 2. zstream dump validates it, counts its DRR_WRITE_DELTA records (as
#    many as the send_delta_records kstat counted) and prints each one
#    with -v.
# 3. zstream redup refuses it.
# 4. zstream recompress and decompress pass the deltas through; the
#    results are received and verified.
# 5. zstream drop_records drops a delta; the result is received, and the
#    dropped block keeps its contents from the incremental source.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
stream=$BACKDIR/delta
out=$BACKDIR/delta.out
typeset -i nrec=8

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $stream $out $out.err $BACKDIR/full $BACKDIR/f1.*
}

log_assert "zstream handles zfs send --delta streams"
log_onexit cleanup

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE \
	-o compression=lz4 $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must cp $mntpnt/f1 $BACKDIR/f1.a
refs_copy $mntpnt/f1 $mntpnt/f2
typeset -i ndelta=0
for rec in 0 2 4 6; do
	refs_poke $mntpnt/f1 $rec
	(( ndelta += 1 ))
done
log_must zfs snapshot $sendfs@b
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

typeset -i records=$(send_refs_stat send_delta_records)
log_must eval "zfs send -c --refs --delta -i @a $sendfs@b >$stream"
log_must test $(send_refs_stat send_delta_records) -eq $((records + ndelta))
log_must stream_has_features $stream fromsnap_refs write_delta

# dump (which validates every record)
log_must eval "zstream dump $stream >$out"
log_must grep -q "Total DRR_WRITE_DELTA records = $ndelta " $out
log_must grep -q "Total DRR_WRITE_BYREF records = $nrec " $out
log_must eval "zstream dump -v $stream >$out"
log_must test "$(grep -c '^WRITE_DELTA object = ' $out)" -eq $ndelta
log_must eval "zstream dump <$stream >/dev/null"

# redup
log_mustnot eval "zstream redup $stream >$out 2>$out.err"
cat $out.err
log_must grep -q "zfs send --refs or --delta" $out.err

# recompress, decompress
for cmd in "recompress lz4" "recompress off" "decompress"; do
	log_must eval "zstream $cmd <$stream >$out"
	log_must stream_has_features $out fromsnap_refs write_delta
	log_must test "$(stream_delta_records $out)" -eq $ndelta
	log_must test "$(stream_byref_records $out)" -eq $nrec
	log_must eval "zfs recv -u $recvfs <$out"
	refs_cmp_snaps $sendfs $recvfs a b
	log_must zfs rollback -r $recvfs@a
done

# drop_records: drop the delta of f1's first record
typeset f1obj=$(get_objnum $mntpnt/f1)
log_must eval "zstream drop_records $f1obj,0 <$stream >$out"
log_must test "$(stream_delta_records $out)" -eq $((ndelta - 1))
log_must eval "zfs recv -u $recvfs <$out"
typeset recvdir=$(get_prop mountpoint $recvfs)/.zfs/snapshot/b
log_must eval "head -c $REFS_RECSIZE $recvdir/f1 >$BACKDIR/f1.recv0"
log_must eval "head -c $REFS_RECSIZE $BACKDIR/f1.a >$BACKDIR/f1.a0"
log_must cmp $BACKDIR/f1.recv0 $BACKDIR/f1.a0
log_must eval "tail -c +$((REFS_RECSIZE + 1)) $recvdir/f1 >$BACKDIR/f1.recv1"
log_must eval "tail -c +$((REFS_RECSIZE + 1)) $mntpnt/f1 >$BACKDIR/f1.b1"
log_must cmp $BACKDIR/f1.recv1 $BACKDIR/f1.b1

log_pass "zstream handles zfs send --delta streams"
