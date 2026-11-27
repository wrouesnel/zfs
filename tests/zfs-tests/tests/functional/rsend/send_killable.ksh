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
. $STF_SUITE/tests/functional/rsend/rsend.kshlib

#
# Description:
# A zfs send blocked writing to a full pipe can be killed, and once it
# has exited, nothing holds its snapshot.
#
# On kernels with small stacks (THREAD_SIZE < 16K, so no
# HAVE_LARGE_STACKS), the stream is written on a separate taskq thread
# ("z_send"), and the sending thread used to wait for it uninterruptibly:
# SIGKILL left `zfs send` in D state until the pipe's reader went away
# (#12500).  Elsewhere the write happens in the sending thread, which a
# signal always interrupted; the test checks the same thing there.
#
# Strategy:
# 1. Write a file much larger than a pipe's buffer and snapshot it.
# 2. Open a FIFO with a reader that never reads, and start
#    `zfs send` into it.
# 3. Wait until the send is blocked on the full pipe.
# 4. SIGKILL the send; it must exit within 10 seconds.
# 5. With the reader still there, destroy the snapshot: nothing of the
#    send may still hold it.
#

verify_runnable "both"

# Running, and not a zombie waiting to be reaped.
function running # pid
{
	typeset stat=$(ps -o stat= -p $1)
	[[ -n "$stat" && "$stat" != Z* ]]
}

function cleanup
{
	[[ -n "$send_pid" ]] && kill -9 $send_pid 2>/dev/null
	[[ -n "$reader_pid" ]] && kill -9 $reader_pid 2>/dev/null
	wait
	rm -f $fifo
	destroy_dataset $POOL/killfs "-rR"
}

log_assert "A zfs send blocked on a full pipe can be killed"
log_onexit cleanup

fifo=$BACKDIR/send_killable.fifo
send_pid=""
reader_pid=""

log_must zfs create $POOL/killfs
log_must dd if=/dev/urandom of=/$POOL/killfs/file bs=1M count=32 \
    status=none
log_must zfs snapshot $POOL/killfs@snap

log_must mkfifo $fifo
# The reader opens the FIFO and never reads from it.
sleep 600 < $fifo &
reader_pid=$!
zfs send $POOL/killfs@snap > $fifo &
send_pid=$!

# 32 MiB can't fit in the pipe, so the send blocks within moments.
sleep 3
if ! running $send_pid; then
	log_fail "zfs send exited before it blocked"
fi
typeset taskq="no"
if is_linux && ls /proc/spl/kstat/taskq 2>/dev/null | grep -q "^z_send\."; then
	taskq="yes"
fi
log_note "z_send taskq in use: $taskq; send state: $(ps -o stat=,wchan= -p $send_pid)"

log_must kill -9 $send_pid
typeset -i i=0
while running $send_pid && (( i < 10 )); do
	sleep 1
	(( i += 1 ))
done
if running $send_pid; then
	log_fail "zfs send still running 10 s after SIGKILL:" \
	    "$(ps -o stat=,wchan= -p $send_pid)"
fi
wait $send_pid
send_pid=""
log_note "zfs send exited ${i} s after SIGKILL"

# The reader is still there, so a write left running would still be
# blocked and still hold the snapshot.
log_must zfs destroy $POOL/killfs@snap

log_pass "A zfs send blocked on a full pipe can be killed"
