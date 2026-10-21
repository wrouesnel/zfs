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
# 'zpool trim POOL' and 'zpool initialize POOL' (no vdevs given) work when
# ZPOOL_VDEV_NAME_FOLLOW_LINKS is set and the pool's vdev path is a
# symbolic link.
#
# STRATEGY:
# 1. Create a pool on a file vdev given by a symbolic link to the file.
# 2. With ZPOOL_VDEV_NAME_FOLLOW_LINKS=1, 'zpool initialize -w POOL' and
#    'zpool trim -w POOL' must succeed without "no such device in pool".
# 3. Verify that the vdev was initialized and trimmed.
#

verify_runnable "global"

function cleanup
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -f $LINKFILE $REALFILE $TEST_BASE_DIR/follow_links.out
}
log_onexit cleanup

log_assert "zpool trim/initialize of a whole pool work with" \
    "ZPOOL_VDEV_NAME_FOLLOW_LINKS"

REALFILE=$TEST_BASE_DIR/trim_follow_links_real
LINKFILE=$TEST_BASE_DIR/trim_follow_links_link
OUT=$TEST_BASE_DIR/follow_links.out

log_must truncate -s $MINVDEVSIZE $REALFILE
log_must ln -s $REALFILE $LINKFILE
log_must zpool create -f $TESTPOOL1 $LINKFILE
log_must zpool status -v $TESTPOOL1

for cmd in initialize trim; do
	ZPOOL_VDEV_NAME_FOLLOW_LINKS=1 zpool $cmd -w $TESTPOOL1 > $OUT 2>&1
	rc=$?
	log_note "ZPOOL_VDEV_NAME_FOLLOW_LINKS=1 zpool $cmd -w: rc=$rc" \
	    "$(cat $OUT)"
	log_must zpool status -v $TESTPOOL1
	if grep -q "no such device in pool" $OUT; then
		log_fail "zpool $cmd looked up the resolved link: $(cat $OUT)"
	fi
	(( rc == 0 )) || log_fail "zpool $cmd failed (rc=$rc): $(cat $OUT)"
done

log_must eval "zpool status -i $TESTPOOL1 | grep -q '100% initialized'"
log_must eval "zpool status -t $TESTPOOL1 | grep -q '100% trimmed'"

log_pass "zpool trim/initialize of a whole pool work with" \
    "ZPOOL_VDEV_NAME_FOLLOW_LINKS"
