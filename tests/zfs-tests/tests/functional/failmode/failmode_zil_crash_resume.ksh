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

. $STF_SUITE/tests/functional/failmode/failmode.kshlib

#
# DESCRIPTION:
# When the pool suspends while zil_commit() is filling a log block, the
# ZIL crashes and abandons that block half-filled.  After the pool
# resumes, the block must be cleaned up only once nothing uses it any
# more, the ZIL must restart, and no space may leak.
#
# STRATEGY:
# 1. Create a failmode=wait pool, start its ZIL with a sync write, and
#    stop txgs from syncing on their own.
# 2. Make one log write slow, so that the ZIL's latency estimate is
#    high, and raise zfs_commit_timeout_pct: an fsync() that finds the
#    previous log block still in flight leaves its own block open for
#    about 10 seconds before it fills and issues it.
# 3. Write a full record to a file without syncing it, so its
#    WR_INDIRECT log record waits in the open txg.
# 4. Start a slow sync write to another file, and fsync() the first
#    file while that log write is in flight.
# 5. Make uberblock writes fail and sync the txg, so the pool suspends
#    while it is the syncing txg.  When the fsync() fills its block,
#    dmu_sync() can't log the block of a syncing txg while the pool is
#    suspended, so zil_lwb_commit() crashes the ZIL with that log block
#    unissued, and the fsync falls back to a txg wait.
# 6. Clear the errors and the pool, and verify that fsync() returns,
#    txgs sync, the ZIL restarts, the data is intact and no space has
#    leaked.
#

verify_runnable "global"

typeset saved=""
typeset wedged=""
typeset -a pids=()

function cleanup
{
	zinject -c all >/dev/null 2>&1
	if [[ -n "$saved" ]]; then
		restore_tunable TXG_TIMEOUT
		restore_tunable COMMIT_TIMEOUT_PCT
	fi
	if [[ -n "$wedged" ]]; then
		log_note "Skipping pool cleanup: txgs are stuck, reboot"
		return
	fi
	poolexists $TESTPOOL && zpool clear $TESTPOOL
	for pid in "${pids[@]}"; do
		wait $pid 2>/dev/null
	done
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	rm -f $sum
}

# Wait up to $1 seconds for process $2 to exit.
function wait_exited
{
	typeset -i tries=$1
	while kill -0 $2 2>/dev/null; do
		((tries-- == 0)) && return 1
		sleep 1
	done
	return 0
}

# Fail when txgs no longer sync; the pool can't be cleaned up then.
function stuck
{
	wedged=yes
	log_fail "$@"
}

typeset file=/$TESTPOOL/$TESTFS/file
typeset sum=$TEST_BASE_DIR/failmode_zil_crash_resume.sum

log_onexit cleanup

log_assert "A ZIL that crashed while filling a log block restarts after resume"

