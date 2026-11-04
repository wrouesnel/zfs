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

#
# Copyright (c) 2026 by Will Rouesnel. All rights reserved.
#

#
# DESCRIPTION:
#	A pool that suspends while the async thread's
#	spa_vdev_resilver_done() waits for the config lock as writer
#	can be resumed with zpool clear.
#
#	txg_sync holds SCL_CONFIG as reader for the whole sync, including
#	while it waits for a suspended pool to be resumed.
#	spa_vdev_resilver_done() queues for SCL_ALL as writer behind it.
#	zpool clear (and zpool status) must not queue behind that writer
#	to read the pool's config, or the pool can't be resumed.
#
# STRATEGY:
#	1. Create a pool on a file and keep it writing, with every I/O
#	   delayed, so each txg sync takes seconds and the next txg is
#	   ready when one ends.
#	2. Replace the file with the scsi_debug disk.  When the resilver
#	   is done, the async thread detaches the file (waiting for its
#	   txg and rewriting the cachefile) and goes back to
#	   spa_vdev_resilver_done()'s SCL_ALL writer lock while the next
#	   sync holds SCL_CONFIG.
#	3. As soon as the file has left the cachefile, "pull" the disk,
#	   without a ZFS command (they would queue behind the writer), so
#	   that sync suspends.
#	4. If spa_vdev_resilver_done() isn't waiting, start over (up to 5
#	   times).
#	5. Return the disk; zpool status and zpool clear must return, the
#	   pool must resume and the async thread finish.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/include/blkdev.shlib

verify_runnable "global"

if ! is_linux; then
	log_unsupported "scsi_debug and /proc/<pid>/stack are Linux-only"
fi

typeset FILEVDEV="$TEST_BASE_DIR/resilver_done_vdev"
typeset CACHEFILE="$TEST_BASE_DIR/resilver_done.cache"
typeset STOPFILE="$TEST_BASE_DIR/resilver_done.stop"
typeset DELAY_MS=50
typeset WEDGED=0
typeset WPID=""
typeset sd=""

function resilver_done_waiting
{
	grep -ls spa_vdev_resilver_done /proc/[0-9]*/stack >/dev/null
}

#
# Run a command in the background and wait up to $1 seconds for it.
# Fails if it is still running then.
#
function returns_within
{
	typeset -i secs=$1
	shift
	"$@" > /dev/null 2>&1 &
	typeset pid=$!
	while ((secs-- > 0)); do
		kill -0 $pid 2>/dev/null || { wait $pid; return; }
		sleep 1
	done
	return 124
}

function stop_writer
{
	if [[ -n $WPID ]]; then
		touch $STOPFILE
		wait $WPID
		WPID=""
	fi
}

function cleanup
{
	if ((WEDGED)); then
		# The pool can't be resumed: destroying it would hang too.
		log_note "pool $TESTPOOL is wedged; leaving it in place"
		return
	fi
	[[ -n $sd ]] && echo running > /sys/block/$sd/device/state
	stop_writer
	zinject -c all
	poolexists $TESTPOOL && zpool clear $TESTPOOL
	destroy_pool $TESTPOOL
	unload_scsi_debug
	rm -f $FILEVDEV $CACHEFILE $STOPFILE
	restore_tunable DIRTY_DATA_MAX
}

log_onexit cleanup

log_assert "zpool clear resumes a pool that suspended while" \
    "spa_vdev_resilver_done() waited for the config lock"

save_tunable DIRTY_DATA_MAX
log_must set_tunable64 DIRTY_DATA_MAX $((32 * 1024 * 1024))

load_scsi_debug 512 1 1 1 '512b'
sd=$(get_debug_device)

typeset -i hit=0 attempt
for attempt in 1 2 3 4 5; do
	log_must truncate -s 512M $FILEVDEV
	log_must zpool create -f -o failmode=wait -o cachefile=$CACHEFILE \
	    -O compression=off $TESTPOOL $FILEVDEV
	log_must dd if=/dev/urandom of=/$TESTPOOL/seed bs=1M count=16
	log_must zpool sync $TESTPOOL

	rm -f $STOPFILE
	(while [[ ! -f $STOPFILE ]]; do
		dd if=/dev/urandom of=/$TESTPOOL/file bs=1M count=16 \
		    conv=notrunc status=none || sleep 1
	done) &
	WPID=$!
	log_must zinject -d $FILEVDEV -D $DELAY_MS:1 $TESTPOOL

	log_must zpool replace -f $TESTPOOL $FILEVDEV $sd
	log_must zinject -d $sd -D $DELAY_MS:1 $TESTPOOL

	# Wait for the detach: the file leaves the cachefile.
	typeset -i tries=3000
	while grep -qa "$FILEVDEV" $CACHEFILE; do
		((tries-- > 0)) || log_fail "replaced vdev was never detached"
		sleep 0.02
	done

	# Fail the running sync without a ZFS command.
	echo offline > /sys/block/$sd/device/state
	tries=120
	until [[ $(kstat_pool $TESTPOOL state) == "SUSPENDED" ]]; do
		((tries-- > 0)) || log_fail "pool didn't suspend"
		sleep 0.25
	done

	if resilver_done_waiting; then
		hit=1
		break
	fi
	log_note "attempt $attempt: spa_vdev_resilver_done() not waiting"

	# Missed it: resume, and start over.
	echo running > /sys/block/$sd/device/state
	log_must zinject -c all
	log_must zpool clear $TESTPOOL
	stop_writer
	destroy_pool $TESTPOOL
	rm -f $FILEVDEV
done

((hit)) || log_fail "the pool never suspended while" \
    "spa_vdev_resilver_done() was waiting"
log_note "attempt $attempt: pool suspended while" \
    "spa_vdev_resilver_done() was waiting"

if ! returns_within 30 zpool status $TESTPOOL; then
	WEDGED=1
	log_fail "zpool status on the suspended pool hung"
fi

# Return the disk and resume.
echo running > /sys/block/$sd/device/state
if ! returns_within 60 zpool clear $TESTPOOL; then
	WEDGED=1
	log_fail "zpool clear hung"
fi

tries=120
until [[ $(kstat_pool $TESTPOOL state) == "ONLINE" ]]; do
	((tries-- > 0)) || log_fail "pool didn't resume"
	sleep 0.5
done
stop_writer
log_must zinject -c all

tries=120
while resilver_done_waiting; do
	((tries-- > 0)) || log_fail "spa_vdev_resilver_done() still waiting"
	sleep 0.5
done
log_must zpool sync $TESTPOOL
log_mustnot eval "zpool status -P $TESTPOOL | grep -q $FILEVDEV"

log_pass "zpool clear resumes a pool that suspended while" \
    "spa_vdev_resilver_done() waited for the config lock"
