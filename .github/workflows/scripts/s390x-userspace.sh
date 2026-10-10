#!/usr/bin/env bash

######################################################################
# Big-endian (s390x) userspace checks, run in an s390x container under
# qemu-user on an x86 runner.  No kernel module is built or loaded.
#
# Called in the container from the top of the source tree:
#   s390x-userspace.sh deps            install build dependencies
#   s390x-userspace.sh build           build and install the userland
#   s390x-userspace.sh zstream-prep    create the base image for the
#                                      zstream raw check
#   s390x-userspace.sh zstream-raw DEV apply the test stream to DEV
#                                      (a loop device the runner set up
#                                      on the base image)
#   s390x-userspace.sh unit            run the unit tests
#   s390x-userspace.sh ztest SECONDS   run ztest for SECONDS
######################################################################

set -eu

DATA=.github/workflows/scripts/s390x-userspace
WORK="$PWD/.s390x-work"

# The base image is regenerated from this pattern, so only the stream
# and the expected checksums are stored.  The stream was made on x86
# with: zfs create -V 8m -o compression=on; write the base image;
# snapshot @a; zero 2M at 2M; write 1M of "changed data" lines at 5M;
# snapshot @b; zfs send -i @a.  It starts with two FREE records with
# nonzero offsets (8M, past the end of the volume, and 2M).
BASE_SIZE=8388608
BASE_SHA256=6ed17123d80960d0b12028ea521a8d59c8b3973b1961b5eff52333dfa20dab73
RESULT_SHA256=49ee8fc6989ba4bc1be170110fa57c0a1f641465590a9849e1f9b67d0dd74325

function base_image() {
  yes "OpenZFS zstream raw big-endian check: base image" | \
    head -c $BASE_SIZE > "$1"
  echo "$BASE_SHA256  $1" | sha256sum -c -
}

# Apply the stream to $1 and check the result.
function apply_stream() {
  local rc=0
  zstream raw "$1" "$WORK/incr.zsend" || rc=$?
  echo "zstream raw $1: exit status $rc"
  if echo "$RESULT_SHA256  $1" | sha256sum -c -; then
    [ $rc -eq 0 ] && return 0
  fi
  return 1
}

case "$1" in
deps)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    autoconf automake build-essential ca-certificates ccache file gawk \
    gdb libaio-dev libattr1-dev libblkid-dev libelf-dev libffi-dev \
    libssl-dev libtirpc-dev libtool libtool-bin libudev-dev pkg-config \
    python3 uuid-dev zlib1g-dev
  ;;
build)
  export PATH="/usr/lib/ccache:$PATH"
  ccache -z || true
  ./autogen.sh
  ./configure --with-config=user --enable-debug --disable-pyzfs \
    --prefix=/usr --sysconfdir=/etc --localstatedir=/var
  make -j"$(nproc)"
  make install
  ldconfig
  ccache -s || true
  zstream -h 2>&1 | head -1 || true
  ;;
zstream-prep)
  rm -rf "$WORK"
  mkdir -p "$WORK"
  gzip -dc $DATA/zstream-raw-incr.zsend.gz > "$WORK/incr.zsend"
  zstream dump -v "$WORK/incr.zsend" | grep '^FREE ' || true
  base_image "$WORK/file.img"
  cp "$WORK/file.img" "$WORK/dev.img"
  # A regular file does not use BLKSSZGET; check that path too.
  apply_stream "$WORK/file.img"
  ;;
zstream-raw)
  dev=$2
  [ -b "$dev" ] || { echo "$dev is not a block device"; exit 1; }
  echo "$BASE_SHA256  $dev" | sha256sum -c -
  apply_stream "$dev"
  ;;
unit)
  export PATH="/usr/lib/ccache:$PATH"
  make -j"$(nproc)" unit
  ;;
ztest)
  rm -rf "$WORK/ztest"
  mkdir -p "$WORK/ztest"
  ztest -V -T "$2" -f "$WORK/ztest"
  ;;
*)
  echo "unknown command: $1"
  exit 1
  ;;
esac
