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
# Verify that "zfs send --refs" sends blocks that are dedup hits on blocks
# of the incremental source as references, and that the receiver clones
# them from its copy of the incremental source.
#
# Strategy:
# 1. Create a dedup=on filesystem with a file of random data, snapshot @a
#    and replicate @a to another pool.
# 2. Copy the file and parts of it (at other offsets) with plain writes,
#    and write some unique data; snapshot @b.
# 3. Send -i @a @b with and without --refs.  The --refs stream has the
#    FROMSNAP_REFS feature, one DRR_WRITE_BYREF record per copied block,
#    and is much smaller.  The stream without --refs has neither.
# 4. Receive the --refs stream; the references are cloned on the receiving
#    pool and the received snapshots are identical to the sent ones.
# 5. An incremental from a bookmark of @a (the snapshot still exists) also
#    uses references.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
recvfs2=$POOL2/refs_recv_bm
refs=$BACKDIR/refs
plain=$BACKDIR/plain
bmrefs=$BACKDIR/bmrefs
typeset -i nrec=16

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	datasetexists $recvfs2 && destroy_dataset $recvfs2 -r
	[[ -n "$saved_bclone" ]] && set_tunable32 BCLONE_ENABLED $saved_bclone
	rm -f $refs $plain $bmrefs $BACKDIR/full
}

log_assert "zfs send --refs sends dedup hits on the incremental source" \
	"as references that the receiver clones"
log_onexit cleanup

saved_bclone=$(get_tunable BCLONE_ENABLED)
log_must set_tunable32 BCLONE_ENABLED 1

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must zfs bookmark $sendfs@a $sendfs#a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"
log_must eval "zfs recv -u $recvfs2 <$BACKDIR/full"

# f2: a copy of all of f1.  f3: records 4-11 of f1 at offset 0.
# f4: records 0-3 of f1 at records 2-5, around unique data.
refs_copy $mntpnt/f1 $mntpnt/f2
refs_copy $mntpnt/f1 $mntpnt/f3 4 8
refs_mkfile $mntpnt/f4 8
refs_copy $mntpnt/f1 $mntpnt/f4 0 4 2
refs_mkfile $mntpnt/unique 4
typeset -i nrefs=$((nrec + 8 + 4))
log_must zfs snapshot $sendfs@b

typeset -i records=$(send_refs_stat send_refs_records)
log_must eval "zfs send --refs -i @a $sendfs@b >$refs"
log_must eval "zfs send -i @a $sendfs@b >$plain"

log_must stream_has_features $refs fromsnap_refs
log_mustnot stream_has_features $plain fromsnap_refs
log_must test "$(stream_byref_records $refs)" -eq $nrefs
log_must test "$(stream_byref_records $plain)" -eq 0
log_must test $(send_refs_stat send_refs_records) -eq $((records + nrefs))

typeset -i refs_size=$(stat_size $refs)
typeset -i plain_size=$(stat_size $plain)
log_note "stream size: $refs_size with --refs, $plain_size without"
# With --refs only the 8 unique records are sent in full, of 36.
log_must test $((refs_size * 2)) -lt $plain_size

typeset -i cloned=$(send_refs_stat recv_refs_cloned)
typeset -i copied=$(send_refs_stat recv_refs_copied)
log_must eval "zfs recv -u $recvfs <$refs"
log_must test $(send_refs_stat recv_refs_cloned) -eq $((cloned + nrefs))
log_must test $(send_refs_stat recv_refs_copied) -eq $copied
sync_pool $POOL2
log_must test $(get_pool_prop bcloneused $POOL2) -gt 0
refs_cmp_snaps $sendfs $recvfs a b

# The received copy of f2 shares all of its blocks with f1 in @a.
typeset expected="$(seq -s ' ' 0 $((nrec - 1)) | sed 's/ $//')"
typeset same=$(get_same_blocks $recvfs@a f1 $recvfs@b f2)
log_must test "$same" = "$expected"

# The same, from a bookmark of @a.
log_must eval "zfs send --refs -i $sendfs#a $sendfs@b >$bmrefs"
log_must stream_has_features $bmrefs fromsnap_refs
log_must test "$(stream_byref_records $bmrefs)" -eq $nrefs
log_must eval "zfs recv -u $recvfs2 <$bmrefs"
refs_cmp_snaps $sendfs $recvfs2 a b

log_pass "zfs send --refs sends dedup hits on the incremental source" \
	"as references that the receiver clones"
