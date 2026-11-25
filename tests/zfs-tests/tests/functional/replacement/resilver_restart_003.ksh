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
. $STF_SUITE/tests/functional/replacement/replacement.cfg

#
# DESCRIPTION:
# A resilver that is restarted because another device was attached while it
# ran must wait for the end of the new device's DTL, as the resilver that
# spa_vdev_attach() schedules does, and must not report checksum errors on
# healthy devices or permanent errors in the pool's metadata.
#
# A new device's DTL ends TXG_CONCURRENT_STATES after the txg of the attach.
# A scan covers only the txgs before the one it is set up in, so a resilver
# set up sooner stops short of the end of the DTL, and another one has to
# follow it.
#
# STRATEGY:
# 1. Create a two-way mirror and write 1024 small files.
# 2. Restart resilvers at once (resilver_disable_defer=1) and slow the
#    reads and writes down so the first resilver is still running.
# 3. Attach a third device, then a fourth while the first resilver runs.
# 4. Check in the pool history that two resilvers were set up, one for each
#    attach, and no third.
# 5. Check that the resilvers found no errors and
#    that no device has checksum errors.
# 6. Repeat a few times.
#

function cleanup
{
	zinject -c all >/dev/null 2>&1
	destroy_pool $TESTPOOL1
	rm -f ${VDEV_FILES[@]} $SPARE_VDEV_FILE $SPARE_VDEV_FILE2
	log_must set_tunable32 RESILVER_DISABLE_DEFER $ORIG_DISABLE_DEFER
}

log_assert "A restarted resilver does not report errors on healthy devices"

ORIG_DISABLE_DEFER=$(get_tunable RESILVER_DISABLE_DEFER)
log_onexit cleanup

# Restart the resilver as soon as another device needs one.
log_must set_tunable32 RESILVER_DISABLE_DEFER 1

for round in 1 2 3; do
	log_must truncate -s 256m ${VDEV_FILES[0]} \
	    ${VDEV_FILES[1]} $SPARE_VDEV_FILE $SPARE_VDEV_FILE2
	log_must zpool create -f $TESTPOOL1 mirror ${VDEV_FILES[0]} \
	    ${VDEV_FILES[1]}
	# Many small blocks, so the slowed resilver takes a while.
	for i in {1..1024}; do
		dd if=/dev/urandom of=/$TESTPOOL1/file$i bs=100k count=1 \
		    2>/dev/null || log_fail "writing file$i failed"
	done
	sync_pool $TESTPOOL1

	log_must zinject -D 20:1 -d ${VDEV_FILES[0]} $TESTPOOL1
	log_must zinject -D 20:1 -d ${VDEV_FILES[1]} $TESTPOOL1

	log_must zpool attach $TESTPOOL1 ${VDEV_FILES[0]} $SPARE_VDEV_FILE
	sleep 3
	is_pool_resilvering $TESTPOOL1 || \
	    log_unsupported "the first resilver finished too soon"
	log_must zpool attach $TESTPOOL1 ${VDEV_FILES[0]} $SPARE_VDEV_FILE2
	log_must zinject -c all
	log_must zpool wait -t resilver $TESTPOOL1
	# A resilver that is needed after that starts in a later txg.
	for i in 1 2 3; do
		sync_pool $TESTPOOL1 true
	done
	log_must zpool wait -t resilver $TESTPOOL1

	log_must eval "zpool status -v $TESTPOOL1"
	history=$(zpool history -i $TESTPOOL1 | grep "scan ")
	log_note "$history"
	if echo "$history" | grep -qE 'scan (cancelled|aborted)'; then
		log_note "round $round: the running resilver was restarted"
	else
		log_note "round $round: the first resilver ended first"
	fi
	# If it was set up before the end of the fourth device's DTL, the
	# second resilver is followed by a third one.
	setups=$(echo "$history" | grep -c "scan setup func=2 ")
	(( setups == 2 )) || \
	    log_fail "round $round: $setups resilvers, expected 2"

	log_must check_pool_status $TESTPOOL1 "scan" "with 0 errors"
	log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
	for vdev in ${VDEV_FILES[0]} ${VDEV_FILES[1]} $SPARE_VDEV_FILE \
	    $SPARE_VDEV_FILE2; do
		cksum=$(zpool status -p $TESTPOOL1 | \
		    awk -v d=$vdev '$1 == d {print $5}')
		[[ "$cksum" == "0" ]] || \
		    log_fail "$vdev has $cksum checksum errors"
	done

	destroy_pool $TESTPOOL1
done

log_pass "A restarted resilver does not report errors on healthy devices"
