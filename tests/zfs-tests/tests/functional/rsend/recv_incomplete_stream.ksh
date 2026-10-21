#!/bin/ksh
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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/rsend/rsend.kshlib

#
# Description:
# When 'zfs send -R' fails to send a snapshot part way through (here, a
# read error), it goes on with the next snapshot, so the receiver finds
# the next stream's BEGIN record before the END record of the stream it
# is receiving.  'zfs receive' must say that the stream is incomplete,
# not that an embedded stream can't be received encrypted (with -e and
# no encryption anywhere) or only "invalid backup stream".
#
# Strategy:
# 1. Create a filesystem with two snapshots; the first holds a file that
#    isn't cached in the ARC
# 2. Inject read errors into that file in the first snapshot
# 3. Verify that 'zfs send -Re | zfs receive' and 'zfs send -R | zfs
#    receive' fail, say that the stream is incomplete, and don't mention
#    encryption
#

verify_runnable "both"

function cleanup
{
	zinject -c all >/dev/null 2>&1
	datasetexists $testfs && destroy_dataset $testfs -r
	datasetexists $POOL2/incomplete_e && destroy_dataset $POOL2/incomplete_e -r
	datasetexists $POOL2/incomplete && destroy_dataset $POOL2/incomplete -r
	rm -f $errfile
}

log_assert "'zfs receive' says that a stream cut short by a failed send" \
    "is incomplete"
log_onexit cleanup

testfs=$POOL/incomplete
errfile=$TEST_BASE_DIR/recv_incomplete_stream.err

# 1. Two snapshots; the file in the first is read from disk when sent
log_must zfs create -o primarycache=metadata -o compression=off $testfs
mntpnt=$(get_prop mountpoint $testfs)
log_must dd if=/dev/urandom of=$mntpnt/a bs=128k count=40
log_must zfs snapshot $testfs@s1
log_must eval "echo small > $mntpnt/b"
log_must zfs snapshot $testfs@s2

# 2. Reading the file in the first snapshot fails
log_must ls $mntpnt/.zfs/snapshot/s1/a
log_must zinject -t data -e io -f 100 $mntpnt/.zfs/snapshot/s1/a

# 3. Both receives fail, and say why
for opt in "-e" ""; do
	recvfs=$POOL2/incomplete${opt:+_e}
	log_mustnot eval "zfs send -R $opt $testfs@s2 2>/dev/null | \
	    zfs receive -Fu $recvfs 2>$errfile"
	log_note "zfs send -R $opt | zfs receive: $(<$errfile)"
	log_must grep -q "incomplete stream" $errfile
	log_mustnot grep -q "encrypted" $errfile
done

log_pass "'zfs receive' says that a stream cut short by a failed send" \
    "is incomplete"
