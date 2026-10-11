#!/usr/bin/env python3
# pinner.py END_EPOCH: keep ~40k ZFS files open (like virtiofsd --cache=always
# holding host inodes), mmap+read a share of them, and rotate the pinned set
# so that released inodes land on the inode LRU with page cache attached.
import mmap
import os
import random
import sys
import time

end = int(sys.argv[1])
files = []
for root, _, names in os.walk("/tank/small"):
    files.extend(os.path.join(root, n) for n in names)
for root, _, names in os.walk("/tank/big"):
    files.extend(os.path.join(root, n) for n in names)
random.seed(19144)
pinned = {}
maps = {}
TARGET = 40000
rounds = 0
while time.time() < end:
    # release a random tenth
    for fn in random.sample(list(pinned), min(len(pinned), TARGET // 10)):
        m = maps.pop(fn, None)
        if m is not None:
            m.close()
        os.close(pinned.pop(fn))
    # pin new ones up to TARGET
    while len(pinned) < TARGET:
        fn = random.choice(files)
        if fn in pinned:
            continue
        try:
            fd = os.open(fn, os.O_RDONLY)
        except OSError:
            continue
        pinned[fn] = fd
        if random.random() < 0.15:
            try:
                sz = os.fstat(fd).st_size
                if sz:
                    m = mmap.mmap(fd, sz, prot=mmap.PROT_READ)
                    _ = m[0] + m[sz - 1]
                    maps[fn] = m
            except (OSError, ValueError):
                pass
        elif random.random() < 0.3:
            os.pread(fd, 65536, 0)
    rounds += 1
    if rounds % 20 == 0:
        print(time.strftime("%T"), "round", rounds, "pinned", len(pinned),
              "mapped", len(maps), flush=True)
    time.sleep(2)
