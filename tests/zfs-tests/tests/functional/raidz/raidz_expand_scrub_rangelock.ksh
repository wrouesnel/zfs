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

#
# DESCRIPTION:
#	A scrub repair of a block must not be lost when the raidz expansion
#	reflow copies the rest of that block while the repair is outstanding.
#	The rangelock that a read takes during an expansion has to cover the
#	whole allocation of the block (parity and padding included), not just
#	its data size, or a copy chunk that starts in the block's tail does
#	not wait for the repair: it moves the damaged rows to their new
#	location and the repair goes to the old one.
#
# STRATEGY:
#	1. Create a raidz3 pool, fill it, and pick one 100K block past the
#	   part the expansion copies through its scratch area.  Its allocation
#	   is about twice its data size.
#	2. Stop the reflow inside that block's tail, past its data size
#	   (raidz_expand_repair_race_offset), and export the pool.
#	3. Zero the not yet copied part of three disks.  Rows copied before
#	   the damage stay intact, so no block has both copied and uncopied
#	   damaged rows (which combinatorial reconstruction cannot model).
#	4. Import and scrub.  The hook holds the scrub read of the chosen
#	   block, once it has its map and rangelock, and lets the reflow copy
#	   the rest of the block first.  The scrub must find no data errors.
#	5. Let the expansion finish, then zero three disks again (the next
#	   fault).  A lost repair leaves the block with more damaged columns
#	   than parity, so this scrub must still find no data errors, and a
#	   final scrub must have nothing left to repair.
#

verify_runnable "global"

typeset -r devs=6
typeset -r dev_size_mb=128
typeset -r nparity=3
typeset -r label_size=$((4 * 1024 * 1024))

typeset -a disks

prefetch_disable=$(get_tunable PREFETCH_DISABLE)
scrub_after_expand=$(get_tunable SCRUB_AFTER_EXPAND)

function cleanup
{
	log_must set_tunable64 RAIDZ_EXPAND_REPAIR_RACE_OFFSET 0
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	for i in {0..$devs}; do
		log_must rm -f "$TEST_BASE_DIR/dev-$i"
	done
	log_must rm -f "$TEST_BASE_DIR/l0.list"

	log_must set_tunable32 PREFETCH_DISABLE $prefetch_disable
	log_must set_tunable32 SCRUB_AFTER_EXPAND $scrub_after_expand
}

# Zero disk dev-N from byte offset START to the end of the disk.
function zero_from # disk start
{
	typeset disk=$1
	typeset -i start=$2
	typeset -i mb=$(( (start + 1048575) / 1048576 ))

	if (( start < mb * 1048576 )); then
		log_must dd conv=notrunc if=/dev/zero of=$disk bs=512 \
		    seek=$((start / 512)) count=$(( (mb * 1048576 - start) / 512 ))
	fi
	log_must dd conv=notrunc if=/dev/zero of=$disk bs=1M seek=$mb \
	    count=$((dev_size_mb - mb))
}

# The reflow offset recorded in the exported pool's uberblock.
function reflow_offset
{
	zdb -e -p $TEST_BASE_DIR -u $TESTPOOL | \
	    awk '/raidz_reflow/ { sub("off=", "", $3); print $3 }'
}

log_onexit cleanup

log_must set_tunable32 PREFETCH_DISABLE 1
log_must set_tunable32 SCRUB_AFTER_EXPAND 0

