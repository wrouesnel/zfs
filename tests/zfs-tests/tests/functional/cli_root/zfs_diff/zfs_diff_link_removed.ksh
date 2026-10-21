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
# 'zfs diff' must not report a file as removed (or added) because a hard
# link to it was created and removed in another directory.  Creating the
# link points the file's parent at the link's directory, and removing the
# link leaves it there, so the file's path can't be found from it in
# snapshots taken afterwards.
#
# STRATEGY:
# 1. Create src/file1, snapshot, hard link it as dest/file2, remove
#    dest/file2, snapshot again.
# 2. 'zfs diff' must show src/file1 as modified, not removed.
# 3. Rename src/file1 to src/file1b and snapshot again: 'zfs diff' from
#    the second snapshot must not show src/file1b as added.
#

verify_runnable "both"

function cleanup
{
	datasetexists $DATASET && destroy_dataset $DATASET -r
	rm -f $FILEDIFF
}

function diff_snaps # <snap1> <snap2>
{
	log_must eval "zfs diff -F $1 $2 > $FILEDIFF"
	log_note "zfs diff -F $1 $2:\n$(cat $FILEDIFF)"
}

function change_of # <path>
{
	awk -v path="$1" -F'\t' '$NF == path { printf "%s", $1 }' $FILEDIFF
}

log_assert "'zfs diff' handles a removed hard link in another directory"
log_onexit cleanup

DATASET="$TESTPOOL/$TESTFS/linkfs"
FILEDIFF="$TESTDIR/zfs-diff-link.txt"

log_must zfs create $DATASET
MNTPOINT="$(get_prop mountpoint $DATASET)"
log_must mkdir $MNTPOINT/src $MNTPOINT/dest
log_must eval "echo 'this is a file' > $MNTPOINT/src/file1"
log_must zfs snapshot $DATASET@snap1
log_must ln $MNTPOINT/src/file1 $MNTPOINT/dest/file2
log_must rm $MNTPOINT/dest/file2
log_must zfs snapshot $DATASET@snap2

diff_snaps $DATASET@snap1 $DATASET@snap2
chg=$(change_of $MNTPOINT/src/file1)
[[ "$chg" == "M" ]] || log_fail "src/file1 shown as '$chg', expected 'M'"

log_must mv $MNTPOINT/src/file1 $MNTPOINT/src/file1b
log_must zfs snapshot $DATASET@snap3
diff_snaps $DATASET@snap2 $DATASET@snap3
chg=$(change_of $MNTPOINT/src/file1b)
[[ "$chg" == "M" || "$chg" == "R" ]] ||
    log_fail "src/file1b shown as '$chg', expected 'M' or 'R'"

log_pass "'zfs diff' handles a removed hard link in another directory"
