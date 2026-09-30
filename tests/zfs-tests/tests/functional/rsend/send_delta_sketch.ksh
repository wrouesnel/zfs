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
# Verify that "zfs send --delta" finds similar blocks anywhere in the
# incremental source with its similarity (sketch) index, and that the
# index can be limited or disabled.
#
# Strategy:
# 1. Create a filesystem (dedup=off) with a file of random data, snapshot
#    @a and replicate it.
# 2. Write a new file whose records 1 and 3 are records 3 and 9 of the
#    first file with a few bytes changed, and whose records 0 and 2 are
#    unique; snapshot @b.
# 3. Send -i @a @b --delta: the two similar records are DRR_WRITE_DELTA
#    records ("sketch" hits) against the right blocks.  Receive and verify.
# 4. With zfs_send_delta_sketch_max_blocks=0 or
#    zfs_send_delta_sketch_max_bytes=0 no index is built: no deltas, but
#    the stream still has the WRITE_DELTA feature.  Receive and verify.
# 5. With zfs_send_delta_sketch_max_blocks=4 the index is truncated.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
delta=$BACKDIR/delta
typeset -i nrec=16

function cleanup
{
	[[ -n "$saved_blocks" ]] && \
	    set_tunable64 SEND_DELTA_SKETCH_MAX_BLOCKS $saved_blocks
	[[ -n "$saved_bytes" ]] && \
	    set_tunable64 SEND_DELTA_SKETCH_MAX_BYTES $saved_bytes
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $delta $BACKDIR/full
}

#
# Send -i @a @b --delta, verify the number of delta records and sketch
# hits, and receive the stream.
#
function send_sketch
{
	typeset -i expected=$1
	typeset -i hits=$(send_refs_stat send_delta_sketch_hits)

	log_must eval "zfs send --delta -i @a $sendfs@b >$delta"
	log_must stream_has_features $delta write_delta
	log_must test "$(stream_delta_records $delta)" -eq $expected
	log_must test $(send_refs_stat send_delta_sketch_hits) -eq \
	    $((hits + expected))
	log_must eval "zfs recv -u $recvfs <$delta"
	refs_cmp_snaps $sendfs $recvfs a b
	log_must zfs rollback -r $recvfs@a
}

log_assert "zfs send --delta finds similar blocks with its sketch index"
log_onexit cleanup

saved_blocks=$(get_tunable SEND_DELTA_SKETCH_MAX_BLOCKS)
saved_bytes=$(get_tunable SEND_DELTA_SKETCH_MAX_BYTES)

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

typeset -i sketched=$(send_refs_stat send_delta_sketch_blocks)
send_sketch 2
log_must test $(send_refs_stat send_delta_sketch_blocks) -ge \
	$((sketched + nrec))

# The deltas are against records 3 and 9 of f1.
typeset -i f1obj=$(get_objnum $mntpnt/f1)
log_must eval "zfs send --delta -i @a $sendfs@b >$delta"
typeset refs=$(zstream dump -v $delta | \
	awk '/^WRITE_DELTA / { print $22, $25 }' | xargs)
log_must test "$refs" = \
	"$f1obj $((3 * REFS_RECSIZE)) $f1obj $((9 * REFS_RECSIZE))"

# No index.
log_must set_tunable64 SEND_DELTA_SKETCH_MAX_BLOCKS 0
sketched=$(send_refs_stat send_delta_sketch_blocks)
send_sketch 0
log_must test $(send_refs_stat send_delta_sketch_blocks) -eq $sketched
log_must set_tunable64 SEND_DELTA_SKETCH_MAX_BLOCKS $saved_blocks
log_must set_tunable64 SEND_DELTA_SKETCH_MAX_BYTES 0
send_sketch 0
log_must test $(send_refs_stat send_delta_sketch_blocks) -eq $sketched
log_must set_tunable64 SEND_DELTA_SKETCH_MAX_BYTES $saved_bytes

# A truncated index.
log_must set_tunable64 SEND_DELTA_SKETCH_MAX_BLOCKS 4
typeset -i truncated=$(send_refs_stat send_delta_sketch_truncated)
log_must eval "zfs send --delta -i @a $sendfs@b >$delta"
log_must test $(send_refs_stat send_delta_sketch_truncated) -gt $truncated
log_must test $(send_refs_stat send_delta_sketch_blocks) -eq $((sketched + 4))
log_must eval "zfs recv -u $recvfs <$delta"
refs_cmp_snaps $sendfs $recvfs a b

log_pass "zfs send --delta finds similar blocks with its sketch index"
