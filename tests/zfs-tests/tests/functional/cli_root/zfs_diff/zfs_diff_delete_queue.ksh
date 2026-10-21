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
# 'zfs diff' treats a file that was removed while it was still open (a
# file on the delete queue) as removed: it doesn't print it as
# "(on_delete_queue)".
#
# STRATEGY:
# 1. Create a dataset with a file and snapshot it
# 2. Create a second file; remove both files while they are open
# 3. Snapshot the dataset and verify that 'zfs diff' shows only the
#    first file as removed (and the directory as modified), both between
#    the snapshots and against the live dataset
# 4. Close the files, snapshot again and verify that 'zfs diff' between
#    the last two snapshots doesn't show either file
#

verify_runnable "both"

function cleanup
{
	exec 3>&- 4<&-
	datasetexists "$DATASET" && destroy_dataset "$DATASET" -r
	rm -f $expected $actual
}

log_assert "'zfs diff' doesn't print files on the delete queue"
log_onexit cleanup

DATASET="$TESTPOOL/$TESTFS/fs"
expected=$TEST_BASE_DIR/zfs_diff_delete_queue.expected
actual=$TEST_BASE_DIR/zfs_diff_delete_queue.actual

#
# check_diff from to expected-lines...
#
function check_diff
{
	typeset from=$1
	typeset to=$2
	shift 2

	printf '%s\n' "$@" | grep -v '^$' | sort > $expected
	log_must eval "zfs diff $from $to > $actual"
	log_note "zfs diff $from $to:\n$(<$actual)"
	log_mustnot grep -q 'on_delete_queue' $actual
	grep -vF '<xattrdir>' $actual | sort | log_must diff -u $expected -
}

# 1. A dataset with a file
log_must zfs create "$DATASET"
MNTPOINT="$(get_prop mountpoint "$DATASET")"
log_must eval "echo kept > $MNTPOINT/old"
log_must zfs snapshot "$DATASET@snap1"

# 2. A new file and the old file, both removed while open
exec 3>$MNTPOINT/new
log_must eval "echo data >&3"
log_must rm $MNTPOINT/new
exec 4<$MNTPOINT/old
log_must rm $MNTPOINT/old

# 3. Only the old file shows, as removed
log_must zfs snapshot "$DATASET@snap2"
check_diff "$DATASET@snap1" "$DATASET@snap2" \
    "$(printf 'M\t%s/' "$MNTPOINT")" "$(printf -- '-\t%s/old' "$MNTPOINT")"
check_diff "$DATASET@snap1" "$DATASET" \
    "$(printf 'M\t%s/' "$MNTPOINT")" "$(printf -- '-\t%s/old' "$MNTPOINT")"

# 4. Once closed and freed, neither file shows
exec 3>&- 4<&-
log_must zpool sync $TESTPOOL
log_must zfs snapshot "$DATASET@snap3"
check_diff "$DATASET@snap2" "$DATASET@snap3"

log_pass "'zfs diff' doesn't print files on the delete queue"
