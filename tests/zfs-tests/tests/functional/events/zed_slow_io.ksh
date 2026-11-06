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
# Copyright (c) 2023, Klara Inc.
# Copyright (c) 2025, Mariusz Zaborski <oshogbo@FreeBSD.org>
#

# DESCRIPTION:
#	Verify that vdev properties, slow_io_n and slow_io_t, work with ZED.
#
# STRATEGY:
#	1. Create a pool with single vdev
#	2. Set slow_io_n/slow_io_t to non-default values
#	3. Inject slow io errors
#	4. Verify that ZED degrades vdev
#
#	The cases that must not degrade the vdev don't wait for a fixed
#	time.  The delay ereports are posted before the slow reads
#	return, so they are counted right after the reads.  The test
#	then waits until the ZED diagnosis engine has logged every one
#	of them, and checks that it solved no fault and degraded nothing.
#

. $STF_SUITE/include/libtest.shlib

TESTDIR="$TEST_BASE_DIR/zed_slow_io"
VDEV="$TEST_BASE_DIR/vdevfile.$$"
TESTPOOL="slow_io_pool"
FILEPATH="$TESTDIR/slow_io.testfile"

OLD_SLOW_IO=$(get_tunable ZIO_SLOW_IO_MS)
OLD_SLOW_IO_EVENTS=$(get_tunable SLOW_IO_EVENTS_PER_SECOND)

verify_runnable "both"

# Lines in the ZED log when the current case began.
typeset -i LOG_MARK=0

function do_setup
{
	log_must truncate -s 1G $VDEV
	default_setup_noexit $VDEV
	zed_events_drain
	LOG_MARK=$(wc -l < $ZED_LOG)
	log_must zfs set compression=off $TESTPOOL
	log_must zfs set primarycache=none $TESTPOOL
	log_must zfs set prefetch=none $TESTPOOL
	log_must zfs set recordsize=512 $TESTPOOL
	for i in {1..10}; do
		dd if=/dev/urandom of=${FILEPATH}$i bs=512 count=1 2>/dev/null
	done
	zpool sync
}

# intermediate cleanup
function do_clean
{
	log_must zinject -c all
	log_must zpool destroy $TESTPOOL
	log_must rm -f $VDEV
}

# final cleanup
function cleanup
{
	log_must zinject -c all

	# if pool still exists then something failed so log additional info
	if poolexists $TESTPOOL ; then
		log_note "$(zpool status -s $TESTPOOL)"
		echo "=================== zed log search ==================="
		grep "Diagnosis Engine" $ZEDLET_DIR/zed.log
		destroy_pool $TESTPOOL
	fi
	log_must zed_stop

	log_must rm -f $VDEV

	log_must set_tunable64 ZIO_SLOW_IO_MS $OLD_SLOW_IO
	log_must set_tunable64 SLOW_IO_EVENTS_PER_SECOND $OLD_SLOW_IO_EVENTS
}

function start_slow_io
{
	zpool sync
	log_must set_tunable64 ZIO_SLOW_IO_MS 10
	log_must set_tunable64 SLOW_IO_EVENTS_PER_SECOND 1000

	log_must zinject -d $VDEV -D10:1 -T read $TESTPOOL
	zpool sync
}

function stop_slow_io
{
	log_must set_tunable64 ZIO_SLOW_IO_MS $OLD_SLOW_IO
	log_must set_tunable64 SLOW_IO_EVENTS_PER_SECOND $OLD_SLOW_IO_EVENTS

	log_must zinject -c all
}

# What ZED has logged since the current case began.
function zed_log_case
{
	tail -n +$((LOG_MARK + 1)) $ZED_LOG
}

function delay_events
{
	zpool events | grep -c "ereport\.fs\.zfs\.delay"
}

#
# Wait for the ZED diagnosis engine to log every delay ereport of the
# vdev, then check that it solved no fault and degraded nothing.  The
# diagnosis engine logs each ereport of a case it hasn't solved.  The
# wait has no fixed length: on a stalled system it lasts as long as ZED
# needs.
#
function verify_diagnosed_no_degrade # events
{
	typeset -i events=$1
	typeset guid=$(zpool get -Hp -o value guid $TESTPOOL $VDEV)
	typeset pattern="error event 'ereport\.fs\.zfs\.delay', vdev $guid\$"
	typeset -i seen=0
	typeset -i solved=0
	typeset -i i=0

	while [[ $i -lt 300 ]]; do
		seen=$(zed_log_case | grep -c "$pattern")
		solved=$(zed_log_case | grep -c "solving fault")
		[[ $seen -ge $events || $solved -gt 0 ]] && break
		i=$((i+1))
		sleep 1
	done
	log_note "ZED diagnosed $seen of $events delay events after $i seconds"
	[[ $solved -eq 0 ]] || log_fail "expecting no fault, ZED solved $solved"
	[[ $seen -ge $events ]] || \
	    log_fail "ZED diagnosed only $seen of $events delay events"

	typeset -i degrades=$(zed_log_case | grep -c "zpool_vdev_degrade")
	[[ $degrades -eq 0 ]] || \
	    log_fail "expecting no degrade events, found $degrades"
	log_must check_vdev_state $TESTPOOL $VDEV "ONLINE"
}

