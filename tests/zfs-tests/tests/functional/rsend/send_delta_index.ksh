#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0

# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.

. $STF_SUITE/tests/functional/rsend/rsend.kshlib

# Description:
# Verify that a similarity index built ahead of time with
# "zfs send --build-delta-index" gives the same --delta stream as one built
# during the send, and that indexes of the wrong snapshot or damaged ones
# are refused.
# Strategy:
# 1. Create a filesystem with a file, snapshot @a, write a new file whose
#    records are slightly changed copies of records of the first, and
#    snapshot @b.
# 2. Build the index of @a.  Send -i @a @b --delta with and without it:
#    the streams are identical and the index was loaded.  Receive it.
# 3. An index of @b, a truncated index and one with a bad entry are
#    refused, as is --delta-index without --delta or with -I.

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
idx=$BACKDIR/index
typeset -i nrec=16

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $idx $idx.* $BACKDIR/full $BACKDIR/built $BACKDIR/loaded
}

log_assert "zfs send --delta-index uses a similarity index built ahead of time"
log_onexit cleanup

log_must zfs create -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

refs_mkfile $mntpnt/g 4
refs_copy $mntpnt/f1 $mntpnt/g 3 1 1
refs_copy $mntpnt/f1 $mntpnt/g 9 1 3
refs_poke $mntpnt/g 1 5000 8
refs_poke $mntpnt/g 3 100000 8
log_must zfs snapshot $sendfs@b

log_must eval "zfs send --build-delta-index $sendfs@a >$idx"
log_must test $(stat_size $idx) -gt 64

log_must eval "zfs send --delta -i @a $sendfs@b >$BACKDIR/built"
typeset -i loaded=$(send_refs_stat send_delta_index_loaded)
log_must eval "zfs send --delta --delta-index $idx -i @a $sendfs@b \
    >$BACKDIR/loaded"
log_must test $(send_refs_stat send_delta_index_loaded) -eq $((loaded + 1))
log_must cmp $BACKDIR/built $BACKDIR/loaded
log_must test "$(stream_delta_records $BACKDIR/loaded)" -eq 2
log_must eval "zfs recv -u $recvfs <$BACKDIR/loaded"
refs_cmp_snaps $sendfs $recvfs a b

# The index of another snapshot.
log_must eval "zfs send --build-delta-index $sendfs@b >$idx.b"
log_mustnot eval "zfs send --delta --delta-index $idx.b -i @a $sendfs@b \
    >/dev/null"
# Truncated.
log_must eval "head -c 100 $idx >$idx.short"
log_mustnot eval "zfs send --delta --delta-index $idx.short -i @a \
    $sendfs@b >/dev/null"
# The first entry's length is not a block size.
log_must cp $idx $idx.bad
log_must eval "printf '\\377\\377\\377\\377' | dd of=$idx.bad bs=1 seek=88 \
    conv=notrunc 2>/dev/null"
log_mustnot eval "zfs send --delta --delta-index $idx.bad -i @a $sendfs@b \
    >/dev/null"
# Bad combinations.
log_mustnot eval "zfs send --delta-index $idx -i @a $sendfs@b >/dev/null"
log_mustnot eval "zfs send --delta --delta-index $idx -I @a $sendfs@b \
    >/dev/null"

log_pass "zfs send --delta-index uses a similarity index built ahead of time"
