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


. $STF_SUITE/tests/functional/replacement/replace_unreadable.kshlib

#
# DESCRIPTION:
# A faulted or offline device that is still attached may hold the only good
# copy of blocks the other devices can't read: ZFS faults a device for
# write errors or for read errors elsewhere on it.  Replacing it must not
# detach it while it may still supply them.  The replacement waits, and
# "zpool status" says why and what to do.  Bringing the device back lets
# the resilver copy the blocks; detaching it gives them up.
#
# STRATEGY:
# 1. Create a mirror of two file vdevs, a and b, fill it with files, and
#    overwrite b's copy of one block of some files.
# 2. Fault a ("zpool offline -f"), or take it offline ("zpool offline").
# 3. Replace a with c and wait for the resilver.
# 4. Verify the resilver reported errors, a and the replacing vdev stay,
#    "zpool status" shows the status and action for it (also with -j and
#    -x) and marks a, and the resilver didn't restart.
# 5. "faulted": "zpool clear"; "offline": "zpool online".  The resilver
#    copies the blocks from a and the replacement completes: every file is
#    intact, and the status is gone.
#    "detach": "zpool detach" of the faulted a is accepted, the replacement
#    is complete, and the damaged files are lost and listed.
# 6. Scrub: the pool is healthy, with no errors, and stays so after an
#    export and import.
#

verify_runnable "global"

log_assert "Replacing a faulted or offline device keeps it while it may" \
    "hold unreadable blocks"
log_onexit unreadable_cleanup

for mode in faulted offline detach; do
	unreadable_mirror_create
	unreadable_import
	if [[ $mode == offline ]]; then
		log_must zpool offline $TESTPOOL1 $aguid
	else
		log_must zpool offline -f $TESTPOOL1 $aguid
	fi
	log_must zpool events -c

	log_must zpool replace $TESTPOOL1 $aguid $UNREADABLE_DIR/c
	log_must zpool wait -t resilver $TESTPOOL1
	# Give a completed replacement time to detach a.
	sync_pool $TESTPOOL1
	sync_pool $TESTPOOL1
	sleep 5
	zpool status -v $TESTPOOL1

	errors=$(resilver_errors)
	(( errors > 0 )) || log_fail "$mode: the resilver reported no errors"
	zpool status -g $TESTPOOL1 | grep -qw $aguid ||
	    log_fail "$mode: the old device was detached, its data is lost"
	zpool status $TESTPOOL1 | grep -q replacing ||
	    log_fail "$mode: the replacement completed without the old device"
	check_replace_held $mode
	check_damaged_listed $mode
	check_files $mode
	starts=$(resilver_starts)
	(( starts == 1 )) ||
	    log_fail "$mode: $starts resilvers started, expected 1"

	case $mode in
	faulted)
		log_must zpool clear $TESTPOOL1
		;;
	offline)
		log_must zpool online $TESTPOOL1 $aguid
		;;
	detach)
		log_must zpool detach $TESTPOOL1 $aguid
		;;
	esac
	log_must zpool wait -t resilver $TESTPOOL1
	if ! timeout 60 zpool wait -t replace $TESTPOOL1; then
		zpool status -v $TESTPOOL1
		log_fail "$mode: the replacement didn't complete in 60 s"
	fi
	zpool status -v $TESTPOOL1
	zpool status -g $TESTPOOL1 | grep -qw $aguid &&
	    log_fail "$mode: the old device is still in the pool"
	zpool status $TESTPOOL1 | grep -q replacing &&
	    log_fail "$mode: the replacement didn't complete"
	check_not_replace_held $mode

	if [[ $mode == detach ]]; then
		# The administrator gave the blocks up.
		check_damaged_listed $mode
		check_files $mode
		for i in $BAD; do
			log_mustnot eval "cat $mnt/f$i >/dev/null"
			log_must rm $mnt/f$i
		done
	else
		# The resilver copied the blocks from a.
		check_files $mode all
	fi
	check_clean $mode
	[[ $mode == detach ]] || check_files $mode all
done

log_pass "Replacing a faulted or offline device keeps it while it may" \
    "hold unreadable blocks"
