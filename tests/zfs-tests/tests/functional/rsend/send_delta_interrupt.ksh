#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0

# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.

. $STF_SUITE/tests/functional/rsend/rsend.kshlib

# Description:
# Verify that "zfs send --refs --delta" can be stopped promptly while it
# is still preparing the stream (finding references and building the
# similarity index), before it has written anything: by SIGTERM, by
# SIGKILL, and when the reader of its output goes away.  (Not SIGINT: a
# non-interactive shell starts background commands with SIGINT ignored.
# Every signal stops the send through the same check.)
# Strategy:
# 1. Create a filesystem with primarycache=metadata and a large file,
#    snapshot @a, then write a new file and snapshot @b, so that --delta
#    builds the similarity index by reading the whole file from disk.
# 2. Before each send, export and import the pool so nothing is cached,
#    and delay every read of its disk (with I/O aggregation disabled), so
#    that preparing the stream takes far longer than ABORT_SECS.  Time
#    one uninterrupted send to check that it does.
# 3. Start the send, check that it has not written anything yet, then
#    interrupt it, and check that it fails within ABORT_SECS.
# 4. Check that the fromsnap is no longer held: it can be destroyed.

verify_runnable "both"

sendfs=$POOL/refs_send
out=$BACKDIR/interrupt
fifo=$BACKDIR/interrupt.fifo
typeset -i nrec=1024
typeset -i ABORT_SECS=10
typeset -i START_SECS=3
typeset -i GIVEUP_SECS=600

function cleanup
{
	zinject -c all >/dev/null 2>&1
	[[ -n "$rpid" ]] && kill $rpid 2>/dev/null
	[[ -n "$pid" ]] && kill -KILL $pid 2>/dev/null
	wait
	[[ -n "$saved_agg" ]] && set_tunable32 VDEV_AGGREGATION_LIMIT $saved_agg
	[[ -n "$saved_agg_nr" ]] && \
	    set_tunable32 VDEV_AGGREGATION_LIMIT_NONROT $saved_agg_nr
	datasetexists $sendfs && destroy_dataset $sendfs -r
	rm -f $out $fifo
}

#
# Drop everything the pool has cached, then make every read of its disk
# take 50 ms, one at a time.
#
function slow_cold_pool
{
	log_must zinject -c all
	log_must zpool export $POOL
	log_must zpool import $POOL
	log_must zinject -d $DISK1 -D 50:1 -T read $POOL
}

#
# Wait up to GIVEUP_SECS for the send to exit.  Sets "took" to the number
# of seconds that took, and "rc" to its exit status.
#
function wait_send
{
	typeset -i start=$SECONDS

	while kill -0 $pid 2>/dev/null; do
		(( SECONDS - start > GIVEUP_SECS )) && break
		sleep 0.2
	done
	took=$((SECONDS - start))
	wait $pid
	rc=$?
	pid=
}

#
# Record whether the send failed within ABORT_SECS of being stopped by $1.
#
function check_stopped
{
	log_note "send exited $rc, $took s after $1"
	if (( rc == 0 || took > ABORT_SECS )); then
		slow="$slow $1"
	fi
}

#
# Start the send with its output on the given file and check that it is
# still preparing the stream after START_SECS.
#
function start_send
{
	slow_cold_pool
	zfs send --refs --delta -i @a $sendfs@b >$1 &
	pid=$!
	sleep $START_SECS
	log_must kill -0 $pid
	log_must test ! -s $out
}

log_assert "zfs send --refs --delta stops promptly while preparing the stream"
log_onexit cleanup

saved_agg=$(get_tunable VDEV_AGGREGATION_LIMIT)
saved_agg_nr=$(get_tunable VDEV_AGGREGATION_LIMIT_NONROT)
log_must set_tunable32 VDEV_AGGREGATION_LIMIT 0
log_must set_tunable32 VDEV_AGGREGATION_LIMIT_NONROT 0

log_must zfs create -o recordsize=$REFS_RECSIZE -o primarycache=metadata \
    $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
refs_mkfile $mntpnt/g 4
log_must zfs snapshot $sendfs@b

# Uninterrupted, the send must take well over ABORT_SECS.
slow_cold_pool
typeset -i start=$SECONDS
log_must eval "zfs send --refs --delta -i @a $sendfs@b >$out"
typeset -i full=$((SECONDS - start))
log_note "uninterrupted send took $full s"
log_must test $full -ge $((ABORT_SECS * 3))
rm -f $out

for sig in TERM KILL; do
	start_send $out
	log_must kill -$sig $pid
	wait_send
	check_stopped SIG$sig
done

# The reader of the output exits.
rm -f $fifo
log_must mkfifo $fifo
cat $fifo >/dev/null &
rpid=$!
start_send $fifo
log_must kill $rpid
rpid=
wait_send
check_stopped "reader exit"

log_must zinject -c all
log_must zfs destroy $sendfs@a
[[ -z "$slow" ]] || log_fail "not stopped within $ABORT_SECS s by:$slow"

log_pass "zfs send --refs --delta stops promptly while preparing the stream"
