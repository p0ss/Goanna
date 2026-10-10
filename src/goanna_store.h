// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// The local block store, docs/design/far-rendering-plan.md rung 5: every mapblock this
// client was sent, kept as the server serialised it, keyed by server, so
// the far tiers can draw what was seen after the server has stopped sending
// it. Full resolution, because the coarse chain is derived from it
// (goanna_lod.h) and the store then does not bake in a tier set.
//
// It draws nothing and decides nothing: it is a cache of data the server
// already chose to send this client. Whether the far tiers may read it
// beyond the live range is the server's grant (far_rendering over the
// goanna:v1 channel), read in GoannaClient.
//
// Format, one file per 16 by 16 by 16 blocks, "r.<x>.<y>.<z>.gbs":
//   magic "GOST", u32 version, u32 region size, u32 reserved
//   4096 index entries of 16 bytes: u32 offset, u32 length, u32 stamp
//   (seconds since the epoch), u8 serialisation version, 3 bytes pad
//   then the payloads, appended; a rewrite leaves the old bytes dead until
//   the file is compacted, which happens when dead exceeds live.
// The cap evicts whole region files, oldest written first.
//
// Threads: every method that reads or writes takes m_mutex, so any thread
// may call it (the small accessors below say where they do not). Three do.
// The session thread writes each block as it arrives
// (GoannaSession::onBlockData). The main thread writes edited blocks back
// when they are pruned or the session stops (saveBlockToStore), and asks
// for masks with the try methods, which never wait. The LodStorage worker
// reads payloads and primes region indices through the callbacks
// GoannaClient::lodStartStorage gives it, so the disk reads a far region
// needs happen off the main thread. Everything here is plain C stdio on
// purpose.

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "irrlichttypes_bloated.h"

namespace goanna {

// One server's block store. Owned by GoannaSession, opened in start() and
// closed in stop(); see the opening comment for which threads call it.
class BlockStore {
public:
    static constexpr int kRegionBlocks = 16; // blocks per axis per file
    static constexpr int kSlots = kRegionBlocks * kRegionBlocks * kRegionBlocks;

    ~BlockStore();
    // dir is the server's own directory, created if missing. cap_bytes is
    // the most the directory may hold before the oldest region files go.
    bool open(const std::string &dir, uint64_t cap_bytes);
    void close();
    bool isOpen() const { return !m_dir.empty(); }
    const std::string &directory() const { return m_dir; }

    void put(v3s16 bp, uint8_t ser_ver, const std::string &payload, uint32_t stamp);
    bool get(v3s16 bp, uint8_t &ser_ver, std::string &payload, uint32_t *stamp = nullptr,
            size_t max_bytes = 0);
    bool has(v3s16 bp);
    // Which blocks of a region exist: 4096 bits, slot = (z * 16 + y) * 16 + x
    // in block coordinates relative to the region. False if no such file.
    bool regionMask(v3s16 region, std::vector<uint8_t> &bits);
    // Main-thread lookup: never waits on disk or on a writer. False asks the
    // caller to prime this index on its I/O worker and retry later. A missing
    // region is a ready, empty mask, so it needs no disk access.
    bool tryRegionMask(v3s16 region, std::vector<uint8_t> &bits);
    bool tryHas(v3s16 bp, bool &present);

    static v3s16 regionOf(v3s16 bp);
    static int slotOf(v3s16 bp);

    // bytes() and blocksKnown() read their counters without the lock, so
    // render_stats never waits behind a disk write; the counters are atomics
    // for that, written under the lock. A figure one put behind is fine.
    // regions() takes no lock either but reads the table itself, so it is
    // only for before another thread uses the store (the log line after
    // open).
    uint64_t bytes() const { return m_bytes.load(std::memory_order_relaxed); }
    size_t regions() const { return m_regions.size(); }
    // Blocks in the region files whose indices have been read; a lower
    // bound on what the directory holds, exact once every region is touched.
    size_t blocksKnown() const { return m_blocks_known.load(std::memory_order_relaxed); }

private:
    struct Entry {
        uint32_t offset = 0, length = 0, stamp = 0;
        uint8_t ser_ver = 0;
    };
    struct Region {
        std::string path;
        FILE *f = nullptr;
        std::vector<Entry> index; // kSlots entries when loaded
        uint64_t file_size = 0;
        uint64_t live = 0; // bytes of payload still referenced
        uint32_t newest = 0;
        bool loaded = false;
        int filled = 0;
    };
    Region *regionFor(v3s16 region, bool create);
    bool loadIndex(Region &r);
    bool writeEntry(Region &r, int slot);
    void compact(Region &r, v3s16 rpos);
    void evictToCap();
    std::string pathFor(v3s16 region) const;

    // Guards everything below it: the open directory, the region table with
    // each region's FILE and index, and the writes of the byte and block
    // counts (read without it by bytes() and blocksKnown()). Held for
    // the whole of a disk read or write, which is why the main thread's per
    // frame lookups use the try methods. Its writes on prune and stop wait
    // for the lock like anyone else's.
    std::mutex m_mutex;
    std::string m_dir;
    uint64_t m_cap = 0;
    std::atomic<uint64_t> m_bytes{0};
    std::atomic<size_t> m_blocks_known{0};
    std::map<v3s16, Region> m_regions;
    int m_puts = 0;
};

} // namespace goanna
