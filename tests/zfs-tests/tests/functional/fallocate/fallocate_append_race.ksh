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

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
# A mode 0 fallocate(2) that extends a file must not shrink it when a
# concurrent write has already made it larger (xfstests generic/586),
# neither while the file is open nor after the ZIL is replayed.
#
# STRATEGY:
# 1. Repeatedly race a write of the second block of an empty file
#    against a mode 0 fallocate of its first block.  Every iteration
#    must leave a two-block file, as seen through the racing descriptor,
#    a new descriptor and stat(2), and a write at the end of the file
#    must not land on the second block.
# 2. Freeze a separate pool, race fresh files there and fsync each, then
#    export and import the pool so that the ZIL is replayed.  Every
#    file must come back two blocks long with its second block intact.
#

verify_runnable "global"

FILE=$TESTDIR/$TESTFILE0
VDEVDIR=$TEST_BASE_DIR/falloc_append_race
VDEV=$VDEVDIR/vdev
RPOOL=falloc_race_pool
BS=131072

function cleanup
{
	poolexists $RPOOL && destroy_pool $RPOOL
	rm -rf $VDEVDIR
	[[ -e $TESTDIR ]] && log_must rm -Rf $TESTDIR/*
}

log_assert "fallocate(2) extending a file doesn't truncate a racing append"
log_onexit cleanup

log_must zfs set recordsize=128k $TESTPOOL/$TESTFS
log_must falloc_append_race live $FILE 2000 $BS

log_must mkdir -p $VDEVDIR
log_must truncate -s 4G $VDEV
log_must zpool create -f -O recordsize=128k $RPOOL $VDEV
log_must zfs create $RPOOL/fs
log_must sync_pool $RPOOL
# Create the ZIL before freezing, as the slog replay tests do.
log_must dd if=/dev/zero of=/$RPOOL/fs/sync conv=fdatasync,fsync bs=1 count=1
log_must zpool freeze $RPOOL
log_must falloc_append_race keep /$RPOOL/fs 3000 $BS
log_must zpool export $RPOOL
log_must zpool import -d $VDEVDIR $RPOOL
log_must falloc_append_race check /$RPOOL/fs 3000 $BS

log_pass "fallocate(2) extending a file doesn't truncate a racing append"
