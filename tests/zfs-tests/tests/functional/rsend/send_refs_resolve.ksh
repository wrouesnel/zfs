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
# Verify that "zfs send --refs --refs-resolve=pct" stops searching the
# incremental source once pct percent of the data that uses the blocks to
# reference is found, sends the rest in full, and logs the search.
#
# Strategy:
# 1. Create a dedup=on filesystem with a file of random data, f1, and a
#    small file, s; and a file in another dedup=on filesystem.  Snapshot
#    @a and replicate it.
# 2. For @b, copy all of f1 to f2, record 0 of f1 to each record of f3,
#    the other filesystem's file to f4, and s to 32 small files.  That is
#    68 uses of 21 blocks to reference, of 4864 KiB, of which the 4 blocks
#    used by f4 are not in @a.
# 3. Invalid --refs-resolve values, and --refs-resolve without --refs,
#    are rejected.
# 4. Without --refs-resolve, all of @a is searched: 64 of the 68 uses,
#    4352 KiB, are sent as references, and the search is logged.
# 5. With --refs-resolve=50 the search stops at the third block of f1,
#    with 19 of the 68 uses found, but half of the data.  Counting uses
#    instead, it would not stop before s is found.
# 6. Both streams are received, and the received snapshots are identical
#    to the sent ones.
#

verify_runnable "both"

sendfs=$POOL/refs_resolve
otherfs=$POOL/refs_resolve_other
recvfs=$POOL2/refs_resolve_all
recvfs2=$POOL2/refs_resolve_half
all=$BACKDIR/refs_resolve_all
half=$BACKDIR/refs_resolve_half
typeset -i nrec=16
typeset -i nsmall=32
typeset -i small=8192

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $otherfs && destroy_dataset $otherfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	datasetexists $recvfs2 && destroy_dataset $recvfs2 -r
	[[ -n "$saved_dbgmsg" ]] && set_tunable32 DBGMSG_ENABLE $saved_dbgmsg
	rm -f $all $half $BACKDIR/refs_resolve_full
}

#
# Print the lines of the debug log after line $1 that mention $2.
#
function dbgmsg_after
{
	kstat dbgmsg | awk -v n=$1 'NR > n' | grep -F -- "$2"
}

function dbgmsg_count
{
	kstat dbgmsg | wc -l
}

log_assert "zfs send --refs-resolve stops the search of the incremental" \
	"source once enough references are found"
log_onexit cleanup

saved_dbgmsg=$(get_tunable DBGMSG_ENABLE)
log_must set_tunable32 DBGMSG_ENABLE 1

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $otherfs
othermnt=$(get_prop mountpoint $otherfs)
refs_mkfile $othermnt/o 4

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must eval "dd if=/dev/urandom of=$mntpnt/s bs=$small count=1 2>/dev/null"
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/refs_resolve_full"
log_must eval "zfs recv -u $recvfs <$BACKDIR/refs_resolve_full"
log_must eval "zfs recv -u $recvfs2 <$BACKDIR/refs_resolve_full"

refs_copy $mntpnt/f1 $mntpnt/f2
typeset -i i
for ((i = 0; i < nrec; i++)); do
	refs_copy $mntpnt/f1 $mntpnt/f3 0 1 $i
done
refs_copy $othermnt/o $mntpnt/f4
for ((i = 0; i < nsmall; i++)); do
	log_must eval "dd if=$mntpnt/s of=$mntpnt/s$i bs=$small 2>/dev/null"
done
log_must zfs snapshot $sendfs@b
typeset -i nuses=$((2 * nrec + 4 + nsmall))
typeset -i nfound=$((2 * nrec + nsmall))
typeset -i bytes=$(((2 * nrec + 4) * REFS_RECSIZE + nsmall * small))
typeset -i found_bytes=$((2 * nrec * REFS_RECSIZE + nsmall * small))

# Invalid percentages, and --refs-resolve without --refs.
for pct in 0 101 -1 abc 50x ""; do
	log_mustnot eval "zfs send --refs --refs-resolve=$pct -i @a" \
	    "$sendfs@b >/dev/null"
done
log_mustnot eval "zfs send --refs-resolve=50 -i @a $sendfs@b >/dev/null"
log_mustnot eval "zfs send --delta --refs-resolve=50 -i @a $sendfs@b" \
	">/dev/null"

# The whole of @a is searched, as the blocks f4 uses are not in it.
typeset -i uses=$(send_refs_stat send_refs_uses)
typeset -i found=$(send_refs_stat send_refs_uses_resolved)
typeset -i ubytes=$(send_refs_stat send_refs_use_bytes)
typeset -i fbytes=$(send_refs_stat send_refs_use_bytes_resolved)
typeset -i stopped=$(send_refs_stat send_refs_resolve_stopped)
typeset -i line=$(dbgmsg_count)
log_must eval "zfs send --refs -i @a $sendfs@b >$all"
log_must test "$(stream_byref_records $all)" -eq $nfound
log_must test $(send_refs_stat send_refs_uses) -eq $((uses + nuses))
log_must test $(send_refs_stat send_refs_uses_resolved) -eq $((found + nfound))
log_must test $(send_refs_stat send_refs_use_bytes) -eq $((ubytes + bytes))
log_must test $(send_refs_stat send_refs_use_bytes_resolved) -eq \
	$((fbytes + found_bytes))
log_must test $(send_refs_stat send_refs_resolve_stopped) -eq $stopped

log_note "$(dbgmsg_after $line "send $sendfs@b:")"
log_must eval "dbgmsg_after $line '$sendfs@b: refs scan done' |" \
	"grep -q ' bytes'"
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: searching'" \
	"| grep -q 'for 21 blocks with $nuses uses of $bytes bytes, until 100%'"
for mark in 25.0 50.0 75.0; do
	log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: found" \
	    "$mark%' | grep -q 'of the fromsnap ('"
done
log_mustnot eval "dbgmsg_after $line '$sendfs@b: refs resolve: found 90.0%'" \
	"| grep -q ."
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: walk complete," \
	"found 89.4%' | grep -q '($found_bytes/$bytes bytes), 94.1% of uses" \
	"($nfound/$nuses)'"

# Record 0 of f1 is 17 of the 36 uses of full records, 44.7% of the data,
# so the search can stop at 50% once records 1 and 2 are found too.
line=$(dbgmsg_count)
log_must eval "zfs send --refs --refs-resolve=50 -i @a $sendfs@b >$half"
log_must test "$(stream_byref_records $half)" -eq 19
log_must test $(send_refs_stat send_refs_resolve_stopped) -eq $((stopped + 1))
log_note "$(dbgmsg_after $line "send $sendfs@b:")"
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: searching'" \
	"| grep -q 'until 50%'"
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: stopped at" \
	"target, found 50.0%' | grep -q '27.9% of uses (19/$nuses)'"

typeset -i all_size=$(stat_size $all)
typeset -i half_size=$(stat_size $half)
log_note "stream size: $all_size searching all, $half_size stopping at 50%"
log_must test $half_size -gt $all_size

log_must eval "zfs recv -u $recvfs <$all"
refs_cmp_snaps $sendfs $recvfs a b
log_must eval "zfs recv -u $recvfs2 <$half"
refs_cmp_snaps $sendfs $recvfs2 a b

log_must test -n "$(send_refs_stat send_refs_src_ahead)"

log_pass "zfs send --refs-resolve stops the search of the incremental" \
	"source once enough references are found"
