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
. $STF_SUITE/tests/functional/cli_root/zpool_scrub/zpool_scrub.cfg

#
# DESCRIPTION:
#	A scrub that is set up while a vdev needs resilvering heals that
#	vdev: it only scans the vdev's DTL range and posts a "healing"
#	resilver_start event.  It must finish with a matching "healing"
#	resilver_finish event, and must not be recorded as the last full
#	scrub (last_scrubbed_txg), since it didn't read data born before
#	the DTL range.
#
# STRATEGY:
#	1. Create a pool of two mirrors and write a file (f0).
#	2. Offline a child of the first mirror and write another file (f1),
#	   so that the child needs resilvering.
#	3. Hold a sequential rebuild on the second mirror, and online the
#	   child: its resilver request is dropped while a rebuild is active.
#	4. Release the rebuild.  The scrub that follows it
#	   (zfs_rebuild_scrub_enabled) does the healing.
#	5. Verify that the healing resilver_start has a healing
#	   resilver_finish, and that last_scrubbed_txg is still unset.
#	6. Inject read errors on f0 and run "zpool scrub -C": it must read
#	   f0 and report it, since no full scrub has been done.
#

verify_runnable "global"

VDEVS="$TEST_BASE_DIR/heal_a $TEST_BASE_DIR/heal_b $TEST_BASE_DIR/heal_c"
VDEVS="$VDEVS $TEST_BASE_DIR/heal_d $TEST_BASE_DIR/heal_e"
set -A V $VDEVS
POOL=$TESTPOOL2
MNT=$TEST_BASE_DIR/heal_mnt

function cleanup
{
	log_must zinject -c all
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
	log_must set_tunable32 REBUILD_SCRUB_ENABLED 1
	destroy_pool $POOL
	log_must rm -rf $VDEVS $MNT
}

# Print "start finish" counts of the pool's healing resilver events.
function healing_events
{
	zpool events -v $POOL | awk '
	    /class = "sysevent.fs.zfs.resilver_(start|finish)"/ { c = $3 }
	    /resilver_type = "healing"/ && c ~ /start/ { s++ }
	    /resilver_type = "healing"/ && c ~ /finish/ { f++ }
	    /^$/ { c = "" }
	    END { print s + 0, f + 0 }'
}

log_onexit cleanup

log_assert "A healing scrub posts resilver_finish and isn't a full scrub"

log_must set_tunable32 REBUILD_SCRUB_ENABLED 1
log_must truncate -s $MINVDEVSIZE $VDEVS
log_must zpool create -f -O compression=off -m $MNT $POOL \
    mirror ${V[0]} ${V[1]} mirror ${V[2]} ${V[3]}
log_must dd if=/dev/urandom of=$MNT/f0 bs=1M count=32
sync_pool $POOL

log_must zpool offline $POOL ${V[0]}
log_must dd if=/dev/urandom of=$MNT/f1 bs=1M count=16
sync_pool $POOL
log_must zpool events -c

log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
log_must zpool replace -s $POOL ${V[3]} ${V[4]}
log_must zpool online $POOL ${V[0]}
log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0
log_must zpool wait -t resilver,scrub $POOL

# The rebuild's own events say "sequential"; check that a healing scan
# happened at all, so the test can't pass vacuously.
read hstart hfinish <<<"$(healing_events)"
log_note "healing resilver events: $hstart start, $hfinish finish"
(( hstart >= 1 )) || log_fail "no healing scan happened"
(( hfinish == hstart )) || \
    log_fail "$hstart healing resilver_start but $hfinish resilver_finish"

lasttxg=$(zpool get -Hpo value last_scrubbed_txg $POOL)
[[ "$lasttxg" == "0" ]] || \
    log_fail "the healing scan set last_scrubbed_txg to $lasttxg"

log_must zinject -a -t data -e io -T read $MNT/f0
log_must zpool clear $POOL
log_must zpool scrub -w -C $POOL
log_must eval "zpool status -v $POOL | grep -q $MNT/f0"
log_must zinject -c all

log_pass "A healing scrub posts resilver_finish and isn't a full scrub"
