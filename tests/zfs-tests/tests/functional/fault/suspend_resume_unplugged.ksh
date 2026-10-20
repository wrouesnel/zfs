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
#	A single-disk pool whose disk drops off the bus while it is being
#	written must suspend, and resume with 'zpool clear' once the disk is
#	back (under a new device name).
#
# STRATEGY:
#	1. Create a pool on a scsi_debug disk, by its persistent name, and
#	   write a file.
#	2. Five times: write in the background and delete the disk (as a USB
#	   disk that resets): the pool must suspend.  Rescan the SCSI host:
#	   the disk comes back.  'zpool clear' must resume the pool, and the
#	   writers must finish.
#	3. The file written first must read back intact after an export and
#	   import.
#
# NOTES:
#	Whether the kernel's removal of the disk lands before the writes are
#	reissued is a race; the hangs this checks for happen on some cycles
#	only, so it unplugs the disk several times.
#

verify_runnable "global"

DATAFILE=$TEST_BASE_DIR/suspend_resume_unplugged.data

function cleanup
{
	[[ -n "$wpid" ]] && kill $wpid 2>/dev/null
	[[ -n "$host" ]] && scan_scsi_hosts $host
	block_device_wait
	poolexists $TESTPOOL1 && zpool clear $TESTPOOL1
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	unload_scsi_debug
	rm -f $DATAFILE
}

log_assert "a single-disk pool resumes after its disk drops off and returns"
log_onexit cleanup

typeset wpid="" host=""

log_must dd if=/dev/urandom of=$DATAFILE bs=128K count=8
typeset sum1=$(xxh128digest $DATAFILE)

load_scsi_debug 256 1 1 1 '512b'
sd=$(get_debug_device)
id=$(get_persistent_disk_name $sd)
[[ -n "$id" ]] || log_fail "no persistent name for $sd"
host=$(get_scsi_host $sd)

log_must zpool create -f $TESTPOOL1 $id
log_must cp $DATAFILE /$TESTPOOL1/file
sync_pool $TESTPOOL1 true

# unplug_cycle N: unplug the disk during writes, wait for the pool to
# suspend, plug it back, and resume the pool.
function unplug_cycle
{
	typeset n=$1
	typeset sd=$(basename $(readlink -f /dev/disk/by-id/$id))
	typeset -i tries

	log_note "cycle $n: disk $sd"
	# Many writes in flight when the disk goes.
	(
		typeset -i i
		for ((i = 0; i < 4; i++)); do
			for f in w1 w2 w3 w4; do
				dd if=/dev/urandom of=/$TESTPOOL1/$f bs=1M \
				    count=16 conv=fsync 2>/dev/null &
			done
			wait
		done
	) &
	wpid=$!
	sleep 2

	# The disk drops off the bus.
	log_must eval "echo 1 > /sys/block/$sd/device/delete"

	tries=60
	until [[ $(kstat_pool $TESTPOOL1 state) == "SUSPENDED" ]]; do
		if ((tries-- == 0)); then
			zpool status -v $TESTPOOL1
			log_fail "cycle $n: pool didn't suspend"
		fi
		sleep 1
	done
	zpool status $TESTPOOL1

	# The disk comes back, under whatever name the kernel gives it.
	scan_scsi_hosts $host
	block_device_wait /dev/disk/by-id/$id
	log_note "cycle $n: disk back as $(readlink -f /dev/disk/by-id/$id)"

	log_must zpool clear $TESTPOOL1

	tries=120
	while kill -0 $wpid 2>/dev/null; do
		if ((tries-- == 0)); then
			zpool status -v $TESTPOOL1
			log_fail "cycle $n: the writers are still blocked"
		fi
		sleep 1
	done
	wpid=""
	zpool status $TESTPOOL1
	[[ $(kstat_pool $TESTPOOL1 state) == "SUSPENDED" ]] && \
	    log_fail "cycle $n: pool suspended again"
	log_must check_state $TESTPOOL1 "" "online"
	log_must zpool clear $TESTPOOL1
}

for n in 1 2 3 4 5; do
	unplug_cycle $n
done

[[ $(kstat_pool $TESTPOOL1 state) == "SUSPENDED" ]] && log_fail "pool suspended"
log_must zpool export $TESTPOOL1
log_must zpool import -d /dev/disk/by-id $TESTPOOL1
log_must test "$sum1" = "$(xxh128digest /$TESTPOOL1/file)"

log_pass "a single-disk pool resumes after its disk drops off and returns"
