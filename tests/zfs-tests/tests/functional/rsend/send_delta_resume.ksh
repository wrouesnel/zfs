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
# Verify that an interrupted receive of a "zfs send --delta" stream can be
# resumed, and that the resumed send uses deltas too.
#
# Strategy:
# 1. Create a filesystem with three files of random data, snapshot @a and
#    replicate it.  Modify two of them in place in every record and
#    rewrite the third with unrelated data; snapshot @b.
# 2. Receive (-s) the first half of the send -i @a @b --delta stream (the
#    cut is in the third file's data).  The receive fails, and the resume
#    token has "deltaok".
# 3. "zfs send -t <token>" sends the rest with deltas for the files that
#    come after the third one, and it is received.  The received snapshot
#    is identical to the sent one.
# 4. Repeat with resume_test (random truncation or corruption, twice).
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
streamfs=$POOL/refs_stream
stream=$BACKDIR/delta
typeset -i nrec=16

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	datasetexists $streamfs && destroy_dataset $streamfs -r
	rm -f $stream $stream.* $BACKDIR/full
}

log_assert "An interrupted receive of a zfs send --delta stream can be" \
	"resumed with deltas"
log_onexit cleanup

log_must zfs create -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
# f1, u and f2 are created in this order so that (usually) u's object is
# between the others.
refs_mkfile $mntpnt/f1 $nrec
refs_mkfile $mntpnt/u $nrec
refs_mkfile $mntpnt/f2 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

for ((rec = 0; rec < nrec; rec++)); do
	refs_poke $mntpnt/f1 $rec
	refs_poke $mntpnt/f2 $rec
done
log_must eval "dd if=/dev/urandom of=$mntpnt/u bs=$REFS_RECSIZE \\
    count=$nrec conv=notrunc 2>/dev/null"
log_must zfs snapshot $sendfs@b

log_must eval "zfs send --delta -i @a $sendfs@b >$stream"
log_must stream_has_features $stream write_delta
log_must test "$(stream_delta_records $stream)" -eq $((2 * nrec))

# Cut the stream in the middle of u's new data.
typeset -i size=$(stat_size $stream)
log_must eval "head -c $((size / 2)) $stream >$stream.1"
log_mustnot eval "zfs recv -su $recvfs <$stream.1"
token=$(get_prop receive_resume_token $recvfs)
log_must test -n "$token" -a "$token" != "-"
log_must eval "zstream token $token | grep -qw deltaok"
log_must eval "zfs send -nvt $token 2>&1 | grep -qw deltaok"

log_must eval "zfs send -t $token >$stream.2"
log_must stream_has_features $stream.2 write_delta resuming
#
# The deltas of the files that come after u in object order are still to
# be sent.  Object numbers are allocated from per-CPU chunks, so that order
# is not necessarily creation order.
#
typeset -i uobj=$(get_objnum $mntpnt/u)
typeset -i expected=0
for f in f1 f2; do
	(( $(get_objnum $mntpnt/$f) > uobj )) && (( expected += nrec ))
done
typeset -i resumed=$(stream_delta_records $stream.2)
log_note "$resumed deltas in the resumed stream, $expected expected"
log_must test $resumed -eq $expected
log_must eval "zfs recv -su $recvfs <$stream.2"
refs_cmp_snaps $sendfs $recvfs a b

# Random interruptions.
log_must zfs rollback -r $recvfs@a
log_must zfs create $streamfs
resume_test "zfs send --delta -i @a $sendfs@b" $streamfs $recvfs
refs_cmp_snaps $sendfs $recvfs a b

log_pass "An interrupted receive of a zfs send --delta stream can be" \
	"resumed with deltas"
