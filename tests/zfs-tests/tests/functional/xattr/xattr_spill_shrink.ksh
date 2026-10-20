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
. $STF_SUITE/tests/functional/xattr/xattr_common.kshlib

#
# DESCRIPTION:
# When the system attributes of a file shrink but still need a spill
# block, the space they no longer use must not keep the old attribute
# data.
#
# STRATEGY:
# 1. Create a filesystem with xattr=sa, dnodesize=legacy and no
#    compression, so a large xattr goes to the spill block.
# 2. file1: set a large xattr holding a marker string, sync, then set it
#    to a smaller value that still needs the spill block.
# 3. file2: set a large marker xattr and a second large xattr, sync,
#    then remove the marker xattr.
# 4. Verify that the remaining xattrs read back correctly.
# 5. Snapshot and send the filesystem, and verify that the marker
#    string doesn't appear in the stream: the spill blocks must not
#    carry the old values.
#

verify_runnable "both"

function cleanup
{
	rm -f $TEST_BASE_DIR/xattr_spill_shrink.stream
	datasetexists $TESTPOOL/spill && destroy_dataset $TESTPOOL/spill -r
}

log_assert "Shrinking system attributes in a spill block clears the old data"
log_onexit cleanup

typeset marker="STALE_SPILL_DATA_"
typeset stale=$(printf "$marker%.0s" {1..60})
typeset fresh=$(printf "fresh_value_data_%.0s" {1..36})
typeset keep=$(printf "kept_value_data__%.0s" {1..36})
typeset stream=$TEST_BASE_DIR/xattr_spill_shrink.stream
typeset fs=$TESTPOOL/spill

log_must zfs create -o xattr=sa -o dnodesize=legacy -o compression=off $fs
typeset mntpnt=$(get_prop mountpoint $fs)

# file1: shrink one xattr value
log_must touch $mntpnt/file1
log_must set_xattr test $stale $mntpnt/file1
sync_pool $TESTPOOL
log_must set_xattr test $fresh $mntpnt/file1

# file2: remove one of two xattrs
log_must touch $mntpnt/file2
log_must set_xattr stale $stale $mntpnt/file2
log_must set_xattr keep $keep $mntpnt/file2
sync_pool $TESTPOOL
log_must rm_xattr stale $mntpnt/file2
sync_pool $TESTPOOL

log_must eval "[[ '$(get_xattr test $mntpnt/file1)' == '$fresh' ]]"
log_must eval "[[ '$(get_xattr keep $mntpnt/file2)' == '$keep' ]]"
log_mustnot get_xattr stale $mntpnt/file2

log_must zfs snapshot $fs@snap
log_must eval "zfs send $fs@snap > $stream"
typeset count=$(grep -a -o "$marker" $stream | wc -l)
log_note "marker occurrences in the send stream: $count"
if [[ $count -ne 0 ]]; then
	log_fail "the send stream holds $count copies of removed xattr data"
fi

log_pass "Shrinking system attributes in a spill block clears the old data"
