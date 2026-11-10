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
# 6. Repeat with blocks written just after the attach txg, still in the
#    new device's DTL, as the only unreadable ones: the DTL then keeps
#    only txgs after the attach txg.  Once the old device reads again,
#    "zpool resilver" (whose range starts at the attach txg) copies
#    them, after which the detach succeeds and every file is intact.
#

verify_runnable "global"

DIR=$TEST_BASE_DIR/resilver_unreadable
NFILES=64
NLATE=0
NBAD=8

function cleanup
{
	[[ -n "$writer" ]] && kill $writer >/dev/null 2>&1
	restore_tunable SCAN_SUSPEND_PROGRESS
	zinject -c all >/dev/null 2>&1
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $DIR
}

function setup_pool # vdev
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $DIR
	NLATE=0
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
	for ((i = 0; i < NLATE; i++)); do
		[[ "$(xxh128digest $mnt/late$i 2>/dev/null)" == \
		    "${sums[$((NFILES + 1 + i))]}" ]] || ((bad++))
	done
	(( bad == 0 )) || log_fail "$bad of $((NFILES + NLATE)) files lost"
}

#
# Attach $DIR/b with the scan suspended while files are written, and
# make the data of the files born in the txgs after the attach txg that
# the new device's DTL still covers ([TXG_INITIAL, txg + 3)) unreadable.
# Writes to $DIR/a are delayed during the attach so that those txgs
# hold some of the files.  Returns 1 if none of them does.
#
function attach_late_unreadable
{
	typeset mnt=$(get_prop mountpoint $TESTPOOL1)
	typeset -i n=0 nlate=0 rtxg birth

	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	log_must zinject -d $DIR/a -D 25:1 $TESTPOOL1
	(
		typeset -i i=0
		while [[ ! -f $DIR/stop ]]; do
			dd if=/dev/urandom of=$mnt/late$i bs=128k count=1 \
			    status=none
			((i++))
		done
	) &
	writer=$!
	# The attach waits for txg + 3 to sync while the writer runs.
	log_must zpool attach $TESTPOOL1 $DIR/a $DIR/b
	log_must touch $DIR/stop
	wait $writer
	writer=""
	log_must zinject -c all
	log_must zpool sync $TESTPOOL1

	while [[ -f $mnt/late$NLATE ]]; do
		sums[$((NFILES + 1 + NLATE))]=$(xxh128digest $mnt/late$NLATE)
		((NLATE++))
	done
	rtxg=$(zdb -l $DIR/b | awk '$1 == "resilver_txg:" { print $2; exit }')
	(( rtxg > 0 )) || log_fail "no resilver_txg in the label of $DIR/b"
	# The files were written in order, so their births don't decrease.
	for ((n = 0; n < NLATE; n++)); do
		birth=$(zdb -dddddd $TESTPOOL1/ $(ls -i $mnt/late$n |
		    awk '{ print $1 }') | awk '$2 == "L0" {
			for (i = 1; i <= NF; i++)
				if (sub(/^B=[0-9]*\//, "", $i))
					print $i
		}')
		(( birth > 0 )) || log_fail "no birth txg for $mnt/late$n"
		(( birth >= rtxg + 3 )) && break
		if (( birth > rtxg )); then
			log_must zinject -t data -e io -f 100 $mnt/late$n
			((nlate++))
		fi
	done
	log_note "attach txg $rtxg, $NLATE files written, $nlate unreadable"
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	(( nlate > 0 ))
}

log_assert "A resilver that can't read some blocks keeps the old device"
log_onexit cleanup
set -A sums
writer=""
save_tunable SCAN_SUSPEND_PROGRESS

for op in attach replace late; do
	if [[ $op == late ]]; then
		for try in 1 2 3 4 5; do
			setup_pool
			attach_late_unreadable && break
			log_must zinject -c all
			(( try < 5 )) ||
			    log_unsupported "no file born after the attach txg"
		done
	else
		setup_pool
		# Only file data, so that pool metadata reads stay unaffected.
		mnt=$(get_prop mountpoint $TESTPOOL1)
		for i in $(seq $NBAD); do
			log_must zinject -t data -e io -f 100 $mnt/f$i
		done
		log_must zpool $op $TESTPOOL1 $DIR/a $DIR/b
	fi
	log_must zpool wait -t resilver $TESTPOOL1
	log_must zinject -c all
	zpool status -v $TESTPOOL1

	errors=$(resilver_errors)
	(( errors > 0 )) || log_unsupported "no unreadable block in the resilver"
	log_note "$op: resilver had $errors errors"

	if [[ $op != replace ]]; then
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

	# Once the old device reads again, a scrub completes the copy; so
	# does a resilver, whose range starts at the DTL's first txg.
	log_must zpool clear $TESTPOOL1
	if [[ $op == late ]]; then
		log_must zpool resilver $TESTPOOL1
		# The resilver starts when the next txg syncs.
		log_must zpool sync $TESTPOOL1
		log_must zpool wait -t resilver $TESTPOOL1
		zpool status -v $TESTPOOL1
	else
		log_must zpool scrub -w $TESTPOOL1
	fi
	if [[ $op != replace ]]; then
		log_must zpool detach $TESTPOOL1 $DIR/a
	else
		log_must zpool wait -t replace $TESTPOOL1
	fi
	zpool status $TESTPOOL1 | grep -q "$DIR/a " &&
	    log_fail "$DIR/a still in the pool after the scrub"
	verify_files
done

log_pass "A resilver that can't read some blocks keeps the old device"