for i in {0..$(($devs - 1))}; do
	device=$TEST_BASE_DIR/dev-$i
	log_must truncate -s ${dev_size_mb}M $device
	disks[${#disks[*]}+1]=$device
done
log_must truncate -s 512M $TEST_BASE_DIR/dev-$devs

log_must zpool create -f -o ashift=9 $TESTPOOL raidz$nparity ${disks[@]}
log_must zfs set primarycache=metadata $TESTPOOL
log_must zfs create -o compression=off -o recordsize=128k $TESTPOOL/fs
log_must fill_fs /$TESTPOOL/fs 1 256 102400 1 R
log_must zpool sync $TESTPOOL

#
# Pick a 100K block past the part of the vdev that the expansion copies
# through its scratch area first (raidz_reflow_scratch_sync(), which the
# hook does not stop: the boot area size times the new width, 24.5M here),
# and find its allocation (DVA offset and asize) and its data size (psize).
#
typeset -r min_off=$((32 * 1024 * 1024))
typeset -i off=0 asize=0 psize=102400
typeset file=''
zdb -ddddd $TESTPOOL/fs | awk '
    $1 == "path" { path = $2 }
    $2 == "L0" && $4 == "19000L/19000P" {
	split($3, dva, ":")
	print dva[2], dva[3], path
    }' > $TEST_BASE_DIR/l0.list
while read hoff hasize path; do
	typeset -i o=$((16#$hoff))
	if (( o >= min_off && (off == 0 || o < off) )); then
		off=$o
		asize=$((16#$hasize))
		file=/$TESTPOOL/fs$path
	fi
done < $TEST_BASE_DIR/l0.list
log_must rm -f $TEST_BASE_DIR/l0.list
(( off != 0 )) || log_unsupported "no 100K block past $min_off"
log_note "$file: L0 at $off, asize $asize, psize $psize"
(( asize > psize + 2 * 512 )) || log_fail "asize $asize leaves no tail"

# Stop the reflow halfway through the block's tail (parity and padding).
typeset -i race=$(( (off + (psize + asize) / 2) / 512 * 512 ))
log_note "stopping the reflow at $race, $((race - off)) bytes into the block"
log_must set_tunable64 RAIDZ_EXPAND_REPAIR_RACE_OFFSET $race

#
# Wait for the reflow to report that it stopped at the race offset, then
# export and check the offset recorded in the uberblock.
#
typeset stopmsg="raidz_expand_repair_race_offset: reflow stopped at $race"
function stopped_count
{
	kstat dbgmsg | grep -c "$stopmsg"
}
typeset -i seen=$(stopped_count)

log_must zpool attach $TESTPOOL raidz$nparity-0 $TEST_BASE_DIR/dev-$devs
typeset -i t0=$SECONDS
while (( $(stopped_count) <= seen )); do
	if (( SECONDS - t0 > 300 )); then
		zpool status -v $TESTPOOL
		kstat dbgmsg | grep -E "reflow|raidz_expand" | tail -20
		log_fail "the reflow did not stop at $race"
	fi
	sleep 1
done
log_must zpool export $TESTPOOL
typeset -i at=$(reflow_offset)
(( at == race )) || log_fail "the reflow is at $at, not $race"
log_note "the reflow stopped at $at"

#
# Damage three disks, but only where the rows not yet copied are: logical
# sector s of the old layout is at sector s / devs of its disk, and the
# copied rows (below the race offset, now devs + 1 wide) all lie below
# that.  Start two sectors early to include the row the offset is in.
#
typeset -i start=$(( label_size + (race / 512 / devs - 2) * 512 ))
for (( i=0; i<$nparity; i=i+1 )); do
	zero_from $TEST_BASE_DIR/dev-$i $start
done

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub -w $TESTPOOL
log_must eval "zpool status -v $TESTPOOL"
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

# The hook must have held the scrub read of our block.
kstat dbgmsg | grep "raidz_expand_repair_race_offset"
kstat dbgmsg | grep -q "raidz_expand_repair_race_offset: released the read of $off-" || \
    log_fail "the scrub read of the block at $off was not held"

log_must set_tunable64 RAIDZ_EXPAND_REPAIR_RACE_OFFSET 0
log_must zpool wait -t raidz_expand $TESTPOOL
log_must zpool clear $TESTPOOL

# The next fault: three disks fail once the expansion is done.
log_must zpool export $TESTPOOL
for (( i=0; i<$nparity; i=i+1 )); do
	zero_from $TEST_BASE_DIR/dev-$i $label_size
done
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub -w $TESTPOOL
log_must eval "zpool status -v $TESTPOOL"
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_must zpool clear $TESTPOOL
log_must zpool scrub -w $TESTPOOL
log_must eval "zpool status -v $TESTPOOL"
log_must check_pool_status $TESTPOOL "errors" "No known data errors"
log_must check_pool_status $TESTPOOL "scan" "repaired 0B"

log_pass "A scrub repair survives the reflow copying the rest of its block."
