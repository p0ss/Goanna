// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// The local block store, docs/far-rendering.md rung 5: every mapblock this
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
// Thread safe: writes come from the session thread, reads from the main
// thread, under one mutex. Everything here is plain C stdio on purpose.

#include <cstdint>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "irrlichttypes_bloated.h"

namespace goanna {

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

    void put(v3s16 bp, uint8_t ser_ver, const std::string &payload, uint32_t stamp);
    bool get(v3s16 bp, uint8_t &ser_ver, std::string &payload, uint32_t *stamp = nullptr);
    bool has(v3s16 bp);
    // Which blocks of a region exist: 4096 bits, slot = (z * 16 + y) * 16 + x
    // in block coordinates relative to the region. False if no such file.
    bool regionMask(v3s16 region, std::vector<uint8_t> &bits);

    static v3s16 regionOf(v3s16 bp);
    static int slotOf(v3s16 bp);

    uint64_t bytes() const { return m_bytes; }
    size_t regions() const { return m_regions.size(); }
    // Blocks in the region files whose indices have been read; a lower
    // bound on what the directory holds, exact once every region is touched.
    size_t blocksKnown() const { return m_blocks_known; }

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

    std::mutex m_mutex;
    std::string m_dir;
    uint64_t m_cap = 0;
    uint64_t m_bytes = 0;
    size_t m_blocks_known = 0;
    std::map<v3s16, Region> m_regions;
    int m_puts = 0;
};

} // namespace goanna
