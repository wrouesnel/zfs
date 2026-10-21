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
#	A mountpoint set with repeated or trailing slashes is stored without
#	them, so that 'zfs mount -a' mounts a file system below it after it,
#	not before it (where it would be hidden).
#
# STRATEGY:
#	1. Create a file system with mountpoint=<dir>//a and a child with
#	   mountpoint=<dir>/a/b
#	2. Unmount both and run 'zfs mount -a' several times; verify the
#	   child is mounted on top (a file in it is visible), and that the
#	   first mountpoint is stored as <dir>/a
#	3. Set mountpoint=<dir>/a/ and create a file system with a trailing
#	   slash; verify they are stored without the trailing slash and
#	   the mount order is still right
#	4. Verify mountpoint=/ is kept as it is (canmount=off)
#

verify_runnable "global"

function cleanup
{
	# Without the fix the child can be hidden under its parent, and
	# unmounting it by name fails: unmount the parent's mount first.
	umount $base/a 2>/dev/null
	datasetexists $TESTPOOL/$TESTFS/sl && \
	    destroy_dataset $TESTPOOL/$TESTFS/sl -rf
	rm -rf $base
}

function check_mountpoint # dataset expected
{
	typeset mp=$(get_prop mountpoint $1)

	[[ $mp == $2 ]] || log_fail "$1 mountpoint is '$mp', expected '$2'"
}

function check_order # step
{
	typeset -i i

	for ((i = 0; i < 5; i++)); do
		log_must zfs unmount $TESTPOOL/$TESTFS/sl/a/b
		log_must zfs unmount $TESTPOOL/$TESTFS/sl/a
		log_must zfs mount -a
		[[ -f $base/a/b/inb ]] || log_fail \
		    "after $1: $TESTPOOL/$TESTFS/sl/a/b is hidden under" \
		    "$TESTPOOL/$TESTFS/sl/a"
	done
}

log_assert "Mountpoints are stored without repeated or trailing slashes."
log_onexit cleanup

base=$TEST_BASE_DIR/zfs_mount_slashes.$$

log_must zfs create -o mountpoint=none $TESTPOOL/$TESTFS/sl
log_must zfs create -o mountpoint=$base//a $TESTPOOL/$TESTFS/sl/a
log_must zfs create -o mountpoint=$base/a/b $TESTPOOL/$TESTFS/sl/a/b
log_must touch $base/a/b/inb
check_order "mountpoint=$base//a"
check_mountpoint $TESTPOOL/$TESTFS/sl/a $base/a

# The child has its own mountpoint, so it isn't remounted with its parent.
log_must zfs unmount $TESTPOOL/$TESTFS/sl/a/b
log_must zfs set mountpoint=$base/a/ $TESTPOOL/$TESTFS/sl/a
log_must zfs mount $TESTPOOL/$TESTFS/sl/a/b
check_mountpoint $TESTPOOL/$TESTFS/sl/a $base/a
log_must zfs create -o mountpoint=$base///c// $TESTPOOL/$TESTFS/sl/c
check_mountpoint $TESTPOOL/$TESTFS/sl/c $base/c
check_order "mountpoint=$base/a/"

log_must zfs create -o canmount=off -o mountpoint=/ $TESTPOOL/$TESTFS/sl/root
check_mountpoint $TESTPOOL/$TESTFS/sl/root /

log_pass "Mountpoints are stored without repeated or trailing slashes."
