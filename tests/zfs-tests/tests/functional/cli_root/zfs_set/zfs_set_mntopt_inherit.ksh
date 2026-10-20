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
. $STF_SUITE/tests/functional/cli_root/zfs_set/zfs_set_common.kshlib

#
# DESCRIPTION:
#	A mount option property set on a filesystem is reported as
#	inherited, with the new value, by its mounted descendants, and
#	not as a temporary mount option.
#
# STRATEGY:
#	1. Create a filesystem with a child and a grandchild, all mounted.
#	2. For each mount option property, set the non-default value on
#	   the filesystem.
#	3. Verify that the child and grandchild report that value,
#	   inherited from the filesystem.
#	4. Inherit the property on the filesystem, and verify that all
#	   three report the value and source they had before again.
#

verify_runnable "both"

parent=$TESTPOOL/$TESTFS/mntopt_inherit
child=$parent/child
grandchild=$child/grandchild

function cleanup
{
	datasetexists $parent && destroy_dataset $parent -r
}

log_assert "Mount option properties set on a filesystem are inherited" \
	"by its mounted descendants"
log_onexit cleanup

log_must zfs create $parent
log_must zfs create $child
log_must zfs create $grandchild
for fs in $parent $child $grandchild; do
	log_must ismounted $fs
done

set -A props atime exec setuid readonly
set -A values off off off on

typeset -i i=0
while ((i < ${#props[@]})); do
	prop=${props[i]}
	# The value $parent inherits: the default, or one set by the setup
	# or an earlier test on $TESTPOOL/$TESTFS.
	orig_value=$(get_prop $prop $parent)
	orig_source=$(get_source $prop $parent)

	log_must zfs set $prop=${values[i]} $parent
	log_must check_prop_source $parent $prop ${values[i]} local
	for fs in $child $grandchild; do
		log_must check_prop_inherit $fs $prop $parent
	done

	log_must zfs inherit $prop $parent
	for fs in $parent $child $grandchild; do
		log_must check_prop_source $fs $prop "$orig_value" "$orig_source"
	done
	((i += 1))
done

log_pass "Mount option properties set on a filesystem are inherited" \
	"by its mounted descendants"
