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
# 'zdb -C' without a pool dumps the cache file, says so plainly when the
# cache file is empty, and names the file when it can't be decoded.
#
# STRATEGY:
# 1. Point the pool's cachefile at a test file and check that
#    'zdb -C -U FILE' prints the pool's configuration.
# 2. Check that an empty cache file (as left when no pool uses it) is
#    reported as empty, with exit status 0.
# 3. Check that a corrupt cache file fails with a message naming it,
#    not just "failed to unpack nvlist".
#

verify_runnable "global"

CACHE=$TEST_BASE_DIR/zdb_cachefile.cache

function cleanup
{
	default_cleanup_noexit
	rm -f $CACHE
}

log_onexit cleanup
log_assert "zdb -C reports empty and corrupt cache files clearly"

log_must default_setup_noexit "$DISKS"
log_must zpool set cachefile=$CACHE $TESTPOOL
out=$(zdb -C -U $CACHE)
(( $? == 0 )) || log_fail "zdb -C -U $CACHE failed"
echo "$out" | grep -q "name: '$TESTPOOL'" || \
    log_fail "zdb -C -U $CACHE didn't print $TESTPOOL: $out"

log_must zpool set cachefile=none $TESTPOOL
log_must eval "true > $CACHE"
out=$(zdb -C -U $CACHE 2>&1)
rc=$?
log_note "empty cache file: rc=$rc: $out"
(( rc == 0 )) || log_fail "zdb -C on an empty cache file exited $rc"
echo "$out" | grep -q "$CACHE.*empty" || \
    log_fail "zdb -C didn't say $CACHE is empty: $out"

log_must eval "printf 'not an nvlist' > $CACHE"
out=$(zdb -C -U $CACHE 2>&1)
rc=$?
log_note "corrupt cache file: rc=$rc: $out"
(( rc != 0 )) || log_fail "zdb -C on a corrupt cache file exited 0"
echo "$out" | grep -q "$CACHE" || \
    log_fail "zdb -C didn't name the corrupt cache file: $out"

log_pass "zdb -C reports empty and corrupt cache files clearly"
