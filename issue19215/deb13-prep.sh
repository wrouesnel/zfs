#!/usr/bin/env bash
# deb13-prep.sh: provision a Debian 13 test VM for #19215:
# zfs-dkms + zfsutils-linux from trixie-backports, pinned to ZFSVER if set.
# Run as root in the guest.
set -euo pipefail
ZFSVER=${ZFSVER:-2.4.3-2~bpo13+1}
export DEBIAN_FRONTEND=noninteractive
sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources
# 2.4.3-2~bpo13+1 has left the live archive (2.4.4-1~bpo13+1 replaced it), so
# take it from snapshot.debian.org at a date when it was current.
SNAP=${SNAP:-20260815T000000Z}
echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/$SNAP trixie-backports main contrib" \
	>/etc/apt/sources.list.d/snapshot-bpo.list
apt-get update -q
apt-get install -y -q linux-headers-amd64 linux-headers-$(uname -r) dpkg-dev lsof psmisc rclone
apt-cache policy zfs-dkms zfsutils-linux
apt-get install -y -q -t trixie-backports \
	zfs-dkms=$ZFSVER zfsutils-linux=$ZFSVER zfs-zed=$ZFSVER $(apt-cache show zfsutils-linux=$ZFSVER |
	    sed -n 's/^Depends: //p' | tr ',' '\n' |
	    sed -n "s/^ *\(lib[a-z0-9]*linux\) (= .*/\1=$ZFSVER/p")
modprobe zfs
zfs version
