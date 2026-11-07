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

#
# Copyright (c) 2024. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/l2arc/l2arc.cfg

#
# DESCRIPTION:
#	L2ARC DWPD rate limiting correctly limits write rate.
#
# STRATEGY:
#	1. Set a near-zero DWPD limit before creating the pool.
#	2. Create pool with cache device (L2ARC >= arc_c_max * 2).
#	3. Write data until the cache device has wrapped: DWPD only limits
#	   writes after the first pass, so the near-zero limit must not
#	   hold the first pass back.
#	4. For each DWPD value 30000, 0, 15000, 7500:
#	   a. With the near-zero limit, write fresh data for L2ARC.
#	   b. Set the DWPD value and measure L2ARC writes for a while.
#	5. Verify that no limited value wrote more than its daily budget
#	   allows for the time measured and the number of feeds, that each
#	   one wrote something, that a higher limit wrote more per feed
#	   than the lowest one allows, and that DWPD=0 (unlimited) wrote
#	   more per feed than the highest one allows.
#

verify_runnable "global"

log_assert "L2ARC DWPD rate limiting correctly limits write rate."

function cleanup
{
	if poolexists $TESTPOOL ; then
		destroy_pool $TESTPOOL
	fi

	restore_tunable L2ARC_WRITE_MAX
	restore_tunable L2ARC_NOPREFETCH
	restore_tunable L2ARC_DWPD_LIMIT
	restore_tunable L2ARC_EXT_HEADROOM_PCT
	restore_tunable ARC_MIN
	restore_tunable ARC_MAX
}
log_onexit cleanup

# Save original tunables
save_tunable L2ARC_WRITE_MAX
save_tunable L2ARC_NOPREFETCH
save_tunable L2ARC_DWPD_LIMIT
save_tunable L2ARC_EXT_HEADROOM_PCT
save_tunable ARC_MIN
save_tunable ARC_MAX

#
# Test parameters.  The cache device is a third of the 900MB the DWPD
# values were first chosen for, so they are three times as large here:
# 30000 = 1.04MB/s, 15000 = 0.52MB/s, 7500 = 0.26MB/s.  A feed writes a
# buffer only if it and a 64KB log block fit in its write size, so the
# lowest limit must give more than 192KB a second for 128KB blocks.
# A limit of 1 (0.01 DWPD, about 1KB/s) holds L2ARC writes back while
# the data for the next measurement is written.
#
typeset cache_sz=300
typeset arc_max_mb=128
typeset chunk_mb=32
typeset supply_mb=64
typeset test_time=10
typeset min_feeds=5
typeset hold=1

# arc_max = 128MB so that L2ARC (300MB) >= arc_c_max * 2 threshold
log_must set_tunable64 ARC_MIN $((64 * 1024 * 1024))
log_must set_tunable64 ARC_MAX $((arc_max_mb * 1024 * 1024))
log_must set_tunable32 L2ARC_NOPREFETCH 0
log_must set_tunable32 L2ARC_WRITE_MAX $((200 * 1024 * 1024))
log_must set_tunable64 L2ARC_EXT_HEADROOM_PCT 0
log_must set_tunable32 L2ARC_DWPD_LIMIT $hold

log_must truncate -s 2G $VDEV
log_must truncate -s ${cache_sz}M $VDEV_CACHE
log_must zpool create -f $TESTPOOL $VDEV cache $VDEV_CACHE

#
# The daily budget for a DWPD limit of $1: that share of the whole cache
# file (a little more than the device), plus the burst allowance.
#
function dwpd_budget
{
	echo $(( (cache_sz * 1024 * 1024 * $1) / 100 + 64 * 1024 * 1024 ))
}

#
# The most a DWPD limit of $1 lets L2ARC write in $2 seconds: the budget
# spread over a day, for two seconds more than measured (the feed that
# was running at the start, and rounding of the start and end times).
#
function dwpd_bound
{
	echo $(( $(dwpd_budget $1) * ($2 + 2) / 86400 ))
}

#
# The most a DWPD limit of $1 lets one feed write: its write size is the
# budget per second, rounded up to a sector.
#
function dwpd_feed_max
{
	echo $(( ($(dwpd_budget $1) / 86400 / 512 + 2) * 512 ))
}

#
# The device header has L2ARC_DEV_HDR_EVICT_FIRST (1) set in its flags
# until the write hand has wrapped once.
#
function l2arc_first_pass_done
{
	typeset flags=$(zdb -l $VDEV_CACHE | awk '$1 == "flags:" {print $2}')

	[[ -n $flags ]] && (( (flags & 1) == 0 ))
}

