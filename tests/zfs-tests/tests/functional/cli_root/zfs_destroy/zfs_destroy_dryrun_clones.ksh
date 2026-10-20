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
# 'zfs destroy -Rnv <snapshot>' lists the same datasets that
# 'zfs destroy -Rv <snapshot>' destroys, including the dependent clones,
# and destroys nothing.
#
# STRATEGY:
# 1. Create a filesystem with a snapshot, a clone of it in another
#    filesystem, and a snapshot of the clone.
# 2. Run 'zfs destroy -Rnv' and 'zfs destroy -Rnpv' on the snapshot and
#    check that both list the clone and its snapshot, and that nothing
#    was destroyed.
# 3. Run 'zfs destroy -Rv' and check that it destroyed the datasets the
#    dry run listed.
#

verify_runnable "both"

fs=$TESTPOOL/$TESTFS/src
other=$TESTPOOL/$TESTFS/other
snap=$fs@snap
clone=$other/clone
csnap=$clone@csnap

function cleanup
{
	datasetexists $other && destroy_dataset $other -R
	datasetexists $fs && destroy_dataset $fs -R
	rm -f $TEST_BASE_DIR/dryrun.out $TEST_BASE_DIR/real.out
}

log_assert "'zfs destroy -Rnv' on a snapshot lists its dependent clones"
log_onexit cleanup

log_must zfs create $fs
log_must zfs create $other
log_must zfs snapshot $snap
log_must zfs clone $snap $clone
log_must zfs snapshot $csnap

log_must eval "zfs destroy -Rnv $snap > $TEST_BASE_DIR/dryrun.out"
log_note "$(cat $TEST_BASE_DIR/dryrun.out)"
for ds in $snap $clone $csnap; do
	log_must grep -qx "would destroy $ds" $TEST_BASE_DIR/dryrun.out
	log_must datasetexists $ds
done

log_must eval "zfs destroy -Rnpv $snap > $TEST_BASE_DIR/dryrun.out"
for ds in $snap $clone $csnap; do
	log_must grep -qx "destroy	$ds" $TEST_BASE_DIR/dryrun.out
	log_must datasetexists $ds
done

log_must eval "zfs destroy -Rnv $snap | sed -n 's/^would destroy //p' | " \
    "sort > $TEST_BASE_DIR/dryrun.out"
log_must eval "zfs destroy -Rv $snap | sed -n 's/^will destroy //p' | " \
    "sort > $TEST_BASE_DIR/real.out"
log_must diff $TEST_BASE_DIR/dryrun.out $TEST_BASE_DIR/real.out
for ds in $snap $clone $csnap; do
	log_mustnot datasetexists $ds
done

log_pass "'zfs destroy -Rnv' on a snapshot lists its dependent clones"
