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
# When a device of the pool being imported is smaller than the minimum
# device size (for example a disk that isn't fully there yet at boot),
# the kernel fails the import with EOVERFLOW.  'zpool import' must
# report that as an error, not abort with "internal error: Value too
# large for defined data type" (openzfs/zfs#18388).
#
# STRATEGY:
# 1. Create a pool on a file vdev with a cache file, save the cache file
#    and export the pool.
# 2. Shrink the file below SPA_MINDEVSIZE.
# 3. 'zpool import -c CACHEFILE' must fail with exit status 1 and say
#    that a device is too small.
#

verify_runnable "global"

typeset dir=$TEST_BASE_DIR/import_device_too_small
typeset pool=too_small

function cleanup
{
	poolexists $pool && destroy_pool $pool
	rm -rf $dir
}

log_onexit cleanup

log_assert "zpool import reports a device below the minimum size"

log_must mkdir -p $dir
log_must truncate -s $MINVDEVSIZE $dir/vdev
log_must zpool create -o cachefile=$dir/pool.cache $pool $dir/vdev
log_must cp $dir/pool.cache $dir/saved.cache
log_must zpool export $pool
log_must truncate -s $(($SPA_MINDEVSIZE / 2)) $dir/vdev

for args in "-N $pool" "-aN"; do
	out=$(zpool import -c $dir/saved.cache $args 2>&1)
	rc=$?
	log_note "zpool import -c saved.cache $args: rc=$rc: $out"
	(( rc == 1 )) || \
	    log_fail "zpool import $args exited $rc instead of 1: $out"
	[[ "$out" == *"internal error"* ]] && \
	    log_fail "zpool import $args reported an internal error: $out"
	[[ "$out" == *"smaller than the minimum"* ]] || \
	    log_fail "zpool import $args doesn't say the device is too small"
	poolexists $pool && log_fail "$pool was imported"
done

log_pass "zpool import reports a device below the minimum size"
