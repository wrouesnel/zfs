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
# Synchronous overwrites logged WR_INDIRECT must not fill a pool with
# dmu_sync() override blocks and suspend it.
#
# STRATEGY:
# 1. Create a pool on a 1 GiB file vdev and fill it to leave about
#    200 MiB available, as enospc_zil does.
# 2. Raise the txg timeout and zfs_wrlog_data_max, so that only the
#    space check ends a txg.
# 3. Rewrite four 512 KiB files with sync=always for 60 seconds, in
#    whole 128 KiB records: each write is logged WR_INDIRECT, so
#    dmu_sync() writes a new block for it in open context, and the
#    override block it replaces is freed only when the txg syncs.
# 4. Do the same for 60 seconds with logbias=throughput and 16 KiB
#    records and writes.
# 5. Fail if the pool suspended or a log write failed after either.
#    A suspended pool cannot be destroyed, so it is left in place under
#    its own name.
#

verify_runnable "global"

typeset POOL=${TESTPOOL}dms
typeset VDEV=$TEST_BASE_DIR/enospc_dmu_sync_vdev
typeset pids=""

function pool_suspended
{
	[[ $(kstat_pool $POOL state 2>/dev/null) == "SUSPENDED" ]]
}

function cleanup
{
	[[ -n "$pids" ]] && kill $pids 2>/dev/null
	wait
	restore_tunable TXG_TIMEOUT
	restore_tunable WRLOG_DATA_MAX
	if poolexists $POOL && pool_suspended; then
		log_note "$POOL is suspended, leaving it in place"
		return
	fi
	poolexists $POOL && destroy_pool $POOL
	rm -f $VDEV
}

log_onexit cleanup

log_assert "WR_INDIRECT synchronous writes do not fill a pool with" \
    "override blocks"

typeset -i mib=$((1024 * 1024))

log_must truncate -s 1G $VDEV
log_must zpool create -f -o failmode=continue $POOL $VDEV
log_must zfs create -o compression=off $POOL/fill
log_must zfs create -o compression=off -o recordsize=128k -o sync=always \
    $POOL/full
log_must zfs create -o compression=off -o recordsize=16k -o sync=always \
    -o logbias=throughput $POOL/tput

typeset -i fill=$((($(get_prop available $POOL) - 200 * mib) / mib))
log_must dd if=/dev/zero of=/$POOL/fill/file bs=1M count=$fill
for i in 1 2 3 4; do
	log_must dd if=/dev/urandom of=/$POOL/full/file$i bs=128k count=4
	log_must dd if=/dev/urandom of=/$POOL/tput/file$i bs=16k count=32
done
sync_pool $POOL

log_must save_tunable TXG_TIMEOUT
log_must set_tunable32 TXG_TIMEOUT 120
log_must save_tunable WRLOG_DATA_MAX
log_must set_tunable64 WRLOG_DATA_MAX $((4096 * mib))

function writer # file bs count seconds
{
	typeset -i end=$((SECONDS + $4))

	while ((SECONDS < end)); do
		dd if=/dev/urandom of=$1 bs=$2 count=$3 conv=notrunc \
		    2>/dev/null || return 1
	done
}

function rewrite # fs bs count
{
	typeset -i errors_before=$(kstat zil.zil_commit_error_count)
	typeset -i suspended=0 i deadline

	for i in 1 2 3 4; do
		writer /$POOL/$1/file$i $2 $3 60 &
		pids="$pids $!"
	done

	deadline=$((SECONDS + 90))
	while ((SECONDS < deadline)) && kill -0 $pids 2>/dev/null; do
		if pool_suspended; then
			suspended=1
			break
		fi
		sleep 1
	done
	pool_suspended && suspended=1

	typeset -i errors=$(($(kstat zil.zil_commit_error_count) - \
	    errors_before))
	log_note "$1: bs=$2 count=$3, commit errors: $errors," \
	    "free: $(($(get_pool_prop free $POOL) / mib)) MiB"

	((suspended)) && log_fail "The pool suspended ($1)"
	((errors == 0)) || log_fail "$errors log writes failed ($1)"

	log_must wait $pids
	pids=""
}

rewrite full 128k 4
rewrite tput 16k 32
log_must zpool sync $POOL

log_pass "WR_INDIRECT synchronous writes do not fill a pool with" \
    "override blocks"
