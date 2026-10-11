# Upstream #19144: bit 2 set in random 32-bit words (PVE 7.0.14 / ZFS 2.4.4)

Reporter: Proxmox VE 9.2, kernel 7.0.14-14-pve then -16-pve, zfs 2.4.4-pve1,
non-ECC DDR5, Alder Lake-P. A guest pins host inodes through
`virtiofsd --cache=always`; zfs_arc_max 3.1 GiB made arc_prune run ~34/min.
Nine events in three weeks: 0 -> 1 on bit 2 of a 32-bit word.

## Upstream state (checked 2026-10-11)

| Ref | State | In 2.4.4? |
|---|---|---|
| #18715 mmap read beyond EOF | merged 2026-06-30 | yes (bc35c8106) |
| #18840 ARC invariant VERIFYs | merged 2026-07-28 | yes (eb808b3f4) |
| #18897 arc_release()/arc_read_done() race | merged 2026-08-06 (216de07d8) | no; in zfs-2.4.5-staging (eb011f2af) |
| #18968 arc_write_done() anon-in-hash window | merged 2026-08-27 (b0fff48dc) | no; in zfs-2.4.5-staging (57fbddf6b) |
| #18782 NULL deref in buf_hash_remove() | open | - |
| #18787, #18924 (zero-fill / zfs_fillpage underflow) | closed 2026-10-03 | - |
| #19266/#19275 zfs_prune batches (e95c55285) | merged 2026-10-08, master only | no |

