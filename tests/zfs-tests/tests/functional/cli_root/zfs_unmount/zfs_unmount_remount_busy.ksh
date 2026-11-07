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
#	'zfs unmount' must not fail with "busy" just because another process
#	is updating the same mount at that moment.  On FreeBSD, mountd(8)
#	does that every time libzfs commits an NFS share change: it applies
#	the new export list with nmount(MNT_UPDATE) on the exported file
#	systems, and unmount(2) returns EBUSY while MNT_UPDATE is set.  So
#	'zfs set canmount=off', 'zfs unmount' or 'zfs destroy' of a dataset
#	with sharenfs=on (which itself signals mountd just before the
#	unmount) failed now and then (inheritance/inherit_001_pos).
#	A file system that is really in use must still refuse to unmount.
#	FreeBSD only: exportfs(8) on Linux doesn't update the mount.
#
# STRATEGY:
#	1. Create a file system and keep updating its mount (mount -u)
#	   in the background, as mountd's export updates do.
#	2. Unmount and mount it repeatedly: every 'zfs unmount' must succeed.
#	3. Stop the remounts.  Hold the file system busy (a process with its
#	   working directory in it): 'zfs unmount' must fail with "busy" and
#	   leave it mounted.
#	4. Release it: 'zfs unmount' must now succeed, and 'zfs mount' bring
#	   it back.
#

verify_runnable "both"

if ! is_freebsd; then
	log_unsupported "FreeBSD-specific: mountd updates exported mounts"
fi

typeset fs=$TESTPOOL/$TESTFS1
# Under the pool root: when the file system is unmounted,
# "mount -u <dir>" updates the pool root mount instead, which is harmless.
typeset mntpnt=/$TESTPOOL/$TESTFS1
typeset runflag=$TEST_BASE_DIR/remount_busy.run
typeset -i iters=500
typeset -i storm_pid=0 holder_pid=0

function remount_storm
{
	while [[ -e $runflag ]]; do
		mount -u -o noatime $mntpnt
		mount -u -o atime $mntpnt
	done >/dev/null 2>&1
}

function cleanup
{
	rm -f $runflag
	(( storm_pid != 0 )) && wait $storm_pid
	(( holder_pid != 0 )) && kill $holder_pid 2>/dev/null
	datasetexists $fs && destroy_dataset $fs -f
}

log_onexit cleanup

log_assert "'zfs unmount' succeeds while the mount is being updated" \
	"and still fails with 'busy' when the file system is in use."

log_must zfs create $fs
log_must test "$(get_prop mountpoint $fs)" = $mntpnt
log_must ismounted $fs

# 1. remounts in the background
log_must touch $runflag
remount_storm &
storm_pid=$!
sleep 1

# 2. unmount/mount cycles while the remounts run
typeset -i i=0
while (( i < iters )); do
	out=$(zfs unmount $fs 2>&1)
	if (( $? != 0 )); then
		log_fail "zfs unmount $fs failed during a remount" \
		    "(cycle $i of $iters): $out"
	fi
	if ismounted $fs; then
		log_fail "$fs still mounted after zfs unmount (cycle $i)"
	fi
	log_must zfs mount $fs
	(( i += 1 ))
done
log_note "$iters unmount/mount cycles succeeded during remounts"

# 3. stop the remounts; a file system in use must still refuse
log_must rm -f $runflag
wait $storm_pid
storm_pid=0
log_must ismounted $fs

(cd $mntpnt && sleep 300) &
holder_pid=$!
sleep 1
out=$(zfs unmount $fs 2>&1)
(( $? == 0 )) && log_fail "zfs unmount $fs succeeded while it was in use"
log_note "in use: $out"
[[ $out == *"busy"* ]] || log_fail "unexpected error for a busy unmount: $out"
log_must ismounted $fs

# 4. released: unmount and mount work again
kill $holder_pid
wait $holder_pid
holder_pid=0
log_must zfs unmount $fs
log_mustnot ismounted $fs
log_must zfs mount $fs
log_must ismounted $fs

log_pass "'zfs unmount' succeeds while the mount is being updated" \
	"and still fails with 'busy' when the file system is in use."
