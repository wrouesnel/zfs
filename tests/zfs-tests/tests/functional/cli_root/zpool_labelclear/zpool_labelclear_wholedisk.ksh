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

. $STF_SUITE/tests/functional/cli_root/zpool_labelclear/labelclear.cfg

# DESCRIPTION:
#	'zpool labelclear' with the full path of a whole disk that ZFS
#	partitioned clears the labels, which are on the disk's first
#	partition, as it does with the disk's short name.  When there is
#	no label left, the error says so.
#
# STRATEGY:
#	1. Create a pool on a whole (scsi_debug) disk and export it.
#	2. 'zpool labelclear -f /dev/DISK' must succeed.
#	3. The partition must have no label left, and the pool must not be
#	   importable.
#	4. A second 'zpool labelclear -f /dev/DISK' must fail and say that
#	   no label was found.

verify_runnable "global"

# Only Linux partitions a whole disk given to zpool create.
is_linux || log_unsupported "whole disks are partitioned only on Linux"

function cleanup
{
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	unload_scsi_debug
}

log_onexit cleanup
log_assert "zpool labelclear with the path of a whole disk clears its labels"

load_scsi_debug $(($SPA_MINDEVSIZE/1024/1024+32)) 1 1 1 '512b'
disk=$(get_debug_device)
whole=$DEV_DSKDIR/$disk

log_must zpool create -O mountpoint=none -f $TESTPOOL $disk
log_must test "$(zdb -PC $TESTPOOL | grep -c 'whole_disk: 1')" == 1
leaf=$(zpool list -vHP $TESTPOOL | awk '$1 ~ "^/" {print $1; exit}')
log_note "pool vdev on $leaf (whole disk $whole)"
[[ -n "$leaf" && $leaf != $whole ]] || \
    log_fail "$TESTPOOL doesn't use a partition of $whole: '$leaf'"
log_must zpool export $TESTPOOL
log_must zdb -lq $leaf

log_must zpool labelclear -f $whole
log_mustnot zdb -lq $leaf
log_mustnot zpool import -d $DEV_DSKDIR $TESTPOOL

out=$(zpool labelclear -f $whole 2>&1)
rc=$?
log_note "second labelclear: rc=$rc: $out"
(( rc != 0 )) || log_fail "labelclear of a disk without labels succeeded"
[[ "$out" == *"no ZFS label found"* ]] || \
    log_fail "the error doesn't say that there is no label: $out"

log_pass "zpool labelclear with the path of a whole disk clears its labels"
