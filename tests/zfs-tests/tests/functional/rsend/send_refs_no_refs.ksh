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
# Verify that "zfs send --refs" produces a regular stream, without the
# FROMSNAP_REFS feature, when there is nothing to reference.
#
# Strategy:
# 1. Without dedup or block cloning, send -i @a @b --refs: the stream has
#    no FROMSNAP_REFS feature and no DRR_WRITE_BYREF records.
# 2. With dedup=on but only duplicates among blocks written after @a
#    (they are not in the incremental source), the same.
# 3. From a bookmark whose snapshot was destroyed there is no incremental
#    source to reference, even though the data is duplicated (and is sent
#    by reference from the snapshot): the same.
# 4. Every stream is received and verified.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
stream=$BACKDIR/refs

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $stream $BACKDIR/full
}

#
# Send $sendfs from $1 to @$2 with --refs, verify that the stream has no
# references, receive it into $recvfs and verify it.
#
function send_no_refs
{
	typeset from=$1
	typeset to=$2
	typeset -i records=$(send_refs_stat send_refs_records)

	log_must eval "zfs send --refs -i $from $sendfs@$to >$stream"
	log_mustnot stream_has_features $stream fromsnap_refs
	log_must test "$(stream_byref_records $stream)" -eq 0
	log_must test $(send_refs_stat send_refs_records) -eq $records
	log_must eval "zfs recv -u $recvfs <$stream"
	refs_cmp_snaps $sendfs $recvfs $to
}

log_assert "zfs send --refs sends a regular stream when there is nothing" \
	"to reference"
log_onexit cleanup

log_must zfs create -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 8
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

# No dedup, no clones: plain copies are new blocks.
refs_copy $mntpnt/f1 $mntpnt/f2
refs_mkfile $mntpnt/f3 4
log_must zfs snapshot $sendfs@b
send_no_refs @a b

# With dedup=on: g2 (in @d) is a dedup hit on g1 (in @c), so from @c
# there is something to reference.
log_must zfs set dedup=on $sendfs
refs_mkfile $mntpnt/g1 4
log_must zfs snapshot $sendfs@c
log_must zfs bookmark $sendfs@c $sendfs#c
refs_copy $mntpnt/g1 $mntpnt/g2
log_must zfs snapshot $sendfs@d
log_must eval "zfs send -i @b $sendfs@c >$stream"
log_must eval "zfs recv -u $recvfs <$stream"
log_must eval "zfs send --refs -i @c $sendfs@d >$stream"
log_must stream_has_features $stream fromsnap_refs
log_must eval "zfs recv -u $recvfs <$stream"

# Dedup hits among blocks written after @d only.
refs_mkfile $mntpnt/h1 4
refs_copy $mntpnt/h1 $mntpnt/h2
log_must zfs snapshot $sendfs@e
send_no_refs @d e

# g2 (in @d) is a dedup hit on g1 (in @c), but once @c is destroyed an
# incremental from its bookmark has nothing to reference.
log_must zfs destroy $sendfs@c
log_must zfs rollback -r $recvfs@c
send_no_refs $sendfs#c d

log_pass "zfs send --refs sends a regular stream when there is nothing" \
	"to reference"
