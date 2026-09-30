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
# Verify that "zfs send -R --refs -I" uses references in each incremental
# of the replication stream.
#
# Strategy:
# 1. Create a dedup=on filesystem and a child, each with a file of random
#    data, snapshot -r @a and replicate @a.
# 2. In each filesystem, copy the file and snapshot -r @b; copy the file
#    and the copy again and snapshot -r @c.
# 3. send -R --refs -I @a @c: every copied block is a reference, in each of
#    the four incrementals.
# 4. Receive it; every snapshot is identical to the sent one.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
stream=$BACKDIR/refs
typeset -i nrec=8

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $stream $BACKDIR/full
}

log_assert "zfs send -R --refs -I uses references in every incremental"
log_onexit cleanup

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
log_must zfs create $sendfs/child
for fs in $sendfs $sendfs/child; do
	refs_mkfile $(get_prop mountpoint $fs)/f1 $nrec
done
log_must zfs snapshot -r $sendfs@a
log_must eval "zfs send -R $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

for fs in $sendfs $sendfs/child; do
	mntpnt=$(get_prop mountpoint $fs)
	refs_copy $mntpnt/f1 $mntpnt/f2
done
log_must zfs snapshot -r $sendfs@b
for fs in $sendfs $sendfs/child; do
	mntpnt=$(get_prop mountpoint $fs)
	refs_copy $mntpnt/f1 $mntpnt/f3
	# half of f4 references @b's f2, which is not in @a
	refs_copy $mntpnt/f2 $mntpnt/f4 0 $((nrec / 2))
done
log_must zfs snapshot -r $sendfs@c

# (a..b) nrec and (b..c) nrec + nrec / 2, in each of two filesystems
typeset -i nrefs=$((2 * (2 * nrec + nrec / 2)))
log_must eval "zfs send -R --refs -I @a $sendfs@c >$stream"
log_must stream_has_features $stream fromsnap_refs
log_must test "$(stream_byref_records $stream)" -eq $nrefs
# All four incremental streams in the package use references.
typeset -i nsub=0
for f in $(zstream dump $stream | awk '/features = / { print $3 }'); do
	(( (0x$f & 0x80000000) != 0 )) && nsub=$((nsub + 1))
done
log_must test $nsub -eq 4

typeset -i cloned=$(send_refs_stat recv_refs_cloned)
typeset -i copied=$(send_refs_stat recv_refs_copied)
log_must eval "zfs recv -Fu $recvfs <$stream"
log_must test $(( $(send_refs_stat recv_refs_cloned) - cloned + \
    $(send_refs_stat recv_refs_copied) - copied )) -eq $nrefs
log_must cmp_ds_subs $sendfs $recvfs
refs_cmp_snaps $sendfs $recvfs a b c
refs_cmp_snaps $sendfs/child $recvfs/child a b c

log_pass "zfs send -R --refs -I uses references in every incremental"