No PR or issue references #19144. The only zfs_prune change since 2.4.4 is
e95c55285 (feed super_cache_scan in shrinker->batch chunks; fixes the zfs_zget
EAGAIN livelock #19266). It changes how many inodes are I_FREEING at once, not
locking or lifetimes. No prune/shrinker compat change for 6.x/7.0 in
master or zfs-2.4-release since 2.4.4.

## Code analysis

### The two candidate writers cannot produce 6 of the 9 events

Layouts from the BTF of the exact PVE kernel + zfs.ko (7.0.14-14-pve,
2.4.4-pve1; `pahole --btf_base /sys/kernel/btf/vmlinux /sys/kernel/btf/zfs`):

| field | offset | mod 8 |
|---|---|---|
| inode.i_state (I_LRU_ISOLATING = 1<<2) | 144 | 0 |
| arc_buf_hdr_t.b_flags (ARC_FLAG_PREFETCH = 1<<2) | 40 | 0 |
| arc_buf_t.b_flags | 24 | 0 |
| inode.i_data (address_space) | 368 | 0 |
| address_space.i_mmap (rb_root_cached) | 72 | 0 |
| znode_t.z_inode (zfs_znode_cache, 1104 B) | 496 | 0 |
| dnode_t (936 B) .dn_dirty_records[3].list_head.next | 424 | 0 |
| arc_buf_hdr_t.b_l1hdr.b_buf | 152 | 0 |

Slab objects are at least 8-byte aligned, so a stale-pointer store to either
candidate field always lands on an address that is 0 mod 8: the low half of a
64-bit word. Signature 1 (6 events: 4x arc_prune, 1x kswapd, 1x arc_evict)
has bit 34 set in a 64-bit NULL pointer (value 0x0000000400000000), i.e.
the flipped bit is in the 32-bit word at 4 mod 8. Neither writer can do that
with a correctly aligned stale pointer. Both could explain signature 2 and
signature 3 (low half), but not signature 1.

Signature 1, arc_evict case: arc_change_state+0x2b5 in the PVE zfs.ko is
`mov 0x18(%rdx),%eax` in the loop over `hdr->b_l1hdr.b_buf` / `buf->b_next`
reading `buf->b_flags` (objdump of /lib/modules/7.0.14-14-pve/zfs/zfs.ko),
so the bad 0x400000000 was hdr->b_l1hdr.b_buf or a buf->b_next.
Signature 1, evict case: RBX (mapping) = RDI - 0x48 (i_mmap at 72), so the
bad word is mapping->i_mmap.rb_root (or rb_leftmost) + 4.

Signature 2 decoded: dnode_t+424 is `dn_dirty_records[3].list_head.next`
(list_t is 24 bytes, array at 344). An empty list head points at itself
(...6290); +4 = ...6294. dnode_destroy() -> list_destroy() -> list_del() of
the head is what reports it from dbu_evict. Both events hit txg slot 3.

The two unanalysed panics (fault at ...b234 and ...657c) are also at 4 mod 8.

So the events fall in both 32-bit halves of 64-bit words. A single
fixed-offset software writer in 8-aligned objects cannot do that; a writer
with a variable index (bitmap/array) or a hardware fault on one data line of
a 32-bit DDR5 sub-channel (each 32-bit beat carries one aligned 4-byte word,
so a weak DQ2 sets bit 2 of words at both 0 and 4 mod 8) can. This is a
hypothesis, not tested.

### I_LRU_ISOLATING / zfs_prune (2.4.4 module/os/linux/zfs/zfs_vfsops.c:1141)

- I_LRU_ISOLATING has been bit 2 of a u32 i_state since Linux 6.12
  (v6.11: bit 19 of unsigned long; v6.12 and v6.17: `__I_LRU_ISOLATING 2`,
  `u32 i_state`). The reporter's earlier 6.17.13 kernel had the same layout
  and the same code. 7.0 only wraps i_state in `struct inode_state_flags` with
  accessors; inode_lru_isolate(), inode_pin/unpin_lru_isolating() and
  super_cache_scan() are unchanged from 6.17 (diffed fs/inode.c, fs/super.c).
- zfs_prune() runs from zpl_prune_sb() (zpl_super.c:367) holding s_umount
  for read (trylock), checks SB_DYING/SB_BORN, then calls
  super_cache_scan(), which takes s_umount shared again (trylock) and does
  exactly what kswapd's do_shrink_slab() does. The kernel's own
  shrinker refcount/RCU only protects the shrinker object; here the sb (and
  its shrinker) cannot be freed while s_umount is held. The kswapd
  instance of signature 1 shows the same fault without zfs_prune.
- inode_lru_isolate() sets I_LRU_ISOLATING under i_lock, drops the lock,
  invalidates pages, clears it under i_lock and wakes; evict() waits for it
  under i_lock (inode_wait_for_lru_isolating). No lost wakeup; no ZFS path
  frees an inode except via evict() -> destroy_inode() (zfs_inode_destroy,
  zfs_znode_os.c:383). zfs_zget()/zfs_prune_aliases()/zfs_resume_fs() take
  inode refs with igrab(), which tolerates I_LRU_ISOLATING.
- sc.memcg is NULL in zfs_prune(): only root-memcg LRU lists are walked.
  When virtiofsd's inodes are charged to a non-root memcg the scan finds
  nothing and zfs_prune_aliases() runs (igrab + d_prune_aliases + iput).
  Also safe.
- Minor: super_cache_scan() returns SHRINK_STOP (~0UL) when the nested
  trylock fails (e.g. a writer is queued on s_umount); zfs_prune() adds it to
  an int (-1) and then skips the zfs_prune_aliases() fallback. Not memory
  corruption.

### ARC stale header theory (b_flags |= ARC_FLAG_PREFETCH)

arc_access() (arc.c:5342 in 2.4.4) is the only non-L2 writer that sets
ARC_FLAG_PREFETCH alone. A header freed while still hashed (#18968's
arc_write_done() window, closed by b0fff48dc; #18897's arc_read_done()
error path, 216de07d8) would take that write later via buf_hash_find().
In 2.4.4 arc_hdr_destroy() VERIFYs b_hash_next == NULL (eb808b3f4), which
only catches a freed header that is not the last in its bucket.
Both fixes are in zfs-2.4.5-staging, not in 2.4.4. By the alignment argument
above this could at most explain signatures 2 and 3.

## Test environment

VM: Debian 13 genericcloud (UEFI, 8 GB, 4 vCPUs, two 10 GB disks as a mirror) + Proxmox no-subscription repo,
proxmox-kernel-7.0.14-14-pve-signed 7.0.14-14 (uname 7.0.14-14-pve),
zfsutils-linux/zfs-zed/libs 2.4.4-pve1, kmod `v2.4.4-pve1`
(/sys/module/zfs/version 2.4.4-pve1). Keyring proxmox-archive-keyring-trixie.gpg,
sha512 90eb7f05...918a.

Workload: stress.sh + pinner.py + mmapper.py (see headers).

## Runs

| Run | Module | Kernel options | Duration | arc_prune calls | pginodesteal | Result |
|---|---|---|---|---|---|---|
| A (2026-10-11 11:14-14:14 UTC) | stock zfs-kmod 2.4.4-pve1 | default | 3 h | 15,284,146 (reporter: ~34/min, ~200k in 4 days) | 239,711 (+12,744 kswapd) | no oops, WARN, list corruption or pool error; `zpool status -x` healthy |
| B (2026-10-11 14:20-17:21 UTC) | zfs-2.4.4 tag 71a9f9578, `--enable-debug` (ASSERTs on) | slub_debug=FZPU on zfs_znode_cache, dnode_t, arc_buf_hdr_t_full, arc_buf_t, dmu_buf_impl_t, sa_cache; kfence.sample_interval=100 | 3 h | 15,822,786 | 430,135 (+2,408 kswapd) | no ASSERT/VERIFY, no SLUB poison/redzone report, no KFENCE report, no oops/WARN; pool healthy |

Not reproduced. After run B the VM was switched back to the stock modules
(debug_setup.sh off) and shut down.

## The "probably fixed by 216de07d8/b0fff48dc" triage note

- 216de07d8 (#18897) closes two windows. In the first, arc_release() runs on a
  header whose read is IO_IN_PROGRESS (more raw data being read while
  decrypted data stays in the buf), which needs an encrypted dataset. The
  reporter has `feature@encryption` enabled, not active. The second is
  arc_read_done() moving the header to anon on a read error. The reporter
  had one double-sided mirror checksum error, but when it happened relative
  to the crashes is not known.
- b0fff48dc (#18968) needs no encryption or error, only arc_buf_destroy()
  racing arc_write_done() on an anon buffer. Its commit message says the
  window is not proven to occur.
- Either way a stale `b_flags |= ARC_FLAG_PREFETCH` lands at 0 mod 8 and
  cannot produce signature 1. "Probably fixed" overstates it: those fixes
  could account for at most 3 of the 9 events.

## Noble

Not run, because nothing reproduced and no mechanism was found to test.
Kernel facts: Noble GA 6.8 (6.8.0-111/136/146 headers on the host) has
I_LRU_ISOLATING backported as bit 19 of an `unsigned long` i_state, so an
I_LRU_ISOLATING store there could never be "bit 2 of a 32-bit word". The
Noble HWE 7.0 kernel has the upstream 7.0 layout (bit 2 of a u32), the same
as the reporter's kernel.

## Related upstream

#16324 (arc_prune oops/list_del corruption under Docker, 85 comments): the
zfs_prune sb-lifetime UAF there was fixed by #16770, which 2.4.4 has
(zpl_prune_sb s_umount trylock + SB_DYING). Out-of-tree branch
snajpa/zfs `loopia` carries many unrelated stability patches; not reviewed.

pginodesteal counts pages dropped by inode_lru_isolate()'s I_LRU_ISOLATING
pin path outside kswapd, i.e. the pin path ran ~240k times under zfs_prune().
stock_arcstats.log: per-minute arc_prune/size/dnode_size samples of run A.
