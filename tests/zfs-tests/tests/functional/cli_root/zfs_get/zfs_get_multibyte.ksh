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

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	zfs get and zfs list keep their columns aligned when a value has
#	multibyte (UTF-8) characters.
#
# STRATEGY:
#	1. Two filesystems with user properties of 6 characters each, one
#	   of them with a 2-byte character.
#	2. In a UTF-8 locale, every data row of zfs get (source column
#	   after the value) and zfs list (a column after the value) must
#	   have the same width in characters.
#

verify_runnable "both"

function cleanup
{
	datasetexists $TESTPOOL/$TESTFS/mb1 && destroy_dataset $TESTPOOL/$TESTFS/mb1
	datasetexists $TESTPOOL/$TESTFS/mb2 && destroy_dataset $TESTPOOL/$TESTFS/mb2
}

function check_widths # command...
{
	typeset out line
	typeset -i n w first=-1

	out=$("$@") || log_fail "$* failed"
	print -r -- "$out"
	print -r -- "$out" | tail -n +2 | while IFS= read -r line; do
		w=$(printf '%s' "$line" | wc -m)
		if (( first < 0 )); then
			first=$w
		elif (( w != first )); then
			log_fail "$*: rows are $first and $w characters wide"
		fi
	done
}

log_assert "zfs get and zfs list align multibyte values"
log_onexit cleanup

export LC_ALL=C.UTF-8
[[ $(printf '%s' 'å' | wc -m) -eq 1 ]] || log_unsupported "no C.UTF-8 locale"

log_must zfs create $TESTPOOL/$TESTFS/mb1
log_must zfs create $TESTPOOL/$TESTFS/mb2
log_must zfs set user:note=måndag $TESTPOOL/$TESTFS/mb1
log_must zfs set user:note=monday $TESTPOOL/$TESTFS/mb2

check_widths zfs get -o name,property,value,source user:note \
    $TESTPOOL/$TESTFS/mb1 $TESTPOOL/$TESTFS/mb2
check_widths zfs list -o name,user:note,used \
    $TESTPOOL/$TESTFS/mb1 $TESTPOOL/$TESTFS/mb2
check_widths zfs list -o name,user:note,mountpoint \
    $TESTPOOL/$TESTFS/mb1 $TESTPOOL/$TESTFS/mb2

log_pass "zfs get and zfs list align multibyte values"
