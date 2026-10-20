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

. $STF_SUITE/tests/functional/channel_program/channel_common.kshlib

#
# DESCRIPTION:
#	zfs.check.destroy() and zfs.sync.destroy() return ENOENT (2) for a
#	snapshot or bookmark that does not exist, as they do for a
#	filesystem, instead of reporting success.
#

verify_runnable "global"

fs=$TESTPOOL/$TESTFS
snap=$fs@$TESTSNAP
bm=$fs#testbm

function cleanup
{
	destroy_dataset $snap
}

log_onexit cleanup

log_mustnot snapexists $snap
log_mustnot bkmarkexists $bm

log_must_program_sync $TESTPOOL - $fs/nosuchfs $fs@nosuchsnap \
    $fs#nosuchbm <<-EOF
	arg = ...
	for _, name in ipairs(arg["argv"]) do
		err = zfs.check.destroy(name)
		assert(err == 2,
		    "zfs.check.destroy(" .. name .. ") returned " .. err)
		err = zfs.sync.destroy(name)
		assert(err == 2,
		    "zfs.sync.destroy(" .. name .. ") returned " .. err)
	end
	return 0
EOF

# An existing snapshot and bookmark are still destroyed.
create_snapshot $TESTPOOL/$TESTFS $TESTSNAP
log_must zfs bookmark $snap $bm
log_must_program_sync $TESTPOOL - $bm $snap <<-EOF
	arg = ...
	for _, name in ipairs(arg["argv"]) do
		err = zfs.sync.destroy(name)
		assert(err == 0,
		    "zfs.sync.destroy(" .. name .. ") returned " .. err)
	end
	return 0
EOF
log_mustnot snapexists $snap
log_mustnot bkmarkexists $bm

log_pass "Destroying a missing snapshot or bookmark returns ENOENT."
