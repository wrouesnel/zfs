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
# Verify that "zfs send --refs" is refused where it is not supported, and
# ignored for non-raw sends of encrypted datasets.
#
# Strategy:
# 1. --refs is refused for raw (-w), redacted (--redact) and full sends,
#    and with -S, while the same sends without --refs succeed.
# 2. --refs for a non-raw incremental of an encrypted dataset with dedup
#    hits on its incremental source succeeds and sends a regular stream,
#    which is received and verified.
#

verify_runnable "both"

sendfs=$POOL/refs_send
rclone=$POOL/refs_rclone
encfs=$POOL/refs_enc
recvfs=$POOL2/refs_recv
stream=$BACKDIR/refs
errfile=$BACKDIR/refs.err
keyfile=$BACKDIR/refs.key

function cleanup
{
	datasetexists $rclone && destroy_dataset $rclone -r
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $encfs && destroy_dataset $encfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $stream $errfile $keyfile $BACKDIR/full
}

#
# Verify that "zfs send <args>" fails with an error containing $1.
#
function send_refused
{
	typeset msg=$1
	shift

	log_mustnot eval "zfs send $* >$stream 2>$errfile"
	cat $errfile
	log_must grep -q -- "$msg" $errfile
}

log_assert "zfs send --refs is refused or ignored where it is not supported"
log_onexit cleanup

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 4
log_must zfs snapshot $sendfs@a
refs_copy $mntpnt/f1 $mntpnt/f2
log_must zfs snapshot $sendfs@b

# Raw sends.
log_must eval "zfs send -w -i @a $sendfs@b >$stream"
send_refused "cannot be used with raw sends" --refs -w -i @a $sendfs@b
send_refused "cannot be used with raw sends" -w --refs $sendfs@b

# Full sends, also replication streams.
log_must eval "zfs send $sendfs@b >$stream"
send_refused "cannot be used with full sends" --refs $sendfs@b
send_refused "cannot be used with full sends" --refs -R $sendfs@b

# Redacted sends.
log_must zfs clone $sendfs@b $rclone
log_must rm $(get_prop mountpoint $rclone)/f2
log_must zfs snapshot $rclone@s
log_must zfs redact $sendfs@b book $rclone@s
log_must eval "zfs send --redact book -i @a $sendfs@b >$stream"
send_refused "cannot be used with redacted sends" \
	--refs --redact book -i @a $sendfs@b

# Saved sends.
send_refused "incompatible flags" -S --refs $sendfs

# Encrypted dataset, non-raw: accepted, and a regular stream is sent even
# though f2 is a dedup hit on f1.
log_must eval "echo 'password' >$keyfile"
log_must zfs create -o encryption=on -o keyformat=passphrase \
	-o keylocation=file://$keyfile -o dedup=on \
	-o recordsize=$REFS_RECSIZE $encfs
mntpnt=$(get_prop mountpoint $encfs)
refs_mkfile $mntpnt/f1 4
log_must zfs snapshot $encfs@a
refs_copy $mntpnt/f1 $mntpnt/f2
log_must zfs snapshot $encfs@b
log_must eval "zfs send $encfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"
log_must eval "zfs send --refs -i @a $encfs@b >$stream"
log_mustnot stream_has_features $stream fromsnap_refs
log_must test "$(stream_byref_records $stream)" -eq 0
log_must eval "zfs recv -u $recvfs <$stream"
refs_cmp_snaps $encfs $recvfs a b
send_refused "cannot be used with raw sends" --refs -w -i @a $encfs@b

log_pass "zfs send --refs is refused or ignored where it is not supported"
