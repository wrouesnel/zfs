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
# Verify that a "zfs send --refs" stream can be received where block
# cloning is not available: the referenced blocks are read from the
# receiver's copy of the incremental source and written again.
#
# Strategy:
# 1. Create a dedup=on filesystem with a file of random data, snapshot @a,
#    copy the file with plain writes and snapshot @b.  Send -i @a @b --refs.
# 2. Receive @a and then the --refs stream into a pool created with
#    feature@block_cloning disabled: every reference is copied, none is
#    cloned, and the received snapshots are identical to the sent ones.
# 3. Do the same on a pool with block cloning enabled, with
#    zfs_bclone_enabled=0.
#

verify_runnable "both"

sendfs=$POOL/refs_send
nobcpool=refs_nobc
nobcvdev=$TESTDIR/refs_nobc_vdev
recvfs=$nobcpool/refs_recv
recvfs2=$POOL2/refs_recv
refs=$BACKDIR/refs
typeset -i nrec=16

function cleanup
{
	poolexists $nobcpool && destroy_pool $nobcpool
	rm -f $nobcvdev
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs2 && destroy_dataset $recvfs2 -r
	[[ -n "$saved_bclone" ]] && set_tunable32 BCLONE_ENABLED $saved_bclone
	rm -f $refs $BACKDIR/full
}

#
# Receive the full and the --refs stream into $1 and verify that all
# references were copied.
#
function recv_copied
{
	typeset fs=$1
	typeset -i cloned=$(send_refs_stat recv_refs_cloned)
	typeset -i copied=$(send_refs_stat recv_refs_copied)

	log_must eval "zfs recv -u $fs <$BACKDIR/full"
	log_must eval "zfs recv -u $fs <$refs"
	log_must test $(send_refs_stat recv_refs_cloned) -eq $cloned
	log_must test $(send_refs_stat recv_refs_copied) -eq $((copied + nrefs))
	refs_cmp_snaps $sendfs $fs a b
}

log_assert "zfs send --refs streams are received by copying where block" \
	"cloning is not available"
log_onexit cleanup

saved_bclone=$(get_tunable BCLONE_ENABLED)

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
refs_copy $mntpnt/f1 $mntpnt/f2
refs_copy $mntpnt/f1 $mntpnt/f3 3 5 1
typeset -i nrefs=$((nrec + 5))
log_must zfs snapshot $sendfs@b
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs send --refs -i @a $sendfs@b >$refs"
log_must stream_has_features $refs fromsnap_refs
log_must test "$(stream_byref_records $refs)" -eq $nrefs

# A pool without the block_cloning feature.
log_must truncate -s $MINVDEVSIZE $nobcvdev
log_must zpool create -o feature@block_cloning=disabled $nobcpool $nobcvdev
log_must test "$(get_pool_prop feature@block_cloning $nobcpool)" = "disabled"
log_must set_tunable32 BCLONE_ENABLED 1
recv_copied $recvfs
log_must test "$(get_pool_prop feature@block_cloning $nobcpool)" = "disabled"

# A pool with block cloning, disabled by the tunable.
log_must set_tunable32 BCLONE_ENABLED 0
recv_copied $recvfs2

log_pass "zfs send --refs streams are received by copying where block" \
	"cloning is not available"
