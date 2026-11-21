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
#	A disk that goes silently bad while a raidz expansion is paused
#	inside a block must not cost that block once the reflow has moved
#	on.  The rows of the block that were copied before the disk went
#	bad have the damage on that disk in the new layout, so the damaged
#	column moves from row to row.  The rows copied after it carry the
#	damage the reflow read from that disk in the old layout, so it stays
#	in one column.  Every row has one damaged sector, which raidz1 can
#	repair, but no single failed child, current or pre-expansion,
#	explains all of them.
#
# STRATEGY:
#	For raidz2 (the control: two simulated failures cover both kinds of
#	damage) and then raidz1:
#	1. Create a pool on six disks with large metaslabs, write files of
#	   1M blocks back to back and attach a seventh disk with the reflow
#	   paused early on.
#	2. Let the reflow copy one more txg at a time, exporting the pool
#	   after each step, until the reflow offset in the uberblock lies
#	   inside a block of a file with at least three full rows of the
#	   block on either side.  Early in an expansion every txg copies up
#	   to a point about a sixth past the previous offset, so a step lands
#	   in a block most of the time and the loop takes a few steps.  If
#	   the expansion finishes first, start over with a new pool (up to
#	   three times).
#	3. Zero the data area of the first disk while the pool is still
#	   exported.
#	4. Import the pool and let the expansion finish without reading the
#	   files.  Export it and check that the damage in the straddling
#	   block is where described above, one damaged sector per row.
#	5. Import the pool and scrub it.  Verify that it found no data errors
#	   and that every file, including the one with the straddling block,
#	   is intact.
#

typeset -r devs=6
typeset -r dev_size_mb=256
# A directory of our own, so that zdb -e and zpool import only see this pool.
typeset -r devdir=$TEST_BASE_DIR/raidz_expand_straddle
typeset -r nfiles=32
typeset -r file_mb=8
# Full rows of the straddling block required on either side of the offset.
typeset -r margin_rows=3
# Pools to try per parity before giving up on finding a straddling block.
typeset -r attempts=3

prefetch_disable=$(get_tunable PREFETCH_DISABLE)
scrub_after_expand=$(get_tunable SCRUB_AFTER_EXPAND)
min_ms_count=$(get_tunable VDEV_MIN_MS_COUNT)

function cleanup
{
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	log_must rm -rf "$devdir"

	log_must set_tunable32 PREFETCH_DISABLE $prefetch_disable
	log_must set_tunable32 SCRUB_AFTER_EXPAND $scrub_after_expand
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must set_tunable32 VDEV_MIN_MS_COUNT $min_ms_count
}

function reflowed # pool
{
	zpool status -jp $1 | jq -r '.pools[].raidz_expand_stats.reflowed'
}

#
# The reflow offset (in the raidz vdev's address space) of the exported pool.
#
function reflow_offset
{
	zdb -e -p $devdir -u $TESTPOOL | \
	    awk '/raidz_reflow/ { sub("off=", "", $3); print $3 }'
}

