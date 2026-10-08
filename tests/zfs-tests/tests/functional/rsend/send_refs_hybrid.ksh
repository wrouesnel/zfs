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
# Verify that "zfs send --refs" searches the incremental source while the
# stream is sent, unless zfs_send_refs_wait is set; that a resumed send
# only scans the changes from the resume point on; and that the search
# ends with the stream, however the stream ends.
#
# Strategy:
# 1. Create a dedup=on filesystem with a file of random data, f1, and many
#    empty files, and a file in another dedup=on filesystem; snapshot @a
#    and replicate it.
# 2. For @b, in three files in object order, copy all of f1 and the other
#    filesystem's file (20 uses), write unique data, and copy records 0-7
#    of f1 (8 uses).  The other filesystem's blocks are not in @a, so the
#    search of @a never finds them, and walks all of it.
# 3. With zfs_send_refs_wait set, the search covers 20 blocks with 28
#    uses, of which the 24 of f1's blocks are sent as references.
#    Interrupt a receive in the unique data: the resumed send only scans
#    from the resume point, so its search covers the 8 blocks the third
#    file uses.
# 4. By default the search runs while streaming: each use is sent either
#    as a reference or, if its block was not found by the time the stream
#    reached it, in full, which send_refs_missed counts.  The stream is
#    received, and so is a resumed one.
# 5. A send whose reader goes away ends, and the search with it: the
#    incremental source can be destroyed afterwards.
#

verify_runnable "both"

sendfs=$POOL/refs_hybrid
otherfs=$POOL/refs_hybrid_other
recvfs=$POOL2/refs_hybrid_wait
recvfs2=$POOL2/refs_hybrid
recvfs3=$POOL2/refs_hybrid_resume
stream=$BACKDIR/refs_hybrid
resumed=$BACKDIR/refs_hybrid_resumed
typeset -i nrec=16

function cleanup
{
	datasetexists $sendfs && destroy_dataset $sendfs -r
	datasetexists $otherfs && destroy_dataset $otherfs -r
	datasetexists $recvfs && destroy_dataset $recvfs -r
	datasetexists $recvfs2 && destroy_dataset $recvfs2 -r
	datasetexists $recvfs3 && destroy_dataset $recvfs3 -r
	# The rsend setup waits for the search, for repeatable streams.
	set_tunable32 SEND_REFS_WAIT 1
	[[ -n "$saved_dbgmsg" ]] && set_tunable32 DBGMSG_ENABLE $saved_dbgmsg
	rm -f $stream $resumed $BACKDIR/refs_hybrid_full
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

#
# Receive the first half of stream $1 into $2, which fails, and write the
# send that resumes it to $3.
#
function interrupt_and_resume
{
	typeset -i size=$(stat_size $1)

	log_mustnot eval "head -c $((size / 2)) $1 | zfs recv -s -u $2"
	typeset token=$(get_prop receive_resume_token $2)
	log_must test "$token" != "-"
	log_must eval "zfs send -t $token >$3"
}

log_assert "zfs send --refs searches the incremental source while streaming"
log_onexit cleanup

saved_dbgmsg=$(get_tunable DBGMSG_ENABLE)
log_must set_tunable32 DBGMSG_ENABLE 1

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $otherfs
othermnt=$(get_prop mountpoint $otherfs)
refs_mkfile $othermnt/o 4

log_must zfs create -o dedup=on -o recordsize=$REFS_RECSIZE $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must mkdir $mntpnt/many
log_must mkfiles $mntpnt/many/f 20000
log_must zfs snapshot $sendfs@a
log_must eval "zfs send $sendfs@a >$BACKDIR/refs_hybrid_full"
for fs in $recvfs $recvfs2 $recvfs3; do
	log_must eval "zfs recv -u $fs <$BACKDIR/refs_hybrid_full"
done

# Object numbers need not follow the order of creation, so give the files
# their contents in object order.
log_must touch $mntpnt/x $mntpnt/y $mntpnt/z
set -A files $(ls -i $mntpnt/x $mntpnt/y $mntpnt/z | sort -n | awk '{print $2}')
refs_copy $mntpnt/f1 ${files[0]}
refs_copy $othermnt/o ${files[0]} 0 4 $nrec
refs_mkfile ${files[1]} 64
refs_copy $mntpnt/f1 ${files[2]} 0 8
log_must zfs snapshot $sendfs@b
typeset -i nblocks=$((nrec + 4))
typeset -i nuses=$((nrec + 4 + 8))
typeset -i nfound=$((nrec + 8))

# Waiting for the search, all that is found is found before it is needed.
log_must set_tunable32 SEND_REFS_WAIT 1
typeset -i line=$(dbgmsg_count)
log_must eval "zfs send --refs -i @a $sendfs@b >$stream"
log_must test "$(stream_byref_records $stream)" -eq $nfound
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: searching the" \
	"fromsnap for $nblocks blocks with $nuses uses'"
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: walk complete,'"

# The resumed send only scans what was not received yet.
line=$(dbgmsg_count)
interrupt_and_resume $stream $recvfs $resumed
log_note "$(dbgmsg_after $line "send $sendfs@b:")"
log_must eval "dbgmsg_after $line '$sendfs@b: refs scan: resuming at object'"
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: searching the" \
	"fromsnap for 8 blocks with 8 uses'"
log_must test "$(stream_byref_records $resumed)" -eq 8
log_must eval "zfs recv -s -u $recvfs <$resumed"
refs_cmp_snaps $sendfs $recvfs a b

# By default the search runs while streaming.
log_must set_tunable32 SEND_REFS_WAIT 0
typeset -i bg=$(send_refs_stat send_refs_background)
typeset -i missed=$(send_refs_stat send_refs_missed)
line=$(dbgmsg_count)
log_must eval "zfs send --refs -i @a $sendfs@b >$stream"
log_note "$(dbgmsg_after $line "send $sendfs@b:")"
log_must stream_has_features $stream fromsnap_refs
typeset -i byref=$(stream_byref_records $stream)
typeset -i nmissed=$(($(send_refs_stat send_refs_missed) - missed))
log_note "$byref uses sent as references, $nmissed in full"
log_must test $((byref + nmissed)) -eq $nuses
log_must test $(send_refs_stat send_refs_background) -eq $((bg + 1))
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve: searching the" \
	"fromsnap while streaming for $nblocks blocks with $nuses uses'"
# The search has ended by the time the send has.
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve:' | grep -E" \
	"'(stream ended|walk complete), found'"
log_must eval "zfs recv -u $recvfs2 <$stream"
refs_cmp_snaps $sendfs $recvfs2 a b

# Resuming a send, with the search alongside.
interrupt_and_resume $stream $recvfs3 $resumed
log_must eval "zfs recv -s -u $recvfs3 <$resumed"
refs_cmp_snaps $sendfs $recvfs3 a b

# A send whose reader goes away ends, and so does the search.
line=$(dbgmsg_count)
log_must eval "zfs send --refs -i @a $sendfs@b | head -c 4096 >/dev/null"
log_note "$(dbgmsg_after $line "send $sendfs@b:")"
log_must eval "dbgmsg_after $line '$sendfs@b: refs resolve:' | grep -E" \
	"'(stream ended|walk complete), found'"
# Nothing holds the incremental source any more.
log_must zfs destroy -r $sendfs

log_pass "zfs send --refs searches the incremental source while streaming"
