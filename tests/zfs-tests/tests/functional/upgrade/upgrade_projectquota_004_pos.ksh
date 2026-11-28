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

. $STF_SUITE/tests/functional/upgrade/upgrade_common.kshlib

#
# DESCRIPTION:
#	A project ID set on a file created before project quota was enabled
#	must be kept, also when the file's xattr dir already has a project ID
#	slot.
#
#	zfs_setattr() moves such a file to the project ID layout with
#	sa_add_projid(), on its xattr dir first.  If the xattr dir already
#	has the layout (EEXIST), the file must still be moved; otherwise its
#	project ID is only kept in memory and is lost when the file is
#	read back from disk.  The xattr dir has the layout when it was
#	created after project quota was enabled, or when an earlier attempt
#	moved the xattr dir and then failed on the file.
#
# STRATEGY:
#	1. Create a pool with all features disabled and xattr=dir, and on it
#	   f1 (no xattrs yet) and f2 (an xattr dir, plus an xattr=sa xattr
#	   in its spill block).  The files belong to a regular user.
#	2. Enable project quota, export and import the pool, and give f1 an
#	   xattr: its xattr dir is created with a project ID slot.
#	3. Set f2's project ID with EIO injected on its spill block: the
#	   xattr dir is moved, the file is not, and the call fails.
#	4. As the owner (as root on FreeBSD), set the project IDs of f1 and
#	   of f2 (retry).
#	5. Both project IDs and the project usage must survive export and
#	   import.
#

verify_runnable "global"

typeset user=pqup4
typeset group=pqgp4

function cleanup
{
	zinject -c all >/dev/null 2>&1
	cleanup_upgrade
	del_user $user
	del_group $group
}

# Run as the owner where that is enough to set a project ID (Linux).
function owner_run
{
	if is_linux; then
		user_run $user "$@"
	else
		"$@"
	fi
}

function check_projid # file projid
{
	typeset id=$(zfs project $1 | awk '{print $1}')
	[[ "$id" == "$2" ]] || log_fail "$1: project ID is $id, not $2"
}

function check_used # projid objects
{
	typeset used=$(get_prop projectobjused@$1 $TESTPOOL)
	[[ "$used" == "$2" ]] ||
	    log_fail "projectobjused@$1 is $used, not $2"
}

log_assert "project ID of a pre-upgrade file with an xattr dir is kept"
log_onexit cleanup

typeset f1=$TESTDIR/f1
typeset f2=$TESTDIR/f2
typeset out=$TEST_BASE_DIR/upgrade_projectquota_004.out

log_must add_group $group
log_must add_user $group $user

# 1. Pre-project-quota files owned by $user.
log_must zpool create -d -m $TESTDIR $TESTPOOL $TMPDEV
log_must zfs set xattr=dir $TESTPOOL
log_must touch $f1 $f2
log_must set_xattr small 1 $f2
log_must zfs set xattr=sa $TESTPOOL
# Random data, so the spill block is not embedded in its block pointer.
log_must eval "dd if=/dev/urandom bs=1100 count=1 2>/dev/null | \
    openssl base64 -A | set_xattr_stdin big $f2"
log_must zfs set xattr=dir $TESTPOOL
log_must chown $user $f1 $f2
typeset obj2=$(get_objnum $f2)
typeset objset=$(get_prop objsetid $TESTPOOL)

# 2. Enable project quota; f1's xattr dir is created after that.
log_must zpool upgrade $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import -d $TMPDEV $TESTPOOL
typeset -i i=0
while ! zfs projectspace -o used $TESTPOOL | grep -q "USED"; do
	((i++ < 30)) || log_fail "project quota not enabled on $TESTPOOL"
	sleep 1
done
log_must set_xattr small 1 $f1

# 3. f2: the xattr dir is moved, then the file's spill block fails.
log_must zinject -a -b $(printf '%x:%x:0:fffffffffffffffe' $objset $obj2) \
    -e io $TESTPOOL
log_mustnot eval "zfs project -p 305 $f2 > $out 2>&1"
cat $out
log_must grep -q "Input/output error" $out
log_must zinject -c all
check_projid $f2 0

# 4. Set both project IDs as the owner.
log_must owner_run zfs project -p 304 $f1
log_must owner_run zfs project -p 305 $f2
check_projid $f1 304
check_projid $f2 305

# 5. Each project holds its file, the xattr dir and the xattr in it.
log_must zpool sync $TESTPOOL
check_used 304 3
check_used 305 3
log_must zpool export $TESTPOOL
log_must zpool import -d $TMPDEV $TESTPOOL
check_projid $f1 304
check_projid $f2 305
check_used 304 3
check_used 305 3

rm -f $out
log_pass "project ID of a pre-upgrade file with an xattr dir is kept"