#
# Step 3: write data until the first pass is over.  The near-zero limit
# set before the pool was created doesn't apply to the first pass, so
# L2ARC must keep writing everything it is fed until the device wraps.
# Write in chunks and wait for the device header to say so, up to four
# times the size of the cache device.
#
typeset n=0
typeset l2_start=$(kstat arcstats.l2_write_bytes)
typeset max_chunks=$(( 4 * cache_sz / chunk_mb ))
while ! l2arc_first_pass_done; do
	if (( n >= max_chunks )); then
		typeset l2_now=$(kstat arcstats.l2_write_bytes)
		log_fail "L2ARC first pass not done after" \
		    "$((n * chunk_mb))MB:" \
		    "$(( (l2_now - l2_start) / 1024 / 1024))MB written to" \
		    "the cache device"
	fi
	log_must dd if=/dev/urandom of=/$TESTPOOL/fill$n bs=1M \
	    count=$chunk_mb status=none
	log_must zpool sync $TESTPOOL
	# Let the feed thread write the new data out (it wakes every second)
	log_must sleep 2
	(( n++ ))
done
typeset first_pass=$(( $(kstat arcstats.l2_write_bytes) - l2_start ))
log_note "First pass done after $((n * chunk_mb))MB written," \
    "$((first_pass / 1024 / 1024))MB to the cache device"
if (( first_pass < cache_sz * 1024 * 1024 * 3 / 4 )); then
	log_fail "First pass done after only $((first_pass / 1024))KB"
fi
log_must rm /$TESTPOOL/fill*
log_must zpool sync $TESTPOOL

typeset -A delta
typeset -A elapsed
typeset -A feeds

#
# Step 4.  The checks below compare what was written with the time taken
# and with the number of feeds (l2_feeds), so that a stalled system,
# where neither the feed thread nor the test runs for a while, doesn't
# change the outcome.  Each measurement lasts until there have been a few
# feeds.
#
for dwpd in 30000 0 15000 7500; do
	# Step 4a: fresh data for L2ARC, held back by the near-zero limit
	log_must set_tunable32 L2ARC_DWPD_LIMIT $hold
	log_must dd if=/dev/urandom of=/$TESTPOOL/data$dwpd bs=1M \
	    count=$supply_mb status=none
	log_must zpool sync $TESTPOOL

	# Step 4b: measure L2ARC writes with the limit under test
	typeset t0=$(date +%s)
	typeset feeds0=$(kstat arcstats.l2_feeds)
	typeset bytes0=$(kstat arcstats.l2_write_bytes)
	log_must set_tunable32 L2ARC_DWPD_LIMIT $dwpd
	# At least test_time seconds and min_feeds feeds, up to 2 minutes
	typeset i
	for i in {1..120}; do
		sleep 1
		(( i >= test_time && \
		    $(kstat arcstats.l2_feeds) - feeds0 >= min_feeds )) && break
	done
	typeset bytes1=$(kstat arcstats.l2_write_bytes)
	typeset feeds1=$(kstat arcstats.l2_feeds)
	typeset t1=$(date +%s)

	delta[$dwpd]=$((bytes1 - bytes0))
	elapsed[$dwpd]=$((t1 - t0))
	feeds[$dwpd]=$((feeds1 - feeds0))
	log_note "DWPD=$dwpd: $((delta[$dwpd] / 1024))KB in" \
	    "${elapsed[$dwpd]}s, ${feeds[$dwpd]} feeds"
	log_must rm /$TESTPOOL/data$dwpd
done

# Step 5: no limited value writes more than its budget, but each writes
for dwpd in 30000 15000 7500; do
	typeset bound=$(dwpd_bound $dwpd ${elapsed[$dwpd]})
	if (( delta[$dwpd] > bound )); then
		log_fail "DWPD=$dwpd wrote $((delta[$dwpd] / 1024))KB in" \
		    "${elapsed[$dwpd]}s, more than its $((bound / 1024))KB"
	fi
	bound=$(( (feeds[$dwpd] + 1) * $(dwpd_feed_max $dwpd) ))
	if (( delta[$dwpd] > bound )); then
		log_fail "DWPD=$dwpd wrote $((delta[$dwpd] / 1024))KB in" \
		    "${feeds[$dwpd]} feeds, more than its $((bound / 1024))KB"
	fi
	if (( delta[$dwpd] == 0 )); then
		log_fail "DWPD=$dwpd wrote nothing in ${elapsed[$dwpd]}s"
	fi
done

# Higher limits write more per feed than the lowest limit allows
for dwpd in 30000 15000; do
	typeset bound=$(( feeds[$dwpd] * $(dwpd_feed_max 7500) ))
	if (( delta[$dwpd] <= bound )); then
		log_fail "DWPD=$dwpd wrote $((delta[$dwpd] / 1024))KB in" \
		    "${feeds[$dwpd]} feeds, no more than DWPD=7500 allows" \
		    "($((bound / 1024))KB)"
	fi
done

# DWPD=0 (unlimited) writes more than the highest limit allows
typeset bound=$(( (feeds[0] + 1) * $(dwpd_feed_max 30000) ))
if (( delta[0] <= bound )); then
	log_fail "DWPD=0 (unlimited) wrote $((delta[0] / 1024))KB in" \
	    "${feeds[0]} feeds, no more than DWPD=30000 allows" \
	    "($((bound / 1024))KB)"
fi

destroy_pool $TESTPOOL

log_pass "L2ARC DWPD rate limiting correctly limits write rate."
