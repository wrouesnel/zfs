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
# Verify that "zfs send --delta" only sends a patch that is at most
# zfs_send_delta_max_pct percent of the size of the block.
#
# Strategy:
# 1. Create a filesystem with a file of random data, snapshot @a and
#    replicate it.  Overwrite 5% of one record and 70% of two others with
#    random data; snapshot @b.
# 2. With the default zfs_send_delta_max_pct (50), only the first record
#    is sent as a delta; the others are rejected and sent in full.
# 3. With zfs_send_delta_max_pct=100 all three are deltas; with
#    zfs_send_delta_max_pct=0 none is even attempted.
# 4. Every stream is received and verified.
#

verify_runnable "both"

sendfs=$POOL/refs_send
recvfs=$POOL2/refs_recv
delta=$BACKDIR/delta
typeset -i nrec=8

function cleanup
{
	[[ -n "$saved_pct" ]] && set_tunable32 SEND_DELTA_MAX_PCT $saved_pct
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $delta $BACKDIR/full
}

#
# Send -i @a @b --delta with zfs_send_delta_max_pct=$1, expecting $2 delta
# records, and at least $3 rejected patches; receive and verify.
#
function send_pct
{
	typeset -i pct=$1
	typeset -i expected=$2
	typeset -i rejects=$3

	log_must set_tunable32 SEND_DELTA_MAX_PCT $pct
	typeset -i rejected=$(send_refs_stat send_delta_rejected)
	typeset -i attempts=$(send_refs_stat send_delta_attempts)
	log_must eval "zfs send --delta -i @a $sendfs@b >$delta"
	log_must stream_has_features $delta write_delta
	log_must test "$(stream_delta_records $delta)" -eq $expected
	log_must test $(send_refs_stat send_delta_rejected) -ge \
	    $((rejected + rejects))
	if [[ $pct -eq 0 ]]; then
		log_must test $(send_refs_stat send_delta_attempts) -eq \
		    $attempts
	fi
	log_note "max_pct $pct: $(stat_size $delta) bytes"
	log_must eval "zfs recv -u $recvfs <$delta"
	refs_cmp_snaps $sendfs $recvfs a b
	log_must zfs rollback -r $recvfs@a
}

log_assert "zfs send --delta only sends patches of at most" \
	"zfs_send_delta_max_pct percent of the block"
log_onexit cleanup

saved_pct=$(get_tunable SEND_DELTA_MAX_PCT)

log_must zfs create -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"

refs_poke $mntpnt/f1 1 0 $((REFS_RECSIZE * 5 / 100))
refs_poke $mntpnt/f1 3 0 $((REFS_RECSIZE * 70 / 100))
refs_poke $mntpnt/f1 6 1000 $((REFS_RECSIZE * 70 / 100))
log_must zfs snapshot $sendfs@b

send_pct 50 1 2
send_pct 100 3 0
send_pct 0 0 0

log_pass "zfs send --delta only sends patches of at most" \
	"zfs_send_delta_max_pct percent of the block"
