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
# A user with the delegated diff (and snapshot) permission can run
# 'zfs diff' on a dataset whose mountpoint that user can't search,
# and gets the same output as root.
#
# STRATEGY:
# 1. Create a dataset whose mountpoint is mode 0700, owned by root.
# 2. Delegate diff and snapshot on it to an unprivileged user.
# 3. Change files between two snapshots.
# 4. Verify 'zfs diff snap1 snap2' and 'zfs diff snap1' as the user
#    succeed and print what they print for root.
#

verify_runnable "global"

DIFFUSER=zdiffuser
DIFFGROUP=zdiffgroup
DATASET="$TESTPOOL/$TESTFS/fs"

function cleanup
{
	datasetexists $DATASET && destroy_dataset $DATASET -r
	del_user $DIFFUSER
	del_group $DIFFGROUP
	rm -f $TEST_BASE_DIR/zfs_diff_root.out
}

log_assert "'zfs diff' works for a delegated user who can't search" \
	"the mountpoint"
log_onexit cleanup

del_user $DIFFUSER
del_group $DIFFGROUP
log_must add_group $DIFFGROUP
log_must add_user $DIFFGROUP $DIFFUSER
user_run $DIFFUSER zfs list ||
	log_unsupported "Test user $DIFFUSER cannot execute zfs utilities"

# 1. A dataset the user can't look into
log_must zfs create $DATASET
MNTPOINT="$(get_prop mountpoint $DATASET)"
log_must chown root $MNTPOINT
log_must chmod 0700 $MNTPOINT

# 2. Delegate diff (and snapshot, for the diff against the live dataset)
log_must zfs allow -u $DIFFUSER diff,snapshot $DATASET
log_mustnot user_run $DIFFUSER ls $MNTPOINT

# 3. Changes between two snapshots, and after the second
log_must touch $MNTPOINT/removed $MNTPOINT/modified
log_must zfs snapshot $DATASET@snap1
log_must rm $MNTPOINT/removed
log_must touch $MNTPOINT/created
log_must eval "echo changed > $MNTPOINT/modified"
log_must zfs snapshot $DATASET@snap2
log_must touch $MNTPOINT/later

# 4. The user's diffs match root's
for args in "$DATASET@snap1 $DATASET@snap2" "$DATASET@snap1"; do
	log_must eval "zfs diff -H $args | sort > $TEST_BASE_DIR/zfs_diff_root.out"
	log_must grep -q created $TEST_BASE_DIR/zfs_diff_root.out
	log_must user_run $DIFFUSER zfs diff -H $args
	log_must eval "sort $TEST_BASE_DIR/out | \
	    diff -u $TEST_BASE_DIR/zfs_diff_root.out -"
done

log_pass "'zfs diff' works for a delegated user who can't search" \
	"the mountpoint"
