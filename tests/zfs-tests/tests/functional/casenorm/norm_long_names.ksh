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
# On a normalizing file system, a valid name of up to 255 bytes can be
# created, looked up and removed even when its normalized form is longer
# than 255 bytes (formD and formKD decompose each Hangul syllable into
# two or three jamo, tripling its size).
#
# STRATEGY:
# 1. For each normalization form, create a file system with it.
# 2. Create a file whose name is 80 Hangul syllables (240 bytes,
#    720 bytes in formD) followed by a precomposed e-acute.
# 3. Check that it exists, that readdir returns it, and that the same
#    name with a decomposed e-acute finds the same file (an equivalent
#    name under normalization).
# 4. Remove it and check the directory is empty.
#

verify_runnable "global"

function cleanup
{
	destroy_testfs
}

log_onexit cleanup
log_assert "Names whose normalized form exceeds 255 bytes work"

typeset hangul=""
typeset -i i
for ((i = 0; i < 80; i++)); do
	hangul="$hangul$(printf '\uac01')"
done
typeset name_c="$hangul$(printf '\u00e9')"
typeset name_d="${hangul}e$(printf '\u0301')"

for form in formC formD formKC formKD; do
	log_note "normalization=$form"
	create_testfs "-o normalization=$form"
	dir=$TESTDIR

	log_must touch "$dir/$name_c"
	log_must test -f "$dir/$name_c"
	typeset -i n=$(ls -A $dir | wc -l)
	(( n == 1 )) || log_fail "$form: $n entries after creating one file"
	[[ "$(ls -A $dir)" == "$name_c" ]] || \
	    log_fail "$form: readdir returned another name"

	typeset ino_c=$(stat -c %i "$dir/$name_c" 2>/dev/null || \
	    stat -f %i "$dir/$name_c")
	typeset ino_d=$(stat -c %i "$dir/$name_d" 2>/dev/null || \
	    stat -f %i "$dir/$name_d")
	[[ -n "$ino_c" && "$ino_c" == "$ino_d" ]] || \
	    log_fail "$form: equivalent name found inode '$ino_d', not '$ino_c'"

	log_must rm "$dir/$name_c"
	n=$(ls -A $dir | wc -l)
	(( n == 0 )) || log_fail "$form: $n entries left after rm"

	destroy_testfs
done

log_pass "Names whose normalized form exceeds 255 bytes work"
