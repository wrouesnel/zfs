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
#	During a raidz expansion that adds several disks at once, a block
#	that straddles the reflow offset has rows at their new location and
#	rows still at their old one, which is as many disks wide as the vdev
#	was before the expansion, not one disk narrower than it is now.
#	Damage from a single failed disk must remain repairable in such a
#	block, also when the reflow has copied some of the damage to the new
#	location.
#
# STRATEGY:
#	For each of two old disks:
#	1. Create a 3-wide raidz1 pool with large metaslabs, so that the
#	   file is written in one piece, write a file of 1M blocks and attach
#	   three new disks in one expansion (3 -> 6 wide) with the reflow
#	   paused early on.
#	2. Export the pool and zero the part of the old disk that holds the
#	   data the reflow has not copied yet.
#	3. Import the pool and let the reflow copy some more of the data, in
#	   chunks that are not a multiple of the block size so that it can
#	   stop inside a block.  It copies the damage along, spread over all
#	   disks.
#	4. Verify that a block of the file straddles the new reflow offset,
#	   with at least three rows on either side, its first part copied
#	   from the damaged area and its column on the zeroed disk holding
#	   data (if none does, let the reflow copy a little more and look
#	   again, until one does or the reflow is done).  Every row of that
#	   block has one damaged sector, on the zeroed disk in the rows at the
#	   old location and wherever the reflow put it in the others.
#	5. Scrub with the reflow paused.  Verify that it found no data
#	   errors, repaired something and that the file is intact.
#	6. Let the expansion finish, scrub again and verify that it repairs
#	   nothing.
#

verify_runnable "global"

typeset -r old_width=3
typeset -r added=3
typeset -r dev_size_mb=512
# Rows of the straddling block required on either side of the offset.
typeset -r minrows=3
# A directory of our own, so that zdb -e and zpool import only see this pool.
typeset -r devdir=$TEST_BASE_DIR/raidz_expand_multi_boundary_repair

prefetch_disable=$(get_tunable PREFETCH_DISABLE)
scrub_after_expand=$(get_tunable SCRUB_AFTER_EXPAND)
max_copy_bytes=$(get_tunable RAIDZ_EXPAND_MAX_COPY_BYTES)
min_ms_count=$(get_tunable VDEV_MIN_MS_COUNT)
txg_timeout=$(get_tunable TXG_TIMEOUT)

