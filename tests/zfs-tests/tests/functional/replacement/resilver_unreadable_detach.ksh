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
# A resilver that cannot read some blocks from the only device holding
# them must leave them in the new device's DTL, so that the old device
# can't be detached (and a replace doesn't detach it) until they have
# been copied.
#
# STRATEGY:
# 1. Create a single-device pool and fill it with files.
# 2. Make some files' data unreadable and attach a second device.
# 3. Verify the resilver reports errors and "zpool detach" of the old
#    device fails with "no valid replicas".
# 4. Clear the errors and scrub: the scrub copies the missing blocks
#    from the old device, after which the detach succeeds and every
#    file is intact.
# 5. Repeat with "zpool replace": the old device stays until the scrub,
#    and is then detached by the replace, with every file intact.
#

verify_runnable "global"

DIR=$TEST_BASE_DIR/resilver_unreadable
NFILES=64
NBAD=8

function cleanup
{
	zinject -c all >/dev/null 2>&1
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $DIR
}

function setup_pool # vdev
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $DIR
	log_must mkdir -p $DIR
	log_must truncate -s 512M $DIR/a $DIR/b
	log_must zpool create -f -O compression=off \
	    -O primarycache=metadata $TESTPOOL1 $DIR/a
	typeset mnt=$(get_prop mountpoint $TESTPOOL1)
	for i in $(seq $NFILES); do
		log_must dd if=/dev/urandom of=$mnt/f$i bs=1M count=1 \
		    status=none
		sums[$i]=$(xxh128digest $mnt/f$i)
	done
	log_must zpool export $TESTPOOL1
	log_must zpool import -d $DIR $TESTPOOL1
}

function resilver_errors
{
	zpool status $TESTPOOL1 |
	    sed -n 's/.*resilvered.* with \([0-9]*\) errors.*/\1/p'
}

function verify_files
{
	typeset mnt=$(get_prop mountpoint $TESTPOOL1)
	typeset -i bad=0
	log_must zpool export $TESTPOOL1
	log_must zpool import -d $DIR $TESTPOOL1
	for i in $(seq $NFILES); do
		[[ "$(xxh128digest $mnt/f$i 2>/dev/null)" == "${sums[$i]}" ]] ||
		    ((bad++))
	done
	(( bad == 0 )) || log_fail "$bad of $NFILES files lost"
}

log_assert "A resilver that can't read some blocks keeps the old device"
log_onexit cleanup
set -A sums

for op in attach replace; do
	setup_pool
	# Only file data, so that pool metadata reads stay unaffected.
	mnt=$(get_prop mountpoint $TESTPOOL1)
	for i in $(seq $NBAD); do
		log_must zinject -t data -e io -f 100 $mnt/f$i
	done
	log_must zpool $op $TESTPOOL1 $DIR/a $DIR/b
	log_must zpool wait -t resilver $TESTPOOL1
	log_must zinject -c all
	zpool status -v $TESTPOOL1

	errors=$(resilver_errors)
	(( errors > 0 )) || log_unsupported "no unreadable block in the resilver"
	log_note "$op: resilver had $errors errors"

	if [[ $op == attach ]]; then
		out=$(zpool detach $TESTPOOL1 $DIR/a 2>&1) &&
		    log_fail "detach of the only device holding $errors" \
		    "unreadable blocks succeeded"
		[[ "$out" == *"no valid replicas"* ]] ||
		    log_fail "unexpected detach error: $out"
	else
		zpool status $TESTPOOL1 | grep -q "replacing" ||
		    log_fail "replace detached the only device holding" \
		    "$errors unreadable blocks"
	fi
	zpool status $TESTPOOL1 | grep -q "$DIR/a " ||
	    log_fail "$DIR/a left the pool"

	# Once the old device reads again, a scrub completes the copy.
	log_must zpool clear $TESTPOOL1
	log_must zpool scrub -w $TESTPOOL1
	if [[ $op == attach ]]; then
		log_must zpool detach $TESTPOOL1 $DIR/a
	else
		log_must zpool wait -t replace $TESTPOOL1
	fi
	zpool status $TESTPOOL1 | grep -q "$DIR/a " &&
	    log_fail "$DIR/a still in the pool after the scrub"
	verify_files
done

log_pass "A resilver that can't read some blocks keeps the old device"