# Test default ZED settings:
#    inject 10 events over 2.5 seconds, should not degrade.
function default_degrade
{
	do_setup

	start_slow_io
	for i in {1..10}; do
		dd if=${FILEPATH}$i of=/dev/null count=1 bs=512 2>/dev/null
		sleep 0.25
	done
	stop_slow_io
	log_note "$(zpool status -s $TESTPOOL)"

	typeset -i events=$(delay_events)
	log_note "$events delay events found"
	[[ $events -gt 0 ]] || log_fail "expecting delay events, found none"
	verify_diagnosed_no_degrade $events

	do_clean
}

# change slow_io_n, slow_io_t to 5 events in 60 seconds
# fire more than 5 events, should degrade
function slow_io_degrade
{
	do_setup

	log_must zpool set slow_io_n=5 $TESTPOOL $VDEV
	log_must zpool set slow_io_t=60 $TESTPOOL $VDEV

	start_slow_io
	for i in {1..16}; do
		dd if=${FILEPATH}$i of=/dev/null count=1 bs=512 2>/dev/null
		sleep 0.5
	done
	stop_slow_io
	zpool sync

	#
	# wait up to 60 seconds for kernel to produce at least 5 delay events
	#
	typeset -i i=0
	typeset -i events=0
	while [[ $i -lt 60 ]]; do
		events=$(zpool events | grep "ereport\.fs\.zfs.delay" | wc -l)
		[[ $events -ge "5" ]] && break
		i=$((i+1))
		sleep 1
	done
	log_note "$events delay events found"

	if [[ $events -ge "5" ]]; then
		log_must wait_vdev_state $TESTPOOL $VDEV "DEGRADED" 60
	fi

	do_clean
}

# change slow_io_n, slow_io_t to 10 events in 1 second
# inject events spaced 0.5 seconds apart, should not degrade
function slow_io_no_degrade
{
	do_setup

	zpool set slow_io_n=10 $TESTPOOL $VDEV
	zpool set slow_io_t=1 $TESTPOOL $VDEV

	start_slow_io
	for i in {1..16}; do
		dd if=${FILEPATH}$i of=/dev/null count=1 bs=512 2>/dev/null
		sleep 0.5
	done
	stop_slow_io
	zpool sync

	typeset -i events=$(delay_events)
	log_note "$events delay events found"
	[[ $events -gt 0 ]] || log_fail "expecting delay events, found none"
	verify_diagnosed_no_degrade $events

	do_clean
}

# Change slow_io_n, slow_io_t to 5 events in 60 seconds
# fire more than 5 events. Disable slow io events.
# Should not degrade.
function slow_io_degrade_disabled
{
	do_setup

	log_must zpool set slow_io_n=5 $TESTPOOL $VDEV
	log_must zpool set slow_io_t=60 $TESTPOOL $VDEV
	log_must zpool set slow_io_events=off $TESTPOOL $VDEV

	start_slow_io
	for i in {1..16}; do
		dd if=${FILEPATH}$i of=/dev/null count=1 bs=512 2>/dev/null
		sleep 0.5
	done
	stop_slow_io
	zpool sync

	#
	# The reads were slow, but no zfs.delay was generated for them.
	#
	typeset -i slow=$(zpool get -Hp -o value slow_ios $TESTPOOL $VDEV)
	typeset -i events=$(delay_events)
	log_note "$slow slow I/Os, $events delay events found"
	[[ $slow -gt 0 ]] || log_fail "expecting slow I/Os, found none"
	[[ $events -eq 0 ]] || \
		log_fail "expecting no delay events, found $events"
	verify_diagnosed_no_degrade 0

	do_clean
}

log_assert "Test ZED slow io configurability"
log_onexit cleanup

log_must zed_events_drain
log_must zed_start

default_degrade
slow_io_degrade
slow_io_no_degrade
slow_io_degrade_disabled

log_pass "Test ZED slow io configurability"
