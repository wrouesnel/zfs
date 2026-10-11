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
# With failmode=wait, a zpool command that has completed must not block
# forever writing its history record because the pool suspended after the
# command ran.
#
# STRATEGY:
# 1. Create a pool with failmode=wait, and inject write errors into its
#    uberblock writes, so that each txg sync fails and suspends the pool
#    without leaving any I/O to retry.
# 2. Suspend the pool, then run "zpool clear" with the errors still
#    injected: the clear resumes the pool and succeeds, and the next txg
#    sync suspends it again.  zfs_history_log_delay_ms delays the history
#    write that follows the clear until the pool has suspended again.
# 3. Verify that "zpool clear" exits, and that the pool is still suspended.
# 4. Resume the pool, run "zpool set" and suspend the pool while its
#    history write is delayed.  Verify that "zpool set" exits.
#

verify_runnable "global"

typeset -i cmd_pid=0

function stop_injection
{
	set_tunable32 HISTORY_LOG_DELAY_MS 0
	zinject -c all
	zpool clear $TESTPOOL
}

function cleanup
{
	stop_injection
	if ((cmd_pid != 0)); then
		wait $cmd_pid
	fi
	# the writes started to suspend the pool
	wait
	destroy_pool $TESTPOOL
}

log_onexit cleanup

log_assert "With failmode=wait, a completed command does not block" \
    "writing its history record to a suspended pool"

DISK=${DISKS%% *}

function wait_for_state # state
{
	typeset -i tries=300
	until [[ $(kstat_pool $TESTPOOL state) == $1 ]]; do
		if ((tries-- == 0)); then
			log_fail "pool state is $(kstat_pool $TESTPOOL state)," \
			    "expected $1"
		fi
		sleep 0.1
	done
}

function start_suspend
{
	log_must zinject -d $DISK -e io -T write -L uber $TESTPOOL
	# these block until the pool resumes
	dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file.$1 bs=128k count=4 &
	zpool sync $TESTPOOL &
}

#
# Wait for a command that has run in the background to exit.  If it has
# not exited within 30 seconds after its history write, it is blocked:
# log its stack, resume the pool so that it can finish, and fail.
#
function check_exits # pid what
{
	typeset -i pid=$1
	typeset what=$2
	typeset -i tries=$(((HISTORY_DELAY_MS / 1000 + 30) * 10))

	while kill -0 $pid 2>/dev/null; do
		if ((tries-- == 0)); then
			log_note "$what is blocked, pool" \
			    "$(kstat_pool $TESTPOOL state):"
			if is_linux; then
				cat /proc/$pid/stack
			else
				procstat -kk $pid
			fi
			stop_injection
			wait $pid
			cmd_pid=0
			log_fail "$what blocked writing history to the" \
			    "suspended pool"
		fi
		sleep 0.1
	done
	wait $pid
	typeset -i rc=$?
	cmd_pid=0
	log_must test $rc -eq 0
}

typeset -i HISTORY_DELAY_MS=2000

log_must zpool create -f -o failmode=wait $TESTPOOL $DISK
log_must zfs create $TESTPOOL/$TESTFS
log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file bs=128k count=8
sync_pool $TESTPOOL

# zpool clear with the errors still injected
start_suspend 1
wait_for_state SUSPENDED
log_must set_tunable32 HISTORY_LOG_DELAY_MS $HISTORY_DELAY_MS
zpool clear $TESTPOOL &
cmd_pid=$!
check_exits $cmd_pid "zpool clear"
log_must test "$(kstat_pool $TESTPOOL state)" == "SUSPENDED"

log_must set_tunable32 HISTORY_LOG_DELAY_MS 0
log_must zinject -c all
log_must zpool clear $TESTPOOL
wait_for_state ONLINE
wait

# a command that succeeds on a healthy pool, which suspends before the
# command's history is written
log_must set_tunable32 HISTORY_LOG_DELAY_MS $HISTORY_DELAY_MS
zpool set comment=failmode_history $TESTPOOL &
cmd_pid=$!
typeset -i tries=100
until [[ $(get_pool_prop comment $TESTPOOL) == "failmode_history" ]]; do
	if ((tries-- == 0)); then
		log_fail "zpool set did not set the comment"
	fi
	sleep 0.1
done
start_suspend 2
wait_for_state SUSPENDED
check_exits $cmd_pid "zpool set"

log_pass "With failmode=wait, a completed command does not block" \
    "writing its history record to a suspended pool"
