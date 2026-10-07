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
. $STF_SUITE/include/kstat.shlib

# Description:
# Verify that "zfs send -v --refs --delta" reports its progress while it
# prepares the stream, and logs how long each preparation phase took.
# Strategy:
# 1. Create a filesystem with dedup=on and primarycache=metadata and a
#    large file, snapshot @a, then write a new file that partly copies the
#    first (dedup hits, so there are references to locate) and snapshot @b.
# 2. Before each send, export and import the pool so nothing is cached,
#    and delay every read of its disk, so that building the similarity
#    index takes many seconds.
# 3. With -vP, the progress lines while the index is built have the
#    delta_index phase, with progress that grows and stays within its
#    nonzero total.  With -v, they say so in words.
# 4. zfs_dbgmsg has a line for each preparation phase of each send.

verify_runnable "both"

sendfs=$POOL/refs_send
out=$BACKDIR/progress
err=$BACKDIR/progress.err
typeset -i nrec=384

function cleanup
{
	zinject -c all >/dev/null 2>&1
	[[ -n "$saved_agg" ]] && set_tunable32 VDEV_AGGREGATION_LIMIT $saved_agg
	[[ -n "$saved_agg_nr" ]] && \
	    set_tunable32 VDEV_AGGREGATION_LIMIT_NONROT $saved_agg_nr
	datasetexists $sendfs && destroy_dataset $sendfs -r
	rm -f $out $err $err.index
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

log_assert "zfs send -v --refs --delta reports progress while preparing"
log_onexit cleanup

saved_agg=$(get_tunable VDEV_AGGREGATION_LIMIT)
saved_agg_nr=$(get_tunable VDEV_AGGREGATION_LIMIT_NONROT)
log_must set_tunable32 VDEV_AGGREGATION_LIMIT 0
log_must set_tunable32 VDEV_AGGREGATION_LIMIT_NONROT 0

log_must zfs create -o recordsize=$REFS_RECSIZE -o primarycache=metadata \
    -o dedup=on $sendfs
mntpnt=$(get_prop mountpoint $sendfs)
refs_mkfile $mntpnt/f1 $nrec
log_must zfs snapshot $sendfs@a
refs_mkfile $mntpnt/g 8
refs_copy $mntpnt/f1 $mntpnt/g 0 4 0
log_must zfs snapshot $sendfs@b

# Parsable: time, bytes, blocks, name, then phase, progress and total.
slow_cold_pool
log_must eval "zfs send -vvP --refs --delta -i @a $sendfs@b >$out 2>$err"
awk -F'\t' '$5 == "delta_index"' $err >$err.index
log_note "delta_index progress lines:\n$(cat $err.index)"
log_must test $(wc -l <$err.index) -ge 3
# Nothing sent yet; progress grows, within a known total.
log_must awk -F'\t' '
    $2 != 0 || $7 == 0 || $6 > $7 || $6 < prev { bad = 1 } { prev = $6 }
    END { exit (bad || prev == 0) }' $err.index
log_must stream_has_features $out write_delta

# Readable.
slow_cold_pool
log_must eval "zfs send -v --refs --delta -i @a $sendfs@b >$out 2>$err"
log_must grep -q "$sendfs@b (building similarity index: .* read, [0-9]*%)" $err

# Each preparation phase is logged for both sends.
for phase in "refs scan" "refs resolve" "delta index"; do
	log_must test $(kstat dbgmsg | \
	    grep -c "send $sendfs@b: $phase done after") -ge 2
done

log_must zinject -c all
log_pass "zfs send -v --refs --delta reports progress while preparing"
