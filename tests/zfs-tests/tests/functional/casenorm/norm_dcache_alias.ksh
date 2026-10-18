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

. $STF_SUITE/tests/functional/casenorm/casenorm.kshlib

#
# DESCRIPTION:
# On a file system with normalization=formD, names that normalize to the
# same string refer to the same directory entry.  Name lookups must keep
# agreeing with that after files and directories are created and removed
# under a differently normalized name: no stale "file not found" for a name
# that exists, and no name that still reaches a removed file.
#
# STRATEGY:
# For casesensitivity=sensitive and casesensitivity=mixed, with
# normalization=formD, using the NFC (C) and NFD (D) forms of one name:
# 1. Look up D while nothing exists, then create the file as C: reading D
#    must return C's contents, and removing D must remove the file.
# 2. Create C, read it through D, remove C: D must no longer exist.  Then
#    create a new C: reading D must return the new contents, and a write
#    through D must be visible through C.
# 3. Create C, remove it, create D: C must exist and return D's contents.
# 4. As 3 with directories: mkdir C, rmdir C, mkdir D: C must exist.
#

verify_runnable "global"

function cleanup
{
	destroy_testfs
}

log_onexit cleanup

typeset C=$NAME_C_ORIG
typeset D=$NAME_D_ORIG

function check_content # name expected
{
	typeset got
	got=$(cat "$TESTDIR/$1" 2>&1) ||
	    log_fail "reading $(get_norm $1) failed: $got"
	[[ "$got" == "$2" ]] ||
	    log_fail "reading $(get_norm $1) returned '$got', expected '$2'"
}

function check_entries # expected count of directory entries
{
	typeset n
	n=$(ls -A "$TESTDIR" | wc -l)
	[[ $n -eq $1 ]] || log_fail "$TESTDIR has $n entries, expected $1: \
	    $(ls -A $TESTDIR)"
}

for sens in sensitive mixed; do
	log_note "casesensitivity=$sens normalization=formD"
	create_testfs "-o casesensitivity=$sens -o normalization=formD"

	# 1. A failed lookup of D must not hide a file created as C.
	log_mustnot test -e "$TESTDIR/$D"
	log_must eval "echo nfc > '$TESTDIR/$C'"
	log_must test -e "$TESTDIR/$D"
	check_content $D nfc
	log_must rm "$TESTDIR/$D"
	log_mustnot test -e "$TESTDIR/$C"
	log_mustnot test -e "$TESTDIR/$D"
	check_entries 0

	# 2. D must not keep reaching a file removed as C.
	log_must eval "echo old > '$TESTDIR/$C'"
	check_content $D old
	log_must rm "$TESTDIR/$C"
	log_mustnot test -e "$TESTDIR/$D"
	log_must eval "echo new > '$TESTDIR/$C'"
	check_content $D new
	log_must eval "echo more >> '$TESTDIR/$D'"
	check_content $C "$(printf 'new\nmore')"
	check_entries 1
	log_must rm "$TESTDIR/$C"
	check_entries 0

	# 3. Removing C must not hide a file created as D.
	log_must eval "echo first > '$TESTDIR/$C'"
	log_must rm "$TESTDIR/$C"
	log_must eval "echo nfd > '$TESTDIR/$D'"
	log_must test -e "$TESTDIR/$C"
	check_content $C nfd
	log_must rm "$TESTDIR/$C"
	check_entries 0

	# 4. The same for directories.
	log_must mkdir "$TESTDIR/$C"
	log_must rmdir "$TESTDIR/$C"
	log_must mkdir "$TESTDIR/$D"
	log_must test -d "$TESTDIR/$C"
	log_must rmdir "$TESTDIR/$C"
	log_mustnot test -e "$TESTDIR/$D"
	check_entries 0

	destroy_testfs
done

log_pass "Lookups of normalization-equivalent names stay consistent"
