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
# Copyright (c) 2026 by Will Rouesnel.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/events/events_common.kshlib

#
# DESCRIPTION:
#	ZED reaps every zedlet it runs, so it keeps running zedlets for a
#	burst of events and exits on SIGTERM.
#
#	ZED's reaper thread waited for SIGCHLD with pause() after wait4()
#	found no exited child.  A zedlet that exited in between had its
#	SIGCHLD taken before pause(), so the reaper slept with the zombie
#	unreaped and its job slot was never returned.  With one job slot
#	(-j 1, as ZTS runs ZED) the main thread then waits for a slot
#	forever: no more zedlets run, no event reaches the agents, and
#	SIGTERM is never acted on.
#
# STRATEGY:
#	1. Start ZED (one job slot) and keep it and its zedlets on one CPU,
#	   which makes a zedlet exit while the reaper is between wait4()
#	   and its wait for SIGCHLD more likely.
#	2. Post a burst of history events.
#	3. Wait for ZED to finish every zedlet it started, up to the last
#	   event; fail if it makes no progress for 30 s, and list any
#	   unreaped zedlet.
#	4. Stop ZED with SIGTERM within 10 s.
#

verify_runnable "global"

EVENTS=200
PROP="org.openzfs:zedlet_reap"

function cleanup
{
	typeset pids=$(zed_check)

	# A ZED that lost a zedlet ignores SIGTERM; don't let it outlive us.
	if [[ -n "$pids" ]]; then
		kill $pids 2>/dev/null
		sleep 2
		pids=$(zed_check)
		[[ -n "$pids" ]] && kill -9 $pids 2>/dev/null
	fi
	log_must zed_stop
	zfs inherit $PROP $TESTPOOL
}

#
# Print the zedlets of ZED process $1 that have exited but were not reaped.
#
function zombie_zedlets # pid
{
	ps -o pid=,stat=,args= --ppid $1 | awk '$2 ~ /^Z/'
}

log_assert "ZED reaps every zedlet and keeps running zedlets"
log_onexit cleanup

command -v taskset >/dev/null || log_unsupported "taskset is not available"

log_must zed_start
zedpid=$(zed_check)
log_must taskset -a -p -c 0 $zedpid

log_must zpool events -c
for i in $(seq 1 $EVENTS); do
	zfs set $PROP=$i $TESTPOOL || log_fail "zfs set $PROP=$i failed"
done
last=$(zpool events -v $TESTPOOL | awk '$1 == "eid" { e = $3 } END { print e }')
[[ -n "$last" ]] || log_fail "no events for $TESTPOOL"
last=$((last))
log_note "posted $EVENTS events, last eid $last"

#
# ZED runs one zedlet at a time and looks for a free slot every 200 ms, so
# the burst takes a while; wait for as long as it keeps making progress.
#
typeset -i still=0
typeset prev="" cur=""
while :; do
	invoked=$(grep -c '^Invoking ' $ZED_LOG)
	finished=$(grep -c '^Finished ' $ZED_LOG)
	if grep -q "^Invoking .* eid=$last " $ZED_LOG &&
	    (( invoked == finished )); then
		break
	fi
	cur="$invoked/$finished"
	if [[ "$cur" == "$prev" ]]; then
		(( still += 1 ))
	else
		still=0
	fi
	prev=$cur
	if (( still >= 30 )); then
		zombie_zedlets $zedpid
		tail -n 5 $ZED_LOG
		log_fail "ZED stuck for 30 s after $finished of $invoked" \
		    "zedlets (last eid $last)"
	fi
	sleep 1
done
log_note "ZED ran $finished zedlets up to eid $last"
[[ -z "$(zombie_zedlets $zedpid)" ]] || log_fail "unreaped zedlets left"

kill $zedpid
SECONDS=0
while [[ -n "$(zed_check)" ]] && (( SECONDS < 10 )); do
	sleep 1
done
[[ -z "$(zed_check)" ]] || log_fail "ZED ignored SIGTERM for 10 s"

log_pass "ZED reaps every zedlet and keeps running zedlets"