#
# Print "object offset asize" (decimal, offset and asize in sectors) for
# each level 0 block of the dataset in the exported pool, leaving out
# embedded blocks (no DVA).
#
function dataset_blocks
{
	zdb -e -p $devdir -ddddd $TESTPOOL/fs | awk '
	    prev ~ /^ *Object +lvl/ { obj = $1 }
	    $2 == "L0" && $3 ~ /^[0-9]+:[0-9a-f]+:[0-9a-f]+$/ {
		print obj, $3
	    }
	    { prev = $0 }' | while IFS=": " read obj _ off asize; do
		echo $obj $((16#$off / 4096)) $((16#$asize / 4096))
	done
}

#
# Is the 4k sector at byte offset $2 of disk $1 all zeros?
#
function sector_zero # disk offset
{
	dd if=$1 bs=4k skip=$(($2 / 4096)) count=1 status=none | \
	    cmp -s -n 4096 - /dev/zero
}

verify_runnable "global"

log_onexit cleanup

log_must set_tunable32 PREFETCH_DISABLE 1
log_must set_tunable32 SCRUB_AFTER_EXPAND 0
# One metaslab holds all the files, in one piece (see
# raidz_expand_boundary_repair).
log_must set_tunable32 VDEV_MIN_MS_COUNT 2

#
# Pool, files and paused expansion for one attempt at a straddle.
#
function create_pool # nparity
{
	typeset -i i
	typeset -a disks=()

	log_must mkdir -p $devdir
	for i in {0..$(($devs - 1))}; do
		log_must truncate -s ${dev_size_mb}M $devdir/dev-$i
		disks[${#disks[*]}+1]=$devdir/dev-$i
	done
	log_must truncate -s ${dev_size_mb}M $devdir/dev-$devs

	log_must zpool create -f -o cachefile=none -o ashift=12 $TESTPOOL \
	    raidz$1 ${disks[@]}
	log_note "metaslab_shift $(zdb -l $devdir/dev-0 | \
	    awk '$1 == "metaslab_shift:" { print $2; exit }')"
	log_must zfs create -o recordsize=1M -o compression=off \
	    -o primarycache=metadata $TESTPOOL/fs
	for i in {1..$nfiles}; do
		f=/$TESTPOOL/fs/file$i
		log_must dd if=/dev/urandom of=$f bs=1M count=$file_mb \
		    status=none
		digest[$f]=$(xxh128digest $f)
		name[$(ls -i $f | awk '{print $1}')]=$f
	done
	log_must zpool sync $TESTPOOL

	allocated=$(get_pool_prop allocated $TESTPOOL)
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES \
	    $((allocated / 80))
	log_must zpool attach $TESTPOOL raidz$1-0 $devdir/dev-$devs
	wait_raidz_expand_paused $TESTPOOL
}

#
# Step the reflow until the offset recorded in the exported pool is inside
# a block, with at least $margin_rows full rows (devs sectors each) of the
# block on either side.  A row cut by the offset is read from its old
# location until the reflow has copied all of it, and doesn't count.  The
# export itself moves the offset: it stops the paused reflow, which copies
# one more txg's worth first.  So the damage has to be done in the same
# export as the look at the offset.  Returns with the pool exported and
# file, bstart, bsize and e set, or 1 if the expansion finished first.
#
function find_straddle
{
	typeset obj s0 asz blocks offset

	file=
	while :; do
		log_must zpool export $TESTPOOL
		offset=$(reflow_offset)
		if [[ -z $offset ]] || (( offset == 0 )); then
			log_note "reflow offset '$offset': the expansion" \
			    "finished before a block straddled it"
			return 1
		fi
		e=$((offset / 4096))
		blocks=$(dataset_blocks)
		log_note "$(echo "$blocks" | awk 'NF == 3 { n++
		    if (min == "" || $2 < min) min = $2
		    if ($2 + $3 > max) max = $2 + $3 } END {
		    printf "%d blocks in sectors [%s, %s)", n, min, max }')"
		inside=
		while read obj s0 asz; do
			(( s0 <= e && e < s0 + asz )) &&
			    inside="(object $obj ${name[$obj]}:"
			(( s0 <= e && e < s0 + asz )) &&
			    inside="$inside [$s0, $((s0 + asz))))"
			(( s0 + asz == e )) &&
			    inside="${inside}(end of object $obj)"
			[[ -n ${name[$obj]} ]] || continue
			(( s0 + margin_rows * devs <= e )) || continue
			(( e + margin_rows * devs <= \
			    s0 + asz / devs * devs )) || continue
			file=${name[$obj]}
			bstart=$s0
			bsize=$asz
			break
		done <<< "$blocks"
		log_note "reflow offset sector $e: ${file:-in no block $inside}"
		[[ -n $file ]] && return 0
		log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
		log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES \
		    $(($(reflowed $TESTPOOL) + 1))
		wait_raidz_expand_paused $TESTPOOL
	done
}

for nparity in 2 1; do
	#
	# Where the files land and where the steps stop varies, and now and
	# then no step stops inside a block.  Start over with a new pool, up
	# to $attempts times.
	#
	typeset -i attempt
	for ((attempt = 1; attempt <= attempts; attempt++)); do
		log_note "raidz$nparity, attempt $attempt"
		unset digest name
		typeset -A digest name
		create_pool $nparity
		find_straddle && break
		log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
		log_must zpool destroy $TESTPOOL
		log_must rm -rf $devdir
	done
	(( attempt <= attempts )) || log_unsupported "raidz$nparity: no" \
	    "block straddled the reflow offset in $attempts attempts"
	log_note "raidz$nparity: block of $file at sectors" \
	    "[$bstart, $((bstart + bsize))) straddles the reflow offset" \
	    "sector $e: $(((e - bstart) / devs)) rows before it" \
	    "(attempt $attempt)"

	#
	# Zero disk 0 between the front and the back labels.  The rows
	# before the offset are in the new layout (devs + 1 wide), the rest
	# in the old one.
	#
	log_must dd conv=notrunc if=/dev/zero of=$devdir/dev-0 bs=1M seek=4 \
	    count=$((dev_size_mb - 5)) status=none
	log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must zpool wait -t raidz_expand $TESTPOOL

	#
	# Sector s of the block is now on disk s % (devs + 1), row
	# s / (devs + 1), after the 4M of labels and boot area.  It was
	# zeroed if it was copied before the damage and is on disk 0 now, or
	# if it was copied after the damage from disk 0 of the old layout
	# (s % devs == 0).  Each full row of the block has at most one such
	# sector, except the row cut by the offset.
	#
	log_must zpool export $TESTPOOL
	typeset -i r s bad=0 before=0 after=0
	for ((r = 0; r < bsize / devs; r++)); do
		typeset -i n=0
		zcols=
		for ((s = bstart + r * devs; s < bstart + (r + 1) * devs;
		    s++)); do
			sector_zero $devdir/dev-$((s % (devs + 1))) \
			    $((4194304 + s / (devs + 1) * 4096)) || continue
			(( n += 1 ))
			zcols="$zcols $((s - bstart - r * devs))"
			if (( s < e && s % (devs + 1) == 0 )); then
				(( before += 1 ))
			elif (( s >= e && s % devs == 0 )); then
				(( after += 1 ))
			else
				(( bad += 1 ))
			fi
		done
		log_note "row $r (sectors $((bstart + r * devs))-" \
		    "$((bstart + r * devs + devs - 1))): zeroed column(s)" \
		    "${zcols:- none}"
		(( n > 1 && (e < bstart + r * devs ||
		    e >= bstart + (r + 1) * devs) )) && (( bad += 1 ))
	done
	log_note "raidz$nparity: $before sectors zeroed on disk 0 in the" \
	    "new layout, $after copied from old disk 0, $bad unexpected"
	(( bad == 0 && before > 0 && after > 0 )) || \
	    log_fail "the damage in the block is not as expected"

	log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
	log_must zpool scrub -w $TESTPOOL
	log_must eval "zpool status -v $TESTPOOL"

	# Every other file must be intact whatever happens to this block.
	for f in ${!digest[@]}; do
		[[ $f == $file ]] && continue
		[[ $(xxh128digest $f) == ${digest[$f]} ]] || \
		    log_fail "raidz$nparity: $f changed as well"
	done
	if ! check_pool_status $TESTPOOL "errors" "No known data errors" ||
	    [[ $(xxh128digest $file 2>/dev/null) != ${digest[$file]} ]]; then
		for ((i = 0; i < file_mb; i++)); do
			dd if=$file of=/dev/null bs=1M skip=$i count=1 \
			    status=none 2>/dev/null || \
			    log_note "$file: block $i (offset ${i}M) unreadable"
		done
		log_note "no single failed child that vdev_raidz_combrec()" \
		    "simulates (raidz_simulate_failure()) matches both kinds"
		log_fail "raidz$nparity: block [$bstart, $((bstart + bsize)))" \
		    "of $file straddled the reflow offset $e (sectors) when" \
		    "dev-0 was zeroed and is lost: rows before the offset" \
		    "have the damage on disk 0, rows after it on old disk 0"
	fi
	log_mustnot check_pool_status $TESTPOOL "scan" "repaired 0B"

	log_must zpool destroy $TESTPOOL
	log_must rm -rf $devdir
done

log_pass "A disk damaged while the reflow is inside a block costs no data."
