#!/usr/bin/env python3
# mmapper.py END_EPOCH: shared-mmap writers plus truncates on /tank/mm, so that
# inodes reach zpl_evict_inode() -> truncate_setsize() with i_mmap populated
# recently, and page cache keeps being created and dropped.
import mmap
import os
import random
import sys
import time

end = int(sys.argv[1])
names = [f"/tank/mm/m{i:03d}" for i in range(400)]
random.seed(7)
n = 0
while time.time() < end:
    fn = random.choice(names)
    try:
        fd = os.open(fn, os.O_RDWR)
    except OSError:
        continue
    try:
        sz = 4 << 20
        os.ftruncate(fd, sz)
        m = mmap.mmap(fd, sz)
        for off in range(0, sz, 4096 * random.randint(1, 16)):
            m[off] = (m[off] + 1) & 0xff
        if random.random() < 0.3:
            m.flush()
        m.close()
        if random.random() < 0.2:
            os.ftruncate(fd, random.randint(0, sz))
    finally:
        os.close(fd)
    n += 1
    if n % 2000 == 0:
        print(time.strftime("%T"), "ops", n, flush=True)
