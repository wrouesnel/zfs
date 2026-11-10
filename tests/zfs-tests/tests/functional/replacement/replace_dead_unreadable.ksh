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
# Replacing a dead device completes even if the resilver can't read some
# blocks from the surviving copies: the dead device can't supply them, so
# keeping it attached protects nothing.  The blocks are reported as
# permanent errors, and the pool is clean once the damaged files are gone.
#
# STRATEGY:
# 1. Create a mirror of two file vdevs, a and b, fill it with files, and
#    overwrite b's copy of one block of some files.
# 2. Make a unavailable:
#    - "unavail": remove its file before the import;
#    - "pulled": fault it with "zpool offline -f", then remove its file.
#      A faulted device isn't reopened, so the pool only finds out that
#      it's gone at the next "zpool clear".
# 3. Replace a with c and wait for the resilver.  For "pulled", run
#    "zpool clear".
# 4. Verify the replacement completes without a manual detach, the
#    resilver reported errors, "zpool status -v" lists exactly the
#    damaged files, the other files are intact, and the resilver didn't
#    restart.
# 5. Delete the damaged files and scrub: the pool is healthy, with no
#    errors, and stays so after an export and import.
#

verify_runnable "global"

log_assert "Replacing a dead device completes despite unreadable blocks"
log_onexit unreadable_cleanup

for mode in unavail pulled; do
	unreadable_mirror_create
	[[ $mode == unavail ]] &&
	    log_must mv $UNREADABLE_DIR/a $UNREADABLE_DIR/gone/a
	unreadable_import
	if [[ $mode == pulled ]]; then
		log_must zpool offline -f $TESTPOOL1 $aguid
		log_must mv $UNREADABLE_DIR/a $UNREADABLE_DIR/gone/a
	fi
	log_must zpool events -c

	log_must zpool replace $TESTPOOL1 $aguid $UNREADABLE_DIR/c
	log_must zpool wait -t resilver $TESTPOOL1
	errors=$(resilver_errors)
	(( errors > 0 )) || log_fail "$mode: the resilver reported no errors"
	if [[ $mode == pulled ]]; then
		# Still faulted: the replacement may wait for it until
		# "zpool clear" finds that it's gone.
		zpool status -v $TESTPOOL1
		log_must zpool clear $TESTPOOL1
		log_must zpool wait -t resilver $TESTPOOL1
	fi
	# The replacement completes asynchronously after the resilver.
	if ! timeout 60 zpool wait -t replace $TESTPOOL1; then
		zpool status -v $TESTPOOL1
		log_fail "$mode: the replacement didn't complete in 60 s"
	fi
	zpool status -v $TESTPOOL1

	zpool status -g $TESTPOOL1 | grep -qw $aguid &&
	    log_fail "$mode: the dead device is still in the pool"
	zpool status $TESTPOOL1 | grep -q replacing &&
	    log_fail "$mode: the replacement didn't complete"
	log_mustnot eval "zpool detach $TESTPOOL1 $aguid"
	check_not_replace_held $mode
	check_damaged_listed $mode
	check_files $mode
	for i in $BAD; do
		log_mustnot eval "cat $mnt/f$i >/dev/null"
	done

	# No resilver restart for the blocks it couldn't read ("zpool
	# clear" starts one for them).
	sync_pool $TESTPOOL1
	sync_pool $TESTPOOL1
	starts=$(resilver_starts)
	expected=1
	[[ $mode == pulled ]] && expected=2
	(( starts <= expected )) ||
	    log_fail "$mode: $starts resilvers started, expected $expected"

	for i in $BAD; do
		log_must rm $mnt/f$i
	done
	check_clean $mode
done

log_pass "Replacing a dead device completes despite unreadable blocks"
