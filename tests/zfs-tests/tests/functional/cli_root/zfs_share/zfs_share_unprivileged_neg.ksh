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
# 'zfs share' run by an unprivileged user fails with readable errors:
# each message on its own line, and the dataset name quoted on its own.
#
# STRATEGY:
# 1. Set sharenfs=on and unshare the dataset.
# 2. Run 'zfs share <fs>' and 'zfs share -a nfs' as an unprivileged user.
# 3. Verify that both fail, that the dataset stays unshared, and that
#    stderr has "cannot share '<fs>': " at the start of a line.
#

verify_runnable "global"

typeset user=zshareusr
typeset group=zsharegrp

function cleanup
{
	del_user $user
	del_group $group
	log_must zfs set sharenfs=off $TESTPOOL/$TESTFS
	is_shared $TESTPOOL/$TESTFS && \
	    log_must unshare_fs $TESTPOOL/$TESTFS
}

log_assert "'zfs share' by an unprivileged user fails with readable errors"
log_onexit cleanup

log_must add_group $group
log_must add_user $group $user

log_must zfs set sharenfs=on $TESTPOOL/$TESTFS
is_shared $TESTPOOL/$TESTFS && log_must unshare_fs $TESTPOOL/$TESTFS

typeset err=$TEST_BASE_DIR/err
for cmd in "zfs share $TESTPOOL/$TESTFS" "zfs share -a nfs"; do
	log_mustnot user_run $user $cmd
	log_mustnot is_shared $TESTPOOL/$TESTFS
	grep -q "^cannot share '$TESTPOOL/$TESTFS': " $err || \
	    log_fail "'$cmd' error isn't on its own line or misquotes" \
	    "the dataset: $(<$err)"
done

log_pass "'zfs share' by an unprivileged user fails with readable errors"
