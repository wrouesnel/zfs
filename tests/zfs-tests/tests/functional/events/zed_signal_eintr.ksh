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

# DESCRIPTION:
# Verify the ZED keeps running when a signal interrupts its wait for the
# next event, and still exits on SIGTERM.
#
# While idle the ZED sleeps in the ZFS_IOC_EVENTS_NEXT ioctl, which
# returns EINTR when a signal arrives.  SIGSTOP/SIGCONT (job control,
# ptrace, debuggers) and SIGHUP (documented as "rescan the zedlets")
# must not make it exit.
#
# STRATEGY:
# 1. Start the ZED and wait until it has handled an event and is idle.
# 2. Send SIGSTOP, then SIGCONT.  Verify the same ZED process is still
#    running, has not logged "Exiting", and handles a new event.
# 3. Send SIGHUP.  Verify the ZED is still running, rescans its zedlet
#    directory, and handles a new event.
# 4. Send SIGTERM.  Verify the ZED logs "Exiting" and exits.

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/events/events_common.kshlib

verify_runnable "both"

function cleanup
{
	[[ -n "$zedpid" ]] && kill -CONT $zedpid 2>/dev/null
	zed_stop
}

#
# Generate an event, wait for the ZED process 'pid' to run the debug
# zedlet for it, and wait for the ZED to go back to sleep in the kernel,
# waiting for the next event.
#
function zed_handles_event # pid
{
	typeset pid=$1

	log_must truncate -s 0 $ZED_DEBUG_LOG
	log_must zpool scrub -w $TESTPOOL
	log_must file_wait_event $ZED_DEBUG_LOG sysevent.fs.zfs.scrub_finish 60
	log_must grep -q "^ZED_PID=$pid\$" $ZED_DEBUG_LOG
	log_must file_wait $ZED_DEBUG_LOG 2 60

	# The main thread's state is 'S' while it waits in the ioctl.
	typeset -i i=0
	while [[ $(awk '{print $3}' /proc/$pid/stat 2>/dev/null) != "S" ]]; do
		((i++ > 50)) && log_fail "ZED (pid $pid) did not go idle"
		sleep 0.2
	done
	log_note "ZED pid $pid idle"
}

#
# Verify the ZED process 'pid' survived the signal(s) named by 'what'.
#
function zed_survived # pid what
{
	typeset pid=$1
	typeset what=$2

	sleep 2
	if ! kill -0 $pid 2>/dev/null || grep -q "Exiting" $ZED_LOG; then
		cat $ZED_LOG
		log_fail "ZED (pid $pid) exited after $what"
	fi
	log_note "ZED pid $pid still running after $what"
}

log_assert "Verify the ZED survives signals that interrupt its event wait"
log_onexit cleanup

log_must zpool events -c
log_must zed_stop
log_must zed_start

typeset -i i=0
zedpid=""
while [[ -z "$zedpid" ]]; do
	((i++ > 50)) && log_fail "ZED did not start"
	sleep 0.2
	zedpid=$(zed_check)
done
log_note "ZED pid $zedpid"
zed_handles_event $zedpid

# Stop and continue the ZED, as job control or a debugger attach does.
log_must kill -STOP $zedpid
sleep 1
log_must test "$(awk '{print $3}' /proc/$zedpid/stat)" = "T"
log_must kill -CONT $zedpid
zed_survived $zedpid "SIGSTOP/SIGCONT"
zed_handles_event $zedpid

# SIGHUP rescans the zedlet directory and carries on.
nscan=$(grep -c "Registered zedlet" $ZED_LOG)
log_must kill -HUP $zedpid
zed_survived $zedpid "SIGHUP"
i=0
while (( $(grep -c "Registered zedlet" $ZED_LOG) <= nscan )); do
	((i++ > 50)) && log_fail "ZED did not rescan its zedlets after SIGHUP"
	sleep 0.2
done
zed_handles_event $zedpid

# SIGTERM still makes the ZED exit.
log_must kill -TERM $zedpid
i=0
while kill -0 $zedpid 2>/dev/null; do
	((i++ > 50)) && log_fail "ZED (pid $zedpid) did not exit on SIGTERM"
	sleep 0.2
done
log_must grep -q "Exiting" $ZED_LOG
zedpid=""

log_pass "The ZED survives signals that interrupt its event wait"
