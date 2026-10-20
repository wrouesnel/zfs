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

. $STF_SUITE/tests/functional/pam/utilities.kshlib

#
# DESCRIPTION:
#	pam_zfs_key's chauthtok must stay out of the way of a user who has no
#	dataset under homes= (a new user being given a first password, or
#	root setting a password): no "Current password" prompt, no failure.
#
# STRATEGY:
#	1. homes= points at a filesystem with no dataset for the test user.
#	2. With pam_zfs_key optional, chauthtok must not prompt.
#	3. With pam_zfs_key required, chauthtok with no input must succeed
#	   and not prompt.
#	4. The user's real dataset (under the setup's homes) still changes
#	   its key with the module required.
#

if [ -n "$ASAN_OPTIONS" ]; then
	export LD_PRELOAD=$(ldd "$(command -v zfs)" | awk '/libasan\.so/ {print $3}')
fi

typeset out=$TEST_BASE_DIR/pam_chauthtok_no_dataset.out

function cleanup
{
	rmconfig
	datasetexists $TESTPOOL/pam-empty && destroy_dataset $TESTPOOL/pam-empty
	rm -f $out
}

function required_config # homes
{
	printf '%s\trequired\t%s\t%s\n%s\trequired\tpam_permit.so\n' \
	    password "$pammodule" "$1" password > "${pamconfig}"
}

log_assert "pam_zfs_key chauthtok ignores users without a dataset"
log_onexit cleanup

log_must zfs create -o mountpoint="$TESTDIR-empty" $TESTPOOL/pam-empty
log_mustnot datasetexists $TESTPOOL/pam-empty/${username}

genconfig "homes=$TESTPOOL/pam-empty runstatedir=${runstatedir}"
pamtester -v ${pamservice} ${username} chauthtok < /dev/null > $out 2>&1
typeset rc=$?
cat $out
[[ $rc -eq 0 ]] || log_fail "chauthtok (module optional) exited $rc"
grep -q "Current password" $out && \
    log_fail "chauthtok (module optional) prompted for the current password"

required_config "homes=$TESTPOOL/pam-empty runstatedir=${runstatedir}"
pamtester -v ${pamservice} ${username} chauthtok < /dev/null > $out 2>&1
rc=$?
cat $out
grep -q "Current password" $out && \
    log_fail "chauthtok (module required) prompted for the current password"
[[ $rc -eq 0 ]] || log_fail "chauthtok (module required) exited $rc"

# A user with a dataset still gets its key changed, and back.
required_config "homes=$TESTPOOL/pam runstatedir=${runstatedir}"
log_must eval "printf 'testpass\nsecondpass\nsecondpass\n' | " \
    "pamtester ${pamservice} ${username} chauthtok"
log_mustnot eval "echo testpass | zfs load-key -n $TESTPOOL/pam/${username}"
log_must eval "echo secondpass | zfs load-key -n $TESTPOOL/pam/${username}"
log_must eval "printf 'secondpass\ntestpass\ntestpass\n' | " \
    "pamtester ${pamservice} ${username} chauthtok"
log_must eval "echo testpass | zfs load-key -n $TESTPOOL/pam/${username}"
keystatus unavailable

log_pass "pam_zfs_key chauthtok ignores users without a dataset"
