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
#	'zfs receive -n' of a replication stream into a new filesystem must
#	succeed when the real receive would: the filesystems that the stream
#	creates don't exist during a dry run, and later streams in the
#	package (children, incrementals) must not fail on that, nor be
#	matched to other filesystems that hold the same snapshots.
#
# STRATEGY:
#	1. Create a filesystem with a child and a grandchild, with two
#	   snapshots each.
#	2. For a plain and a raw (encrypted) send -R of the newest snapshot:
#	   a. 'zfs receive -n -v' into a new filesystem must succeed, list
#	      every snapshot in the stream under the new name, and create
#	      nothing.
#	   b. The real receive must succeed.
#

verify_runnable "both"

function cleanup
{
	for ds in $src $dst $esrc $edst; do
		datasetexists $ds && destroy_dataset $ds -r
	done
	rm -f $stream $out
}

log_assert "zfs receive -n of a replication stream succeeds like the receive"
log_onexit cleanup

typeset src=$TESTPOOL/$TESTFS1
typeset dst=$TESTPOOL/$TESTFS2
typeset esrc=$TESTPOOL/esrc
typeset edst=$TESTPOOL/edst
typeset stream=$TEST_BASE_DIR/recv_n_recursive.zsend
typeset out=$TEST_BASE_DIR/recv_n_recursive.out

# check_dryrun SRC DST [SEND FLAGS]
function check_dryrun
{
	typeset s=$1 d=$2 flags=$3

	log_must zfs create $s/kid
	log_must zfs create $s/kid/deep
	log_must zfs snapshot -r $s@s1
	log_must eval "echo data >$(get_prop mountpoint $s/kid)/f"
	log_must zfs snapshot -r $s@s2
	log_must eval "zfs send -R $flags $s@s2 >$stream"

	log_must eval "zfs receive -n -v $d <$stream >$out 2>&1"
	cat $out
	for fs in $d $d/kid $d/kid/deep; do
		for snap in s1 s2; do
			log_must grep -q "^would receive .* into $fs@$snap\$" $out
		done
	done
	log_mustnot grep -q "^would receive .* into $s" $out
	log_mustnot datasetexists $d

	log_must eval "zfs receive -u $d <$stream"
	for fs in $d $d/kid $d/kid/deep; do
		log_must snapexists $fs@s1
		log_must snapexists $fs@s2
	done
}

log_must zfs create $src
check_dryrun $src $dst

log_must eval "echo password | zfs create -o encryption=on" \
    "-o keyformat=passphrase $esrc"
check_dryrun $esrc $edst -w

log_pass "zfs receive -n of a replication stream succeeds like the receive"
