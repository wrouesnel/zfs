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

verify_runnable "global"

#
# DESCRIPTION:
#	'zpool attach -s' (sequential reconstruction) to a raidz vdev is
#	refused, because only mirror and dRAID vdevs can be rebuilt
#	sequentially.  The error must say so, and must not claim that the
#	raidz_expansion feature is disabled when it is enabled.
#
# STRATEGY:
#	1. Create a raidz1 pool with every feature enabled
#	2. Verify that 'zpool attach -s' fails, says that only mirror and
#	   dRAID vdevs support sequential reconstruction, doesn't mention the
#	   raidz_expansion feature, and leaves the vdev with 4 disks
#	3. Verify that 'zpool attach' without -s expands the vdev
#	4. Create a raidz1 pool with raidz_expansion disabled and verify that
#	   'zpool attach' and 'zpool attach -s' fail saying the
#	   raidz_expansion feature must be enabled
#	5. Create a raidz1 pool with device_rebuild disabled and verify that
#	   'zpool attach -s' fails saying the device_rebuild feature must be
#	   enabled
#

typeset -r devs=5
typeset -r dev_size_mb=256
typeset -r errfile=$TEST_BASE_DIR/raidz_expand_011.err

typeset -a disks

function cleanup
{
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	for i in {1..$devs}; do
		log_must rm -f "$TEST_BASE_DIR/dev-$i"
	done
	rm -f $errfile
}

#
# attach_fails expected-text [attach args...]
#
function attach_fails
{
	typeset expected=$1
	shift

	log_mustnot eval "zpool attach $* >$errfile 2>&1"
	log_note "zpool attach $*: $(<$errfile)"
	log_must grep -q "$expected" $errfile
}

log_onexit cleanup

for i in {1..$devs}; do
	device=$TEST_BASE_DIR/dev-$i
	log_must truncate -s ${dev_size_mb}M $device
	disks[${#disks[*]}+1]=$device
done

pool=$TESTPOOL
opts="-o cachefile=none"

# Every feature enabled: -s is refused for being a raidz, not for a feature.
log_must zpool create -f $opts $pool raidz1 ${disks[1..$(($devs-1))]}
attach_fails "only mirror and dRAID vdevs support sequential reconstruction" \
    -s $pool raidz1-0 ${disks[$devs]}
log_mustnot grep -q "raidz_expansion" $errfile
attach_fails "only mirror and dRAID vdevs support sequential reconstruction" \
    -sw $pool raidz1-0 ${disks[$devs]}
log_mustnot grep -q "raidz_expansion" $errfile
log_must test "$(zpool list -Hv $pool | grep -c "$TEST_BASE_DIR/dev-")" -eq \
    $(($devs - 1))
log_must zpool attach -w $pool raidz1-0 ${disks[$devs]}
log_must test "$(zpool list -Hv $pool | grep -c "$TEST_BASE_DIR/dev-")" -eq \
    $devs
log_must zpool destroy $pool

# raidz_expansion disabled: that is what both forms report.
log_must zpool create -f $opts -o feature@raidz_expansion=disabled $pool \
    raidz1 ${disks[1..$(($devs-1))]}
attach_fails "raidz_expansion feature must be enabled" \
    $pool raidz1-0 ${disks[$devs]}
attach_fails "raidz_expansion feature must be enabled" \
    -s $pool raidz1-0 ${disks[$devs]}
log_must zpool destroy $pool

# device_rebuild disabled: -s reports that feature.
log_must zpool create -f $opts -o feature@device_rebuild=disabled $pool \
    raidz1 ${disks[1..$(($devs-1))]}
attach_fails "device_rebuild feature must be enabled" \
    -s $pool raidz1-0 ${disks[$devs]}
log_must zpool destroy $pool

log_pass "zpool attach -s to raidz reports the reason it is refused."
