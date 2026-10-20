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
# Description:
# A pool imported read-only can be suspended by an I/O failure like any
# other pool. Once the device is back, 'zpool clear' must resume it, as
# it does for a read-write pool; otherwise the pool, and every process
# waiting on it, is stuck until reboot.
#
# Strategy:
# 1. Create a single-disk pool on a scsi_debug device, write a file and
#    take its checksum, export it and import it read-only.
# 2. "Pull" the disk and read the file in the background, until the pool
#    suspends.
# 3. Return the disk and run 'zpool clear'.
# 4. Verify the pool is no longer suspended, the read completes with the
#    right checksum, and the pool exports.
# 5. Verify 'zpool clear' of a read-only pool that isn't suspended still
#    fails.
#

. $STF_SUITE/include/libtest.shlib

DATAFILE=$(mktemp)
SUMFILE=$(mktemp)

function cleanup
{
	if [[ -n "$sd" ]]; then
		echo running > /sys/block/$sd/device/state
	fi
	zpool clear $TESTPOOL
	destroy_pool $TESTPOOL
	unload_scsi_debug
	rm -f $DATAFILE $SUMFILE
}

log_onexit cleanup

log_assert "a suspended read-only pool resumes after the disk returns" \
    "and 'zpool clear'"

log_must dd if=/dev/urandom of=$DATAFILE bs=128K count=16
typeset sum1=$(xxh128digest $DATAFILE)

# a debug device that we can "unplug"
load_scsi_debug 100 1 1 1 '512b'
sd=$(get_debug_device)

log_must zpool create -o failmode=wait $TESTPOOL $sd
log_must cp $DATAFILE /$TESTPOOL/file
log_must zpool export $TESTPOOL
log_must zpool import -o readonly=on -d /dev $TESTPOOL
log_must test "$(get_pool_prop readonly $TESTPOOL)" = "on"

# "pull" the disk, and read the file: it isn't cached since the import
log_must eval "echo offline > /sys/block/$sd/device/state"
xxh128digest /$TESTPOOL/file > $SUMFILE &
typeset readpid=$!

log_note "waiting for pool to suspend"
typeset -i tries=30
until [[ $(kstat_pool $TESTPOOL state) == "SUSPENDED" ]] ; do
	if ((tries-- == 0)); then
		log_fail "pool didn't suspend"
	fi
	sleep 1
done

# return the disk, and clear: this must reopen the vdev and resume the
# failed reads, even though the pool is read-only
log_must eval "echo running > /sys/block/$sd/device/state"
log_must zpool clear $TESTPOOL

log_note "waiting for the read to finish"
tries=30
while kill -0 $readpid 2>/dev/null; do
	if ((tries-- == 0)); then
		log_fail "read still blocked after 'zpool clear'"
	fi
	sleep 1
done
wait $readpid

if [[ $(kstat_pool $TESTPOOL state) == "SUSPENDED" ]] ; then
	log_fail "pool still suspended after 'zpool clear'"
fi
log_must test "$sum1" = "$(<$SUMFILE)"

# a read-only pool that isn't suspended has nothing to resume, and clear
# is still refused for it
log_mustnot zpool clear $TESTPOOL

# the reopened vdev's async work can keep the pool busy for a moment
log_must_busy zpool export $TESTPOOL

log_pass "a suspended read-only pool resumes after the disk returns" \
    "and 'zpool clear'"
