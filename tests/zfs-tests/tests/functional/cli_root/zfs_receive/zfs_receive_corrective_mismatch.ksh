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
# A corrective recv that cannot reproduce the corrupted blocks must fail
#   cleanly and leave them, and the in-memory copies of their block
#   pointers, alone.
#
# STRATEGY:
# 1. Create a zstd-3 dataset containing a compressible file, snapshot it
#    and create an uncompressed send file of the snapshot
# 2. Change the dataset's compression to zstd-12, so that recompressing
#    the stream data produces different blocks than those on disk
# 3. Corrupt the file's blocks
# 4. Verify that a healing recv fails, and that it succeeds without
#    healing anything when zfs_recv_best_effort_corrective is set.  On
#    debug builds (where ZFS_DEBUG_MODIFY is enabled) this also verifies
#    that the in-memory indirect blocks were not modified.
#

verify_runnable "both"

DISK=${DISKS%% *}

backup=$TEST_BASE_DIR/backup

function cleanup
{
	log_must rm -f $backup
	log_must restore_tunable RECV_BEST_EFFORT_CORRECTIVE

	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	log_must zpool create -f $TESTPOOL $DISK
}

function check_not_healed
{
	log_must zinject -a
	log_must zpool scrub -w $TESTPOOL
	log_must zpool status -v $TESTPOOL
	log_must eval "zpool status -v $TESTPOOL | \
	    grep \"Permanent errors have been detected\""
	log_mustnot eval "cat $file > /dev/null"
}

log_must save_tunable RECV_BEST_EFFORT_CORRECTIVE
log_onexit cleanup

log_assert "ZFS corrective recv must fail cleanly when it cannot heal"

typeset file="/$TESTPOOL/$TESTFS1/$TESTFILE0"

log_must eval "poolexists $TESTPOOL && destroy_pool $TESTPOOL"
log_must zpool create -f -o feature@head_errlog=disabled $TESTPOOL $DISK

log_must zfs create -o primarycache=none -o atime=off \
    -o compression=zstd-3 $TESTPOOL/$TESTFS1
log_must eval "dd if=/dev/urandom bs=1024 count=768 | \
    od -An -tx1 -v > $file"
log_must sync_pool $TESTPOOL
typeset ratio=$(get_prop compressratio $TESTPOOL/$TESTFS1)
[[ "$ratio" != "1.00x" ]] || \
	log_fail "Data in $TESTPOOL/$TESTFS1 was not compressed ($ratio)"
log_must zfs snapshot $TESTPOOL/$TESTFS1@snap1
log_must eval "zfs send $TESTPOOL/$TESTFS1@snap1 > $backup"

log_must zfs set compression=zstd-12 $TESTPOOL/$TESTFS1
corrupt_blocks_at_level $file 0
check_not_healed

# the data can not be recompressed to match the on-disk blocks
log_mustnot eval "zfs recv -c $TESTPOOL/$TESTFS1@snap1 < $backup"
check_not_healed

# in best effort mode the blocks that can not be healed are skipped
log_must set_tunable32 RECV_BEST_EFFORT_CORRECTIVE 1
log_must eval "zfs recv -c $TESTPOOL/$TESTFS1@snap1 < $backup"
log_must set_tunable32 RECV_BEST_EFFORT_CORRECTIVE 0
check_not_healed

log_pass "ZFS corrective recv fails cleanly when it cannot heal"
