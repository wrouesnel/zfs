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
. $STF_SUITE/tests/functional/cli_root/zpool_trim/zpool_trim.kshlib

#
# DESCRIPTION:
#	'zpool trim POOL' trims the leaves that support TRIM and skips the
#	ones that don't without an error, as 'zpool trim -a' does.  Naming
#	a leaf that doesn't support TRIM is still an error.
#
# STRATEGY:
#	1. Create a dRAID pool with a distributed spare on file vdevs and
#	   replace one child with the distributed spare.  A distributed
#	   spare doesn't support TRIM itself.
#	2. 'zpool trim -w POOL' must succeed without an error message.
#	3. The file vdevs must have been trimmed.
#	4. 'zpool trim POOL draid1-0-0' must fail as not supported.
#

verify_runnable "global"

function cleanup
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $TESTDIR
}
log_onexit cleanup

log_assert "'zpool trim POOL' skips leaves that don't support TRIM"

log_must mkdir -p $TESTDIR
log_must truncate -s $MINVDEVSIZE $TESTDIR/vdev{0..4}

log_must zpool create -f $TESTPOOL1 draid1:2d:5c:1s $TESTDIR/vdev{0..4}
log_must zpool replace -w $TESTPOOL1 $TESTDIR/vdev1 draid1-0-0
log_must eval "zpool status $TESTPOOL1 | grep -q 'draid1-0-0.*ONLINE'"

out=$(zpool trim -w $TESTPOOL1 2>&1)
rc=$?
log_note "zpool trim -w $TESTPOOL1: rc=$rc: $out"
if (( rc != 0 )) || [[ -n "$out" ]]; then
	log_fail "zpool trim $TESTPOOL1 failed on the distributed spare" \
	    "(rc=$rc): $out"
fi

for n in 0 2 3 4; do
	state=$(trim_progress $TESTPOOL1 $TESTDIR/vdev$n)
	[[ "$state" == "100" ]] || \
	    log_fail "$TESTDIR/vdev$n wasn't trimmed: '$state'"
done

out=$(zpool trim $TESTPOOL1 draid1-0-0 2>&1)
rc=$?
log_note "zpool trim $TESTPOOL1 draid1-0-0: rc=$rc: $out"
(( rc != 0 )) || log_fail "trim of the distributed spare didn't fail"
[[ "$out" == *"not supported"* ]] || \
    log_fail "unexpected error for the distributed spare: $out"

log_pass "'zpool trim POOL' skips leaves that don't support TRIM"
