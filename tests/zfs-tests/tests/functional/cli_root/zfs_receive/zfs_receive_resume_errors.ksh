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
#	zfs receive must name the real cause when a resumable receive fails
#	because of the destination, not suggest that the kernel modules be
#	upgraded.
#
# STRATEGY:
#	1. Interrupt a send -R | receive -s inside the child filesystem, and
#	   resume it into the top-level filesystem: the receive must fail
#	   and say that it has no partially received stream to resume.
#	2. Interrupt an incremental receive -s of the child, and resume it
#	   into the top-level filesystem: the same.  Resuming it into the
#	   child must work.
#	3. Hold an incremental receive -s after it began, snapshot the
#	   destination, then let it finish: the receive must fail and say
#	   that the destination's snapshots changed during the receive.
#

verify_runnable "both"

function cleanup
{
	[[ -n "$wpid" ]] && kill $wpid 2>/dev/null
	rm -f $marker
	datasetexists $dst/kid && zfs receive -A $dst/kid 2>/dev/null
	for ds in $src $dst; do
		datasetexists $ds && destroy_dataset $ds -r
	done
	rm -f $stream $out
}

log_assert "zfs receive names the cause of a failed resumable receive"
log_onexit cleanup

typeset src=$TESTPOOL/$TESTFS1
typeset dst=$TESTPOOL/$TESTFS2
typeset stream=$TEST_BASE_DIR/recv_resume_errors.zsend
typeset out=$TEST_BASE_DIR/recv_resume_errors.out
typeset marker=$TEST_BASE_DIR/recv_resume_errors.go
typeset wpid=""

log_must zfs create $src
log_must zfs create $src/kid
log_must eval "echo small >$(get_prop mountpoint $src)/f"
log_must dd if=/dev/urandom of=$(get_prop mountpoint $src/kid)/big bs=1024k count=32
log_must zfs snapshot -r $src@s1

# 1. A full replication stream cut inside the child.
log_must eval "zfs send -R $src@s1 >$stream"
typeset -i size=$(wc -c <$stream)
log_mustnot eval "dd if=$stream bs=1024 count=$((size / 1024 * 6 / 10)) |" \
    "zfs receive -s $dst"
token=$(get_prop receive_resume_token $dst/kid)
[[ "$token" == "-" ]] && log_fail "no resume token on $dst/kid"
log_mustnot eval "zfs send -t $token | zfs receive -s $dst >$out 2>&1"
cat $out
log_must grep -q "no partially received stream to resume" $out
log_must eval "zfs send -t $token | zfs receive -s $dst/kid"
log_must snapexists $dst/kid@s1

# 2. An incremental stream of the child, cut.
log_must dd if=/dev/urandom of=$(get_prop mountpoint $src/kid)/big2 bs=1024k count=32
log_must zfs snapshot -r $src@s2
log_must eval "zfs send -i @s1 $src/kid@s2 >$stream"
size=$(wc -c <$stream)
log_mustnot eval "dd if=$stream bs=1024 count=$((size / 1024 / 2)) |" \
    "zfs receive -s $dst/kid"
token=$(get_prop receive_resume_token $dst/kid)
[[ "$token" == "-" ]] && log_fail "no resume token on $dst/kid"
log_mustnot eval "zfs send -t $token | zfs receive -s $dst >$out 2>&1"
cat $out
log_must grep -q "no partially received stream to resume" $out
log_mustnot grep -q "kernel modules must be upgraded" $out
log_must eval "zfs send -t $token | zfs receive -s $dst/kid"
log_must snapexists $dst/kid@s2

# 3. A snapshot of the destination taken during an incremental receive.
log_must dd if=/dev/urandom of=$(get_prop mountpoint $src/kid)/big3 bs=1024k count=32
log_must zfs snapshot $src/kid@s3
log_must eval "zfs send -i @s2 $src/kid@s3 >$stream"
rm -f $marker
( dd if=$stream bs=1024k count=1 2>/dev/null
  while [[ ! -e $marker ]]; do sleep 0.1; done
  dd if=$stream bs=1024k skip=1 2>/dev/null ) |
    zfs receive -s $dst/kid >$out 2>&1 &
wpid=$!
# The receive has begun once its resume state shows.
typeset -i i=0
while [[ "$(get_prop receive_resume_token $dst/kid)" == "-" ]]; do
	((i++ > 300)) && log_fail "the receive did not begin"
	sleep 0.1
done
log_must zfs snapshot $dst/kid@during
log_must touch $marker
wait $wpid
typeset -i rc=$?
wpid=""
cat $out
(( rc != 0 )) || log_fail "the receive succeeded"
log_must grep -q "snapshots of '$dst/kid' changed during the receive" $out
log_mustnot grep -q "kernel modules must be upgraded" $out

log_pass "zfs receive names the cause of a failed resumable receive"
