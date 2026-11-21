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
#	1. Create a pool on six disks and write files of 1M blocks.  Export
#	   it and pick the middle one of the file blocks past the scratch
#	   area of the expansion.
#	2. Import it, hold the reflow in the middle of that block with
#	   zinject -n raidz_expand:reflow -o and attach a seventh disk.  Check that the
#	   reflow is held at exactly that offset, and that the offset in the
#	   uberblock is still the same after an export.
#	3. Zero the data area of the first disk while the pool is exported.
#	4. Import the pool, clear the handler and let the expansion finish
#	   without reading the files.  Export it and check that the damage in
#	   the block is where described above, one damaged sector per row.
#	5. Import the pool and scrub it.  Verify that it found no data errors
#	   and that every file, including the one with that block, is intact.
#

typeset -r devs=6
typeset -r dev_size_mb=256
# A directory of our own, so that zdb -e and zpool import only see this pool.
typeset -r devdir=$TEST_BASE_DIR/raidz_expand_straddle
typeset -r nfiles=32
typeset -r file_mb=8
# Full rows of the block required on either side of the offset.
typeset -r margin_rows=3
# The expansion copies the first 3.5M of each child of the expanded vdev
# through its scratch area, in one step: no block in there can straddle.
typeset -r scratch_sectors=$((3584 / 4 * (devs + 1)))

scrub_after_expand=$(get_tunable SCRUB_AFTER_EXPAND)

function cleanup
{
	zinject -c all
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	log_must rm -rf "$devdir"

	log_must set_tunable32 SCRUB_AFTER_EXPAND $scrub_after_expand
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
verify_inject_points

log_onexit cleanup

log_must set_tunable32 SCRUB_AFTER_EXPAND 0

for nparity in 2 1; do
	log_note "raidz$nparity"
	log_must mkdir -p $devdir
	typeset -a disks=()
	for i in {0..$(($devs - 1))}; do
		log_must truncate -s ${dev_size_mb}M $devdir/dev-$i
		disks[${#disks[*]}+1]=$devdir/dev-$i
	done
	log_must truncate -s ${dev_size_mb}M $devdir/dev-$devs

	log_must zpool create -f -o cachefile=none -o ashift=12 $TESTPOOL \
	    raidz$nparity ${disks[@]}
	log_must zfs create -o recordsize=1M -o compression=off \
	    -o primarycache=metadata $TESTPOOL/fs
	typeset -A digest=() name=()
	for i in {1..$nfiles}; do
		f=/$TESTPOOL/fs/file$i
		log_must dd if=/dev/urandom of=$f bs=1M count=$file_mb \
		    status=none
		digest[$f]=$(xxh128digest $f)
		name[$(ls -i $f | awk '{print $1}')]=$f
	done
	log_must zpool export $TESTPOOL

	#
	# Of the file blocks past the scratch area with enough rows (devs
	# sectors each) for the margin on both sides, take the middle one by
	# offset.  Hold the reflow in the middle of it, half way through a
	# row: rows before the offset are copied before the damage, the row
	# cut by it is still read from its old location, rows after it are
	# copied after the damage.
	#
	blocks=$(dataset_blocks)
	log_note "$(echo "$blocks" | awk 'NF == 3 { n++
	    if (min == "" || $2 < min) min = $2
	    if ($2 + $3 > max) max = $2 + $3 } END {
	    printf "%d blocks in sectors [%s, %s)", n, min, max }')"
	candidates=$(echo "$blocks" | while read obj s0 asz; do
		[[ -n ${name[$obj]} ]] || continue
		(( s0 >= scratch_sectors )) || continue
		(( asz / devs >= 2 * margin_rows + 1 )) || continue
		echo $s0 $asz $obj
	done | sort -n)
	n=$(echo "$candidates" | grep -c .)
	(( n > 0 )) || log_fail "raidz$nparity: no file block to straddle"
	read bstart bsize obj <<< \
	    "$(echo "$candidates" | sed -n "$((n / 2 + 1))p")"
	file=${name[$obj]}
	e=$((bstart + bsize / devs / 2 * devs + devs / 2))
	log_note "raidz$nparity: holding the reflow at sector $e, in the" \
	    "block of $file at sectors [$bstart, $((bstart + bsize))):" \
	    "$(((e - bstart) / devs)) rows before it"

	log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
	id=$(zinject -q -n raidz_expand:reflow -o $((e * 4096)) -A pause \
	    $TESTPOOL)
	[[ $id == +([0-9]) ]] || log_fail "zinject -n raidz_expand:reflow: '$id'"
	log_must zpool attach $TESTPOOL raidz$nparity-0 $devdir/dev-$devs
	wait_inject_point $id 1 120 || \
	    log_fail "raidz$nparity: the reflow was not held"
	log_must zpool sync $TESTPOOL
	log_must eval "zinject"
	held=$(inject_point_field $id AT)
	log_note "raidz$nparity: reflow offset requested $((e * 4096))," \
	    "held at ${held:-none}"
	[[ $held == $((e * 4096)) ]] || \
	    log_fail "raidz$nparity: the reflow is held at '$held', not at" \
	    "$((e * 4096))"

	#
	# The handler stays in place while the pool is exported, and the
	# export moves the reflow no further.
	#
	log_must zpool export $TESTPOOL
	offset=$(reflow_offset)
	log_note "raidz$nparity: reflow offset in the exported pool $offset"
	[[ $offset == $((e * 4096)) ]] || \
	    log_fail "raidz$nparity: the exported pool's reflow offset is" \
	    "'$offset', not $((e * 4096))"

	#
	# Zero disk 0 between the front and the back labels.  The rows
	# before the offset are in the new layout (devs + 1 wide), the rest
	# in the old one.
	#
	log_must dd conv=notrunc if=/dev/zero of=$devdir/dev-0 bs=1M seek=4 \
	    count=$((dev_size_mb - 5)) status=none
	log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
	log_must zinject -c $id
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
