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
# Verify that "zfs send --refs" and "--delta" work when the incremental
# source's objset is not yet open, on the sending and the receiving side:
# both open it themselves and must do so with the pool config lock held.
#
# Strategy:
# 1. Create a dedup=on filesystem with a file of random data, snapshot @a
#    and replicate @a to another pool.
# 2. Copy the file (references) and modify a few records of the original
#    in place (deltas); snapshot @b.
# 3. For --refs, --delta and both: export and import both pools, so that
#    no objset of either is open, then send -i @a @b, receive it and
#    compare the received snapshots with the sent ones.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
stream=$BACKDIR/reimport
typeset -i nrec=8

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $stream $BACKDIR/full
}

function reimport_pools
{
	log_must_busy zpool export $POOL2
	log_must zpool import $POOL2
	log_must_busy zpool export $POOL
	log_must zpool import $POOL
}

log_assert "zfs send --refs and --delta work with the incremental source's" \
	"objsets not yet open"
log_onexit cleanup

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

refs_copy $mntpnt/f1 $mntpnt/f2
refs_poke $mntpnt/f1 1
refs_poke $mntpnt/f1 5
log_must zfs snapshot $sendfs@b

for opts in "--refs" "--delta" "--refs --delta"; do
	reimport_pools
	log_must eval "zfs send $opts -i @a $sendfs@b >$stream"
	log_must eval "zfs recv -u $recvfs <$stream"
	refs_cmp_snaps $sendfs $recvfs a b
	log_must zfs rollback -r $recvfs@a
done

log_pass "zfs send --refs and --delta work with the incremental source's" \
	"objsets not yet open"
