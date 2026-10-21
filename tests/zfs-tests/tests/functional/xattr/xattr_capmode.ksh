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
# Extended attributes can be used through a descriptor by a process in
# capability mode (FreeBSD capsicum).
#
# STRATEGY:
#	For both of xattr=dir and xattr=sa:
#	1. Create a file with a user extended attribute.
#	2. Open it, enter capability mode, and get, list, set and delete
#	   extended attributes through the descriptor (extattr_capmode).
#	3. All of them must succeed, not fail with ECAPMODE/ENOTCAPABLE.
#

verify_runnable "both"

function cleanup
{
	for x in dir sa; do
		datasetexists $TESTPOOL/capmode-$x && \
		    destroy_dataset $TESTPOOL/capmode-$x
	done
}
log_onexit cleanup

log_assert "Extended attributes work through a descriptor in capability mode"

for x in dir sa; do
	fs=$TESTPOOL/capmode-$x
	log_must zfs create -o xattr=$x $fs
	file=$(get_prop mountpoint $fs)/file
	log_must touch $file
	log_must setextattr user test-01 asdf $file
	log_must eval "getextattr -q user test-01 $file | grep -qx asdf"
	log_must extattr_capmode $file test-01 asdf
	log_must eval "getextattr -q user test-01 $file | grep -qx asdf"
	log_mustnot getextattr -q user test-01.new $file
done

log_pass "Extended attributes work through a descriptor in capability mode"
