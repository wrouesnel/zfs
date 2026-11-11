#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
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
# CDDL HEADER END
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/removal/removal.kshlib

#
# DESCRIPTION:
#	A scrub repairs a split block of a removed vdev from the old device
#	of a spare (or replacing) vdev when the other copies are damaged.
#
# STRATEGY:
#	1. Create a pool on a mirror with a hot spare, write a file, add a
#	   second mirror and remove the first one with a small
#	   zfs_remove_max_segment, so that the file's blocks are split
#	   into several segments on the second mirror.
#	2. Replace one side of the second mirror with the spare, which
#	   puts a "spare" vdev with the old device and the spare under
#	   the mirror, and wait for the resilver.
#	3. Damage every segment of the file's first block on the spare and
#	   on the other side of the mirror, so that the old device holds
#	   the only good copy.
#	4. Scrub.  Verify that the scrub repaired the block with no data
#	   errors, that the checksum errors are charged to the two damaged
#	   devices and not to the old device, and that the file is intact
#	   after an export and import.
#	5. Scrub again and verify that nothing is left to repair.
#

verify_runnable "global"

DISKDIR=$(mktemp -d)
A0=$DISKDIR/a0
A1=$DISKDIR/a1
B0=$DISKDIR/b0
B1=$DISKDIR/b1
SPARE=$DISKDIR/spare

typeset max_segment=$(get_tunable REMOVE_MAX_SEGMENT)

function cleanup
{
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	log_must set_tunable32 REMOVE_MAX_SEGMENT $max_segment
	log_must rm -f $A0 $A1 $B0 $B1 $SPARE
	log_must rmdir $DISKDIR
}
log_onexit cleanup

#
# Print the checksum error count of a vdev, from "zpool status -p".
#
function cksum_errors # pool vdev
{
	zpool status -p $1 | awk -v vd="$2" '$1 == vd { print $5; exit }'
}

log_assert "A scrub repairs a split block from the old device of a spare."

log_must truncate -s $MINVDEVSIZE $A0 $A1 $B0 $B1 $SPARE

log_must zpool create -f -o ashift=9 -O compression=off -O recordsize=128k \
    $TESTPOOL mirror $A0 $A1 spare $SPARE
log_must dd if=/dev/urandom of=/$TESTPOOL/file bs=128k count=4
sync_pool $TESTPOOL
typeset sum=$(xxh128digest /$TESTPOOL/file)

#
# Copy the data to the second mirror in 32K segments, so that each 128K
# block of the file is mapped to several segments.
#
log_must zpool add -f $TESTPOOL mirror $B0 $B1
log_must set_tunable32 REMOVE_MAX_SEGMENT 32768
log_must zpool remove $TESTPOOL mirror-0
log_must wait_for_removal $TESTPOOL
sync_pool $TESTPOOL

#
# Find the first block of the file on the removed vdev (vdev 0), and the
# segments of the second mirror (vdev 1) it is mapped to.
#
typeset obj=$(get_objnum /$TESTPOOL/file)
typeset dva=$(zdb -ddddd $TESTPOOL/ $obj | \
    awk '$2 == "L0" && $3 ~ /^0:/ { print $3; exit }')
[[ -n "$dva" ]] || log_fail "no block of the file on vdev 0"
typeset blk_off=$((16#$(echo $dva | cut -d: -f2)))
typeset blk_size=$((16#$(echo $dva | cut -d: -f3)))
log_note "block $dva"

typeset segs=""
zdb -mmmm $TESTPOOL | grep -E '<0:[0-9a-f]+:[0-9a-f]+> -> <1:' | \
    sed 's/[<>]//g' | while read src arrow dst rest; do
	typeset so=$((16#$(echo $src | cut -d: -f2)))
	typeset sz=$((16#$(echo $src | cut -d: -f3)))
	typeset to=$((16#$(echo $dst | cut -d: -f2)))
	typeset lo=$(( so > blk_off ? so : blk_off ))
	typeset hi=$(( so + sz < blk_off + blk_size ? so + sz : \
	    blk_off + blk_size ))
	(( lo < hi )) && segs="$segs $((to + lo - so)):$((hi - lo))"
done
typeset nsegs=$(echo $segs | wc -w)
log_note "block mapped to $nsegs segments: $(echo $segs)"
(( nsegs > 1 )) || log_fail "block $dva is not split ($nsegs segments)"

log_must zpool replace $TESTPOOL $B0 $SPARE
log_must zpool wait -t resilver $TESTPOOL
log_must check_vdev_state $TESTPOOL $SPARE "ONLINE"

#
# Damage every segment of the block on the spare and on the other side
# of the mirror.  Both get zeros, so each segment has two distinct
# copies: the good one on $B0, and the damaged one.
#
typeset label_size=$((4 * 1024 * 1024))
for seg in $segs; do
	typeset dst=${seg%%:*}
	typeset len=${seg##*:}
	for dev in $B1 $SPARE; do
		log_must dd if=/dev/zero of=$dev bs=512 conv=notrunc \
		    seek=$(((label_size + dst) / 512)) count=$((len / 512))
	done
done

log_must zpool scrub -w $TESTPOOL
log_must eval "zpool status -v $TESTPOOL > $TEST_BASE_DIR/status.out"
cat $TEST_BASE_DIR/status.out

log_mustnot grep -q "Permanent errors" $TEST_BASE_DIR/status.out
log_must grep -q "No known data errors" $TEST_BASE_DIR/status.out
log_must grep -q "scrub repaired .* with 0 errors" $TEST_BASE_DIR/status.out

typeset b0_err=$(cksum_errors $TESTPOOL $B0)
typeset b1_err=$(cksum_errors $TESTPOOL $B1)
typeset spare_err=$(cksum_errors $TESTPOOL $SPARE)
log_note "checksum errors: $B0 $b0_err, $B1 $b1_err, $SPARE $spare_err"
log_must test "$b0_err" -eq 0
log_must test "$b1_err" -gt 0
log_must test "$spare_err" -gt 0

log_must zpool export $TESTPOOL
log_must zpool import -d $DISKDIR $TESTPOOL
log_must test "$(xxh128digest /$TESTPOOL/file)" = "$sum"

log_must zpool clear $TESTPOOL
log_must zpool scrub -w $TESTPOOL
log_must eval "zpool status -v $TESTPOOL > $TEST_BASE_DIR/status.out"
cat $TEST_BASE_DIR/status.out
log_must grep -q "scrub repaired 0B .* with 0 errors" $TEST_BASE_DIR/status.out
for dev in $B0 $B1 $SPARE; do
	log_must test "$(cksum_errors $TESTPOOL $dev)" -eq 0
done

log_pass "A scrub repairs a split block from the old device of a spare."
