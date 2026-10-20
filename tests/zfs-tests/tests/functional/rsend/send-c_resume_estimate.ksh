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
# Verify that the size estimate of a resumed send is sane when the
# interrupted stream was not compressed and the resumed one is (-c).
#
# Strategy:
# 1. Fill a compress=lz4 filesystem with compressible data, @a; receive
#    it; more data, @b.
# 2. Interrupt an uncompressed incremental receive -s of @a..@b.
# 3. "zfs send -nvcP -t TOKEN" must estimate more than 0 and no more than
#    the whole compressed incremental (it used to wrap around below 0).
# 4. The estimate must be within a factor of 3 of the size of the
#    resumed compressed stream, and that stream must receive.
# 5. The estimate without -c must stay within the whole incremental.
#

verify_runnable "both"

sendfs=$POOL/sendfs
recvfs=$POOL2/recvfs
stream=$TEST_BASE_DIR/send-c_resume_estimate.zsend

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	rm -f $stream
}

function size_of # estimate output
{
	awk '/^size/ { print $2 }'
}

function in_range # value low high
{
	awk -v v="$1" -v lo="$2" -v hi="$3" \
	    'BEGIN { exit !(v + 0 >= lo + 0 && v + 0 <= hi + 0) }'
}

log_assert "The estimate of a resumed send with -c does not wrap around"
log_onexit cleanup

log_must zfs create -o compress=lz4 $sendfs
typeset mntpnt=$(get_prop mountpoint $sendfs)
for i in 1 2 3; do
	log_must eval "seq -f 'first %.0f' 1 3000000 > $mntpnt/a$i"
done
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a | zfs receive $recvfs"
for i in 1 2 3; do
	log_must eval "seq -f 'second %.0f' 1 3000000 > $mntpnt/b$i"
done
log_must zfs snapshot $sendfs@b

typeset full=$(zfs send -nvP -i @a $sendfs@b | size_of)
typeset fullc=$(zfs send -nvcP -i @a $sendfs@b | size_of)
log_note "incremental estimate $full, with -c $fullc"
log_must in_range $fullc 1 $((full / 2))

# Interrupt the uncompressed incremental after 60% of it.
log_mustnot eval "zfs send -i @a $sendfs@b | head -c $((full * 6 / 10)) | " \
    "zfs receive -s $recvfs"
typeset token=$(get_prop receive_resume_token $recvfs)
[[ "$token" == "-" ]] && log_fail "no resume token on $recvfs"

typeset est=$(zfs send -nvP -t $token | size_of)
typeset estc=$(zfs send -nvcP -t $token | size_of)
log_note "resume estimate $est, with -c $estc"
in_range $estc 1 $fullc || log_fail "resume estimate with -c is $estc," \
    "outside 1..$fullc (the whole compressed incremental)"
in_range $est 1 $full || log_fail "resume estimate is $est, outside 1..$full"

log_must eval "zfs send -c -t $token > $stream"
typeset actual=$(stat_size $stream)
log_note "resumed compressed stream is $actual bytes"
in_range $estc $((actual / 3)) $((actual * 3)) || log_fail "resume" \
    "estimate with -c $estc is not within 3x of the stream's $actual bytes"

log_must eval "zfs receive -s $recvfs < $stream"
log_must cmp $mntpnt/b3 $(get_prop mountpoint $recvfs)/b3

log_pass "The estimate of a resumed send with -c does not wrap around"
