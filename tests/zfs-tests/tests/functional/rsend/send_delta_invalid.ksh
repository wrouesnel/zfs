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
# Verify that "zfs send --delta" is refused where it is not supported, and
# ignored for non-raw sends of encrypted datasets.
#
# Strategy:
# 1. --delta is refused for raw (-w), redacted (--redact) and full sends,
#    and with -S, while the same sends without --delta succeed.
# 2. --delta for a non-raw incremental of an encrypted dataset with a file
#    modified in place succeeds and sends a regular stream, which is
#    received and verified.
#

verify_runnable "both"

sendfs=$POOL/refs_send
rclone=$POOL/refs_rclone
encfs=$POOL/refs_enc
recvfs=$POOL2/refs_recv
stream=$BACKDIR/delta
errfile=$BACKDIR/delta.err
keyfile=$BACKDIR/delta.key

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

log_assert "zfs send --delta is refused or ignored where it is not supported"
log_onexit cleanup

log_must zfs create -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 4
log_must zfs snapshot $sendfs@a
refs_poke $mntpnt/f1 1
log_must zfs snapshot $sendfs@b

# Raw sends.
log_must eval "zfs send -w -i @a $sendfs@b >$stream"
send_refused "--delta cannot be used with raw sends" --delta -w -i @a $sendfs@b
send_refused "--delta cannot be used with raw sends" -w --delta $sendfs@b

# Full sends, also replication streams.
send_refused "--delta cannot be used with full sends" --delta $sendfs@b
send_refused "--delta cannot be used with full sends" --delta -R $sendfs@b
send_refused "--refs and --delta cannot be used with full sends" \
	--refs --delta $sendfs@b

# Redacted sends.
log_must zfs clone $sendfs@b $rclone
log_must rm $(get_prop mountpoint $rclone)/f1
log_must zfs snapshot $rclone@s
log_must zfs redact $sendfs@b book $rclone@s
log_must eval "zfs send --redact book -i @a $sendfs@b >$stream"
send_refused "--delta cannot be used with redacted sends" \
	--delta --redact book -i @a $sendfs@b

# Saved sends.
send_refused "incompatible flags" -S --delta $sendfs

# Encrypted dataset, non-raw: accepted, and a regular stream is sent even
# though f1 was modified in place.
log_must eval "echo 'password' >$keyfile"
log_must zfs create -o encryption=on -o keyformat=passphrase \
	-o keylocation=file://$keyfile -o recordsize=$REFS_RECSIZE $encfs
mntpnt=$(get_prop mountpoint $encfs)
refs_mkfile $mntpnt/f1 4
log_must zfs snapshot $encfs@a
refs_poke $mntpnt/f1 1
log_must zfs snapshot $encfs@b
log_must eval "zfs send $encfs@a >$BACKDIR/full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/full"
log_must eval "zfs send --delta -i @a $encfs@b >$stream"
log_mustnot stream_has_features $stream write_delta
log_mustnot stream_has_features $stream fromsnap_refs
log_must test "$(stream_delta_records $stream)" -eq 0
log_must eval "zfs recv -u $recvfs <$stream"
refs_cmp_snaps $encfs $recvfs a b
send_refused "--delta cannot be used with raw sends" --delta -w -i @a $encfs@b

log_pass "zfs send --delta is refused or ignored where it is not supported"
