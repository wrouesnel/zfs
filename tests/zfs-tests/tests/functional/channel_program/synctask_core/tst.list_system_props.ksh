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
# Copyright (c) 2016 by Delphix. All rights reserved.
#

. $STF_SUITE/tests/functional/channel_program/channel_common.kshlib
. $STF_SUITE/tests/functional/zvol/zvol_common.shlib

#
# DESCRIPTION:
#       Listing system properties should succeed, and every listed
#       property should be readable with zfs.get_prop().  A snapshot
#       lists only the properties that are valid for its head's type.
#

verify_runnable "global"
fs=$TESTPOOL/$TESTFS/testchild
snap=$fs@$TESTSNAP
vol=$TESTPOOL/$TESTVOL
volsnap=$vol@$TESTSNAP
function cleanup
{
	destroy_dataset $volsnap
	destroy_dataset $snap
	destroy_dataset $fs
	destroy_dataset $vol
}

log_onexit cleanup

log_must zfs create $fs
create_snapshot $fs $TESTSNAP
log_must zfs create -V $VOLSIZE $vol
create_snapshot $vol $TESTSNAP

log_must_program $TESTPOOL - <<-EOF
	zfs.list.system_properties("$fs")
EOF

log_must_program $TESTPOOL - <<-EOF
	zfs.list.system_properties("$snap")
EOF

log_must_program $TESTPOOL - <<-EOF
	zfs.list.system_properties("$vol")
EOF

log_must_program $TESTPOOL - <<-EOF
	zfs.list.system_properties("$volsnap")
EOF

#
# Print the system properties listed for a dataset, separated by spaces.
#
function listed_props
{
	typeset ds=$1

	zfs program -j $TESTPOOL - $ds <<-EOF | sed 's/^{"return":"//; s/"}$//'
		args = ...
		local s = ""
		for _, p in ipairs(zfs.list.system_properties(args["argv"][1])) do
			s = s .. p .. " "
		end
		return s
	EOF
}

for ds in $fs $snap $vol $volsnap; do
	props=$(listed_props $ds)
	[[ -n "$props" ]] || log_fail "no system properties listed for $ds"
	for prop in $props; do
		zfs program $TESTPOOL - $ds $prop >/dev/null 2>&1 <<-EOF || \
		    log_fail "$ds lists '$prop' but zfs.get_prop() rejects it"
			args = ...
			zfs.get_prop(args["argv"][1], args["argv"][2])
		EOF
	done
	log_note "$ds: zfs.get_prop() read every listed property: $props"
done

#
# The ZPL properties belong to filesystems and their snapshots, not to
# a volume's snapshot.
#
for prop in version normalization utf8only casesensitivity; do
	listed_props $snap | grep -qw $prop || \
	    log_fail "$snap does not list '$prop'"
	listed_props $volsnap | grep -qw $prop && \
	    log_fail "$volsnap lists filesystem-only property '$prop'"
done
listed_props $volsnap | grep -qw volsize || \
    log_fail "$volsnap does not list 'volsize'"
listed_props $snap | grep -qw volsize && \
    log_fail "$snap lists volume-only property 'volsize'"

log_pass "Listing system properties should succeed."