function cleanup
{
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	log_must rm -rf "$devdir"

	log_must set_tunable32 PREFETCH_DISABLE $prefetch_disable
	log_must set_tunable32 SCRUB_AFTER_EXPAND $scrub_after_expand
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must set_tunable64 RAIDZ_EXPAND_MAX_COPY_BYTES $max_copy_bytes
	log_must set_tunable32 VDEV_MIN_MS_COUNT $min_ms_count
	log_must set_tunable32 TXG_TIMEOUT $txg_timeout
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
# Print the offset and allocated size of each level 0 block of the file in
# the exported pool, in decimal.
#
function file_blocks # object
{
	zdb -e -p $devdir -ddddd $TESTPOOL/fs $1 | \
	    awk '$2 == "L0" { print $3 }' | while IFS=: read _ off asize; do
		echo $((16#$off)) $((16#$asize))
	done
}

#
# Damage old disk $1 before an expansion by several disks, scrub with a
# block straddling the reflow offset and verify the damage is repaired.
#
function test_bad_disk # bad
{
	typeset -i bad=$1
	typeset -a disks newdisks

	log_note "Damaging old disk $bad of $old_width"
	log_must mkdir -p $devdir
	for i in {0..$((old_width + added - 1))}; do
		log_must truncate -s ${dev_size_mb}M $devdir/dev-$i
		if (( i < old_width )); then
			disks[${#disks[*]}+1]=$devdir/dev-$i
		else
			newdisks[${#newdisks[*]}+1]=$devdir/dev-$i
		fi
	done

	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must set_tunable64 RAIDZ_EXPAND_MAX_COPY_BYTES $max_copy_bytes
	log_must set_tunable32 TXG_TIMEOUT $txg_timeout
	log_must zpool create -f -o cachefile=none -o ashift=12 $TESTPOOL \
	    raidz1 ${disks[@]}
	log_must zfs create -o recordsize=1M -o compression=off \
	    -o primarycache=metadata $TESTPOOL/fs
	log_must dd if=/dev/urandom of=/$TESTPOOL/fs/file bs=1M count=300
	typeset digest=$(xxh128digest /$TESTPOOL/fs/file)
	typeset object=$(ls -i /$TESTPOOL/fs/file | awk '{print $1}')

	log_must zpool sync $TESTPOOL
	typeset allocated=$(get_pool_prop allocated $TESTPOOL)
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES $((allocated / 80))
	log_must zpool attach $TESTPOOL raidz1-0 ${newdisks[@]}
	wait_raidz_expand_paused $TESTPOOL
	log_must eval "zpool status $TESTPOOL | \
	    grep -q 'expansion of .* in progress'"
	log_must zpool export $TESTPOOL

	#
	# Rows past the reflow offset are still at their old location, row r
	# on each old disk at byte offset 4M (the labels and boot area) +
	# r * 4k, $old_width disks wide.  Zero the bad disk from the first
	# such row on.  The copied part of the pool is in the rows before
	# that (they are wider) and stays intact.
	#
	typeset offset1=$(reflow_offset)
	log_note "reflow offset $offset1 after the first pause"
	(( offset1 > 0 )) || log_fail "no reflow offset in the uberblock"
	typeset row=$((offset1 / 4096 / old_width))
	log_must dd conv=notrunc if=/dev/zero of=$devdir/dev-$bad bs=4k \
	    seek=$((1024 + row)) count=$((dev_size_mb * 256 - 1024 - row - 256))

	log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
	log_must set_tunable64 RAIDZ_EXPAND_MAX_COPY_BYTES $((1024 * 1024 + 4096))

	#
	# Look for a block that straddles the offset, with at least $minrows
	# rows on either side.  The block was written $old_width wide, so a
	# row of it is $old_width sectors of the vdev's address space, on
	# every old disk at the old location.  Each column of the block is on
	# the same old disk in every row; the column on the bad disk must not
	# be the parity (raidz1 swaps the first two columns in every other
	# MiB), or the scrub finds the data intact and only rewrites the
	# parity.  If no block qualifies, let the reflow copy a little more
	# and look again.
	#
	# The amount copied only advances when a txg syncs, so the reflow
	# pauses at the first txg boundary after the pause point.  With the
	# default txg timeout it copies up to the most it may per txg (twice
	# the previous offset, when 3 disks are added to 3), and stops in the
	# file's data only once or twice.  Short txgs make it stop every few
	# MiB.
	#
	# In the rows at the old location, the damaged column is on
	# consecutive sectors of the bad disk, so with three or more of them
	# at least two are not a multiple of the old width.  For those,
	# numbering the old rows by the current width minus one rather than
	# by the old width would point a simulated failure of the bad disk
	# at another column.
	#
	typeset -i straddling=0
	typeset rowsize=$((old_width * 4096))
	typeset offset2
	log_must set_tunable32 TXG_TIMEOUT 1
	while (( straddling == 0 )); do
		log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES \
		    $(($(reflowed $TESTPOOL) + 1))
		wait_raidz_expand_paused $TESTPOOL
		log_must zpool export $TESTPOOL

		offset2=$(reflow_offset)
		log_note "reflow offset $offset2 after the second pause"
		if (( offset2 == 0 )); then
			log_must zpool import -o cachefile=none -d $devdir \
			    $TESTPOOL
			break
		fi
		file_blocks $object | while read off asize; do
			if (( off >= offset1 &&
			    off + minrows * rowsize <= offset2 &&
			    offset2 + minrows * rowsize <= off + asize &&
			    (off / 4096 + ((off >> 20) & 1)) % old_width !=
			    bad )); then
				log_note "block at $off (asize $asize)" \
				    "straddles it"
				(( straddling += 1 ))
			fi
		done
		log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
	done
	log_must set_tunable32 TXG_TIMEOUT $txg_timeout
	(( straddling > 0 )) || \
	    log_unsupported "no block of the file straddles the reflow offset"

	typeset before=$(reflowed $TESTPOOL)
	log_must zpool scrub -w $TESTPOOL
	log_note "reflowed $before before the scrub," \
	    "$(reflowed $TESTPOOL) after it"
	log_must eval "zpool status -v $TESTPOOL"
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must eval "zpool status $TESTPOOL | \
	    grep -q 'expansion of .* in progress'"
	log_mustnot check_pool_status $TESTPOOL "scan" "repaired 0B"
	[[ $(xxh128digest /$TESTPOOL/fs/file) == $digest ]] || \
	    log_fail "the file changed"
	log_must zpool clear $TESTPOOL

	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must zpool wait -t raidz_expand $TESTPOOL
	log_must zpool scrub -w $TESTPOOL
	log_must eval "zpool status -v $TESTPOOL"
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must check_pool_status $TESTPOOL "scan" "repaired 0B"
	[[ $(xxh128digest /$TESTPOOL/fs/file) == $digest ]] || \
	    log_fail "the file changed"

	log_must zpool destroy $TESTPOOL
	log_must rm -rf $devdir
}

log_onexit cleanup

log_must set_tunable32 PREFETCH_DISABLE 1
log_must set_tunable32 SCRUB_AFTER_EXPAND 0
#
# With the default 16 metaslabs, the file ends up in several pieces with
# free space between them, and the reflow moves through free space in big
# steps.  With 2 metaslabs the file is in one piece in the first metaslab.
#
log_must set_tunable32 VDEV_MIN_MS_COUNT 2

for bad in 0 2; do
	test_bad_disk $bad
done

log_pass "Damage in a block across the reflow offset of a raidz" \
    "expansion by several disks is repairable."
