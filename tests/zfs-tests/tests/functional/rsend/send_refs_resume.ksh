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
# Verify that an interrupted receive of a "zfs send --refs" stream can be
# resumed, and that the resumed send uses references too.
#
# Strategy:
# 1. Create a dedup=on filesystem with a file of random data, snapshot @a
#    and replicate it.  Write a copy of the file, unique data and another
#    copy (so that references come before and after the unique data in the
#    stream) and snapshot @b.
# 2. Receive (-s) the first half of the send -i @a @b --refs stream.  The
#    receive fails, and the resume token has "refsok".
# 3. "zfs send -t <token>" sends the rest with references, and it is
#    received.  The received snapshot is identical to the sent one.
# 4. Repeat with resume_test (random truncation or corruption, twice).
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
streamfs=$POOL/refs_stream
stream=$BACKDIR/refs
typeset -i nrec=16

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	datasetexists $streamfs && destroy_dataset $streamfs -r
	rm -f $stream $stream.* $BACKDIR/full
}

log_assert "An interrupted receive of a zfs send --refs stream can be resumed" \
	"with references"
log_onexit cleanup

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

refs_copy $mntpnt/f1 $mntpnt/f2
refs_mkfile $mntpnt/f3 $nrec
refs_copy $mntpnt/f1 $mntpnt/f4
log_must zfs snapshot $sendfs@b

log_must eval "zfs send --refs -i @a $sendfs@b >$stream"
log_must stream_has_features $stream fromsnap_refs
log_must test "$(stream_byref_records $stream)" -eq $((2 * nrec))

# Cut the stream in the middle of f3's data.
typeset -i size=$(stat_size $stream)
log_must eval "head -c $((size / 2)) $stream >$stream.1"
log_mustnot eval "zfs recv -su $recvfs <$stream.1"
token=$(get_prop receive_resume_token $recvfs)
log_must test -n "$token" -a "$token" != "-"
log_must eval "zstream token $token | grep -qw refsok"
log_must eval "zfs send -nvt $token 2>&1 | grep -qw refsok"

log_must eval "zfs send -t $token >$stream.2"
log_must stream_has_features $stream.2 fromsnap_refs resuming
#
# The cut is in f3's data, so the references of the copies that come after
# f3 in object order are still to be sent.  Object numbers are allocated
# from per-CPU chunks, so that order is not necessarily creation order.
#
typeset -i f3obj=$(ls -i $mntpnt/f3 | awk '{print $1}')
typeset -i expected=0
for f in f2 f4; do
	(( $(ls -i $mntpnt/$f | awk '{print $1}') > f3obj )) && \
	    (( expected += nrec ))
done
typeset -i resumed=$(stream_byref_records $stream.2)
log_note "$resumed references in the resumed stream, $expected expected"
log_must test $resumed -eq $expected
log_must eval "zfs recv -su $recvfs <$stream.2"
refs_cmp_snaps $sendfs $recvfs a b

# Random interruptions.
log_must zfs rollback -r $recvfs@a
log_must zfs create $streamfs
resume_test "zfs send --refs -i @a $sendfs@b" $streamfs $recvfs
refs_cmp_snaps $sendfs $recvfs a b

log_pass "An interrupted receive of a zfs send --refs stream can be resumed" \
	"with references"
