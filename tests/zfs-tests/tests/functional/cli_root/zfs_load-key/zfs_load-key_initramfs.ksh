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
# When libzfs loads its libfetch (libcurl) at run time, the initramfs-tools
# hook must copy that library into the initramfs, or a key with an http://
# or https:// keylocation can't be loaded at boot.  On Debian and Ubuntu
# the library's soname (libcurl.so.4) is a symlink to the versioned file.
#
# STRATEGY:
# 1. Skip unless initramfs-tools and the zfs hook are installed, the hook
#    copies a run-time loaded libfetch, and that library is installed.
# 2. Build an initramfs with mkinitramfs.
# 3. Verify that it holds the library's soname and the file it points to.
#

verify_runnable "global"

typeset hook=/usr/share/initramfs-tools/hooks/zfs
typeset initrd=$TEST_BASE_DIR/zfs_load-key_initramfs.img
typeset list=$TEST_BASE_DIR/zfs_load-key_initramfs.list

function cleanup
{
	rm -f $initrd $list
}
log_onexit cleanup

# initramfs-tools runs helpers (cpio, compressors, ...) that are not in the
# constrained PATH; give it a system PATH, as mkinitramfs does itself.
function initramfs_tools
{
	PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# Is a file named $1 (in any directory) in the initramfs?
function in_initramfs
{
	awk -v n="$1" '{ sub(".*/", ""); if ($0 == n) f = 1 } END { exit !f }' \
	    $list
}

log_assert "The initramfs-tools hook copies libfetch into the initramfs"

if ! is_linux || [[ ! -f $hook ]] ||
    ! initramfs_tools command -v mkinitramfs > /dev/null ||
    ! initramfs_tools command -v lsinitramfs > /dev/null; then
	log_unsupported "initramfs-tools or its zfs hook is not installed"
fi

# The hook copies "@LIBFETCH_SONAME@" only if @LIBFETCH_DYNAMIC@ is set.
typeset soname=$(sed -n \
    's/.*-name "\([^"]*\)" | while read -r libfetch;.*/\1/p' $hook)
if [[ -z $soname ]] || grep -q '^if \[ 0 -gt 0 \]' $hook; then
	log_unsupported "libzfs does not load a libfetch at run time"
fi

typeset lib=$(find /lib/ ! -type d -name $soname | head -1)
if [[ -z $lib ]]; then
	log_unsupported "$soname is not installed"
fi
typeset target=$(basename $(readlink -f $lib))
log_note "$lib -> $target"

log_must initramfs_tools mkinitramfs -o $initrd
log_must eval "initramfs_tools lsinitramfs $initrd > $list"
grep -E 'libcurl|libfetch' $list | while read -r f; do
	log_note "in initramfs: $f"
done

log_must in_initramfs $soname
log_must in_initramfs $target

log_pass "The initramfs-tools hook copies libfetch into the initramfs"
