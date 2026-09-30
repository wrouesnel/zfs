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
. $STF_SUITE/tests/functional/block_cloning/block_cloning.kshlib

#
# Description:
# Verify that "zfs send --refs" sends block clones of blocks of the
# incremental source as references, and that the receiver clones them.
#
# Strategy:
# 1. Create a filesystem (dedup=off) with a file of random data, snapshot
#    @a and replicate @a to another pool.
# 2. Clone all of the file, and a range of it to another offset, with
#    copy_file_range.  Also write a new file and clone it: those blocks
#    are born after @a and must be sent in full.  Snapshot @b.
# 3. Send -i @a @b --refs: the stream has the FROMSNAP_REFS feature and one
#    DRR_WRITE_BYREF record per block cloned from @a, and nothing else.
# 4. Receive it: the references are cloned and the received snapshots are
#    identical to the sent ones.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
refs=$BACKDIR/refs
plain=$BACKDIR/plain
typeset -i nrec=16

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	[[ -n "$saved_bclone" ]] && set_tunable32 BCLONE_ENABLED $saved_bclone
	rm -f $refs $plain $BACKDIR/full
}

log_assert "zfs send --refs sends block clones of the incremental source" \
	"as references that the receiver clones"
log_onexit cleanup

saved_bclone=$(get_tunable BCLONE_ENABLED)
log_must set_tunable32 BCLONE_ENABLED 1

log_must zfs create -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

typeset -i used=$(get_pool_prop bcloneused $POOL)

# f2: a clone of all of f1.  f3: a clone of records 4-11 of f1 at record 2.
log_must clonefile -f $mntpnt/f1 $mntpnt/f2
log_must clonefile -f $mntpnt/f1 $mntpnt/f3 $((4 * REFS_RECSIZE)) \
	$((2 * REFS_RECSIZE)) $((8 * REFS_RECSIZE))
typeset -i nrefs=$((nrec + 8))
# g1 and its clone g2 are born after @a: not references.
refs_mkfile $mntpnt/g1 4
sync_pool $POOL
log_must clonefile -f $mntpnt/g1 $mntpnt/g2
log_must zfs snapshot $sendfs@b
sync_pool $POOL
log_must test $(get_pool_prop bcloneused $POOL) -gt $used

log_must eval "zfs send --refs -i @a $sendfs@b >$refs"
log_must eval "zfs send -i @a $sendfs@b >$plain"
log_must stream_has_features $refs fromsnap_refs
log_must test "$(stream_byref_records $refs)" -eq $nrefs
log_must test "$(stream_byref_records $plain)" -eq 0
typeset -i refs_size=$(stat_size $refs)
typeset -i plain_size=$(stat_size $plain)
log_note "stream size: $refs_size with --refs, $plain_size without"
log_must test $((refs_size * 2)) -lt $plain_size

typeset -i cloned=$(send_refs_stat recv_refs_cloned)
log_must eval "zfs recv -u $recvfs <$refs"
log_must test $(send_refs_stat recv_refs_cloned) -eq $((cloned + nrefs))
refs_cmp_snaps $sendfs $recvfs a b

typeset expected="$(seq -s ' ' 0 $((nrec - 1)) | sed 's/ $//')"
typeset same=$(get_same_blocks $recvfs@a f1 $recvfs@b f2)
log_must test "$same" = "$expected"

log_pass "zfs send --refs sends block clones of the incremental source" \
	"as references that the receiver clones"
