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
# Description:
# The process title of "zfs send -V" shows the progress of the whole
# send: in a replication stream it doesn't start again at 0% with each
# snapshot.
#
# Strategy:
# 1. A filesystem with two snapshots of 96 MiB of new data each.
# 2. Read "zfs send -RV" at about 24 MiB/s, sampling the process title
#    every half second.
# 3. The percentage must never go down, and the second snapshot's must
#    reach at least 50%.
#

verify_runnable "both"

fs=$TESTPOOL/$TESTFS/sendv
titles=$TEST_BASE_DIR/zfs_send-V_total.titles

function cleanup
{
	datasetexists $fs && destroy_dataset $fs -r
	rm -f $titles $titles.pct
}

function slow_reader
{
	typeset -i n
	while :; do
		n=$(head -c 1048576 | wc -c)
		(( n == 0 )) && break
		sleep 0.04
	done
}

log_assert "zfs send -V shows the progress of the whole replication stream"
log_onexit cleanup

log_must zfs create -o compression=off $fs
typeset mntpnt=$(get_prop mountpoint $fs)
log_must dd if=/dev/urandom of=$mntpnt/a bs=1M count=96
log_must zfs snapshot $fs@a
log_must dd if=/dev/urandom of=$mntpnt/b bs=1M count=96
log_must zfs snapshot $fs@b

zfs send -RV $fs@b | slow_reader &
typeset pid=$!
: > $titles
while kill -0 $pid 2>/dev/null; do
	ps -eo args | grep "^zfs: sending $fs@" >> $titles
	sleep 0.5
done
wait $pid || log_fail "zfs send -RV failed"
cat $titles

typeset -i last=0 pct=0 maxb=0 n=0
typeset snap
# "zfs: sending POOL/FS@SNAP (PCT%: SENT/TOTAL)" -> "SNAP PCT"
sed -n 's/^zfs: sending [^@]*@\([^ ]*\) (\([0-9]*\)%.*/\1 \2/p' $titles > $titles.pct
while read -r snap pct; do
	(( n += 1 ))
	(( pct < last )) && \
	    log_fail "the title went from $last% down to $pct% (@$snap)"
	last=$pct
	[[ $snap == b ]] && (( pct > maxb )) && maxb=$pct
done < $titles.pct
(( n >= 4 )) || log_fail "only $n process titles sampled"
(( maxb >= 50 )) || log_fail "the second snapshot only reached $maxb%"

log_pass "zfs send -V shows the progress of the whole replication stream"
