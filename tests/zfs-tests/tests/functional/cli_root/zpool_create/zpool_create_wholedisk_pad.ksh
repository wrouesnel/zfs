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
# When 'zpool create' partitions a whole disk, the first 8K of the new
# partition must be zero.  ZFS never writes that area (vl_pad1 of label
# 0), so a signature left there by an earlier user of the disk, such as
# an md 1.2 superblock at 4K, makes libblkid report the partition as
# that type instead of zfs_member, and 'zpool import' without -d then
# doesn't find the pool (openzfs/zfs#18241).
#
# STRATEGY:
# 1. Create a pool on a whole (scsi_debug) disk and destroy it.
# 2. Fill the first 8K of the partition it used with a pattern.
# 3. Create the pool on the whole disk again (same partition start).
# 4. The first 8K of the partition must be zero.
#

verify_runnable "global"

# Only Linux partitions a whole disk given to zpool create.
is_linux || log_unsupported "whole disks are partitioned only on Linux"

function cleanup
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	unload_scsi_debug
}

log_onexit cleanup

log_assert "zpool create zeroes the first 8K of a whole-disk partition"

load_scsi_debug $(($SPA_MINDEVSIZE/1024/1024+32)) 1 1 1 '512b'
disk=$(get_debug_device)

log_must zpool create -O mountpoint=none -f $TESTPOOL1 $disk
leaf=$(zpool list -vHP $TESTPOOL1 | awk '$1 ~ "^/" {print $1; exit}')
part=$(basename $(readlink -f $leaf))
start=$(cat /sys/class/block/$part/start)
log_note "pool vdev on $leaf ($part, start sector $start)"
[[ -n "$leaf" && $part != $disk ]] || \
    log_fail "$TESTPOOL1 doesn't use a partition of $disk: '$leaf'"
log_must destroy_pool $TESTPOOL1
block_device_wait

# Write 8K of 0xa5 over the start of the old partition (through the disk,
# at the partition's offset, so it doesn't matter whether the partition
# still exists).  Direct I/O throughout: the disk and the partition don't
# share a page cache.
log_must eval "printf '%8192s' | tr ' ' '\245' | \
    dd of=$DEV_RDSKDIR/$disk bs=512 seek=$start iflag=fullblock \
    oflag=direct conv=notrunc status=none"

log_must zpool create -O mountpoint=none -f $TESTPOOL1 $disk
block_device_wait
leaf=$(zpool list -vHP $TESTPOOL1 | awk '$1 ~ "^/" {print $1; exit}')
part=$(basename $(readlink -f $leaf))
[[ $(cat /sys/class/block/$part/start) == $start ]] || \
    log_unsupported "the new partition starts elsewhere"

nonzero=$(dd if=$DEV_RDSKDIR/$disk bs=512 skip=$start count=16 \
    iflag=direct status=none | od -A n -v -t x1 | tr -s ' ' '\n' | \
    grep -v '^$' | grep -vc '^00$')
log_note "non-zero bytes in the first 8K of $part: $nonzero"
[[ $nonzero == 0 ]] || \
    log_fail "zpool create left $nonzero non-zero bytes in the first 8K of $part"

log_pass "zpool create zeroes the first 8K of a whole-disk partition"
