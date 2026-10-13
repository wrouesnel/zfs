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

. $STF_SUITE/tests/functional/rsend/rsend.kshlib

#
# Description:
# Verify that the search of the incremental source by "zfs send --refs",
# shared among zfs_send_refs_resolve_threads threads walking ranges of
# objects, finds the same blocks as one thread does.
#
# Strategy:
# 1. Create a dedup=on filesystem with many one-record files and many
#    empty files in between, so that the search is split into many ranges
#    of objects, and a file in another dedup=on filesystem; snapshot @a
#    and replicate it.
# 2. For @b, copy each one-record file, and the other filesystem's file,
#    whose blocks are not in @a.
# 3. Waiting for the search (zfs_send_refs_wait), with 1 and with 8
#    threads: every block that @a has is found and sent as a reference,
#    and the search is logged with its number of threads.  The threads
#    walk only their own ranges: together they visit about as many block
#    pointers as one thread does.
# 4. Searching while streaming, with 8 threads: each use is sent as a
#    reference or counted in send_refs_missed.
# 5. With --refs-resolve=50 and 8 threads, the search stops at the target.
# 6. Every stream is received, and the received snapshots are identical
#    to the sent ones.
#

verify_runnable "both"

sendfs=$POOL/refs_parallel
otherfs=$POOL/refs_parallel_other
stream=$BACKDIR/refs_parallel
typeset -i nfiles=200

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $otherfs && destroy_dataset $otherfs -r
	typeset fs
	for fs in one eight bg half; do
		datasetexists $POOL2/refs_parallel_$fs && \
		    destroy_dataset $POOL2/refs_parallel_$fs -r
	done
	[[ -n "$saved_threads" ]] && \
	    set_tunable32 SEND_REFS_RESOLVE_THREADS $saved_threads
	# The rsend setup waits for the search, for repeatable streams.
	set_tunable32 SEND_REFS_WAIT 1
	[[ -n "$saved_dbgmsg" ]] && set_tunable32 DBGMSG_ENABLE $saved_dbgmsg
	rm -f $stream $BACKDIR/refs_parallel_full
}

function dbgmsg_after
{
	kstat dbgmsg | awk -v n=$1 'NR > n' | grep -F -- "$2"
}

function dbgmsg_count
{
	kstat dbgmsg | wc -l
}

#
# Send @a..@b with --refs and options $2..., receive it into
# $POOL2/refs_parallel_$1, and check the received snapshots.
#
function send_recv
{
	typeset name=$1
	shift
	log_must eval "zfs send --refs $* -i @a $sendfs@b >$stream"
	log_must eval "zfs recv -u $POOL2/refs_parallel_$name <$stream"
	refs_cmp_snaps $sendfs $POOL2/refs_parallel_$name a b
}

log_assert "zfs send --refs searches the incremental source with several" \
	"threads"
log_onexit cleanup

saved_dbgmsg=$(get_tunable DBGMSG_ENABLE)
log_must set_tunable32 DBGMSG_ENABLE 1
saved_threads=$(get_tunable SEND_REFS_RESOLVE_THREADS)

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $otherfs
othermnt=$(get_prop mountpoint $otherfs)
refs_mkfile $othermnt/o 4

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
log_must mkdir $mntpnt/d $mntpnt/empty
typeset -i i
for ((i = 0; i < nfiles; i++)); do
	refs_mkfile $mntpnt/d/f$i 1
	log_must mkfiles $mntpnt/empty/e${i}_ 100
done
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/refs_parallel_full"
for fs in one eight bg half; do
	log_must eval "zfs recv -u $POOL2/refs_parallel_$fs" \
	    "<$BACKDIR/refs_parallel_full"
done

log_must mkdir $mntpnt/c
for ((i = 0; i < nfiles; i++)); do
	refs_copy $mntpnt/d/f$i $mntpnt/c/f$i
done
refs_copy $othermnt/o $mntpnt/c/o
log_must zfs snapshot $sendfs@b
typeset -i nuses=$((nfiles + 4))

# Waiting for the search: one thread, then eight, find the same blocks.
log_must set_tunable32 SEND_REFS_WAIT 1
typeset -i visited_1=0 visited_8=0
for threads in 1 8; do
	log_must set_tunable32 SEND_REFS_RESOLVE_THREADS $threads
	typeset -i line=$(dbgmsg_count)
	[[ $threads == 1 ]] && name=one || name=eight
	send_recv $name
	log_must test "$(stream_byref_records $stream)" -eq $nfiles
	log_note "$(dbgmsg_after $line "send $sendfs@b: refs resolve")"
	log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: searching" \
	    "the fromsnap for $nuses blocks with $nuses uses' |" \
	    "grep -q 'with $threads threads'"
	log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: walk" \
	    "complete,'"
	typeset -i visited=$(dbgmsg_after $line \
	    "$sendfs@b: refs resolve done after" | \
	    sed -E 's/.* ms \(([0-9]+)\/.*/\1/' | tail -1)
	log_note "$threads threads visited $visited block pointers"
	if [[ $threads == 1 ]]; then
		visited_1=$visited
	else
		visited_8=$visited
	fi
done
log_must test $visited_1 -gt 0
log_must test $visited_8 -lt $((visited_1 * 2))

# Searching while streaming, with eight threads.
log_must set_tunable32 SEND_REFS_WAIT 0
typeset -i missed=$(send_refs_stat send_refs_missed)
send_recv bg
typeset -i byref=$(stream_byref_records $stream)
typeset -i nmissed=$(($(send_refs_stat send_refs_missed) - missed))
log_note "$byref uses sent as references, $nmissed in full"
log_must test $((byref + nmissed)) -eq $nuses

# The target stops the search with eight threads too.
log_must set_tunable32 SEND_REFS_WAIT 1
typeset -i stopped=$(send_refs_stat send_refs_resolve_stopped)
line=$(dbgmsg_count)
send_recv half --refs-resolve=50
log_must test $(send_refs_stat send_refs_resolve_stopped) -eq $((stopped + 1))
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: stopped at" \
	"target'"
log_must test "$(stream_byref_records $stream)" -ge $((nfiles / 2))

log_pass "zfs send --refs searches the incremental source with several" \
	"threads"
