#!/usr/bin/env bash
# debug_setup.sh on|off: switch the PVE VM between the stock 2.4.4-pve1 zfs.ko
# and a --enable-debug build of zfs-2.4.4 (built in ~debian/zfs-2.4.4), and add
# slub_debug for the ZFS caches seen in #19144 plus KFENCE sampling.
# Run as root in the VM, then reboot.
set -euo pipefail
K=$(uname -r); M=/lib/modules/$K/zfs
SLUB="slub_debug=FZPU,zfs_znode_cache,dnode_t,arc_buf_hdr_t_full,arc_buf_t,dmu_buf_impl_t,sa_cache kfence.sample_interval=100"
case ${1:?on|off} in
on)
	[ -f $M/zfs.ko.pve ] || { cp $M/zfs.ko $M/zfs.ko.pve; cp $M/spl.ko $M/spl.ko.pve; }
	cp ~debian/zfs-2.4.4/module/zfs.ko ~debian/zfs-2.4.4/module/spl.ko $M/
	grep -q slub_debug /etc/default/grub || sed -i "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 $SLUB\"|" /etc/default/grub ;;
off)
	[ -f $M/zfs.ko.pve ] && { cp $M/zfs.ko.pve $M/zfs.ko; cp $M/spl.ko.pve $M/spl.ko; }
	sed -i "s| $SLUB||" /etc/default/grub ;;
esac
depmod -a "$K"
update-initramfs -u -k "$K" >/dev/null 2>&1 || true
update-grub >/dev/null 2>&1
grep ^GRUB_CMDLINE_LINUX= /etc/default/grub