read -r DISK1 _ <<<"$DISKS"
if [[ $DISK1 == /* ]]; then
	typeset devdir=$(dirname $DISK1)
else
	typeset devdir=$DEV_DSKDIR
fi
log_must zpool create -f -o failmode=wait $TESTPOOL $DISK1
log_must zfs create -o recordsize=128k -o compression=off \
    -o logbias=throughput $TESTPOOL/$TESTFS

# The first sync write creates the ZIL, so the fsync below has a log
# block to fill without waiting for a txg.
log_must dd if=/dev/urandom of=$file bs=128k count=1 oflag=sync
log_must zpool sync $TESTPOOL

log_must save_tunable TXG_TIMEOUT
log_must save_tunable COMMIT_TIMEOUT_PCT
saved=yes
log_must set_tunable32 TXG_TIMEOUT 3600
log_must zpool sync $TESTPOOL

# A 2 s log write puts the ZIL's latency estimate above 250 ms; an open
# log block then waits 40 times that for more records.
log_must zinject -d $DISK1 -D 2000:1 -T write $TESTPOOL
log_must dd if=/dev/urandom of=$file.slow bs=4k count=1 oflag=sync
log_must set_tunable32 COMMIT_TIMEOUT_PCT 4000

# A full record, not synced: its log record is WR_INDIRECT, in the open txg.
log_must dd if=/dev/urandom of=$file bs=128k count=1 conv=notrunc
log_must eval "xxh128digest $file > $sum"

# While a slow log write is in flight, the fsync's block stays open.
dd if=/dev/urandom of=$file.slow bs=4k count=1 oflag=sync &
pids+=($!)
sleep 0.5
log_must zinject -c all
typeset -i zilerr=$(kstat zil.zil_commit_error_count)
typeset -i indirect=$(kstat zil.zil_itx_indirect_count)
dd if=/dev/null of=$file conv=notrunc,fsync &
typeset -i fsync_pid=$!
pids+=($fsync_pid)
sleep 0.5
kill -0 $fsync_pid || log_fail "fsync returned before the pool suspended"

log_must zinject -d $DISK1 -e io -T write -L uber $TESTPOOL
zpool sync $TESTPOOL &
pids+=($!)

log_note "waiting for pool to suspend"
typeset -i tries=30
until [[ $(kstat_pool $TESTPOOL state) == "SUSPENDED" ]] ; do
	if ((tries-- == 0)); then
		log_fail "pool didn't suspend"
	fi
	sleep 1
done

# The fsync's commit timeout fires and it fills its log block, logging
# the WR_INDIRECT record, while the pool is suspended.
log_note "waiting for the fsync to fill its log block"
tries=60
until (( $(kstat zil.zil_itx_indirect_count) > indirect )); do
	if ((tries-- == 0)); then
		log_fail "the fsync did not fill its log block"
	fi
	sleep 1
done
sleep 1
kill -0 $fsync_pid || log_fail "fsync returned while the pool was suspended"

log_must zinject -c all

# A panic in txg_sync, or a lost wakeup, leaves these stuck.
zpool clear $TESTPOOL &
typeset -i clear_pid=$!
pids+=($clear_pid)
wait_exited 60 $clear_pid || stuck "zpool clear did not return"
wait $clear_pid || log_fail "zpool clear failed"
wait_exited 60 $fsync_pid || stuck "fsync did not return after the resume"
wait $fsync_pid || log_fail "fsync failed after the resume"
# The fsync's log block failed, and it fell back to a txg wait.
(( $(kstat zil.zil_commit_error_count) > zilerr )) || \
    log_fail "the fsync's log block did not fail during the suspension"
for i in 1 2 3 4 5; do
	zpool sync $TESTPOOL &
	pids+=($!)
	wait_exited 60 $! || stuck "txgs stopped syncing after the resume"
done
log_must test "$(kstat_pool $TESTPOOL state)" = "ONLINE"

log_must restore_tunable TXG_TIMEOUT
log_must restore_tunable COMMIT_TIMEOUT_PCT
saved=""

# The ZIL has restarted: a sync write is committed through it again, not
# by the crashed ZIL's txg_wait_synced() fallback.
typeset -i commits=$(kstat zil.zil_commit_count)
typeset -i crashed=$(kstat zil.zil_commit_crash_count)
log_must dd if=/dev/urandom of=$file.2 bs=4k count=1 oflag=sync
log_must test $(kstat zil.zil_commit_crash_count) -eq $crashed
log_must test $(kstat zil.zil_commit_count) -gt $commits

typeset guid=$(get_pool_prop guid $TESTPOOL)
log_must zpool export $TESTPOOL

# The abandoned log block's space was freed, not leaked.
typeset out=$(zdb -e -p $devdir -b $guid 2>&1)
log_note "$out"
if echo "$out" | grep -q "leaked space"; then
	log_fail "The pool leaked space"
fi
echo "$out" | grep -q "No leaks" || log_fail "zdb did not check for leaks"

log_must zpool import -d $devdir $guid
log_must test "$(xxh128digest $file)" = "$(cat $sum)"

log_pass "A ZIL that crashed while filling a log block restarts after resume"
