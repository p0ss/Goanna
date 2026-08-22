// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_store.h"

#include <algorithm>
#include <cstring>
#include <filesystem>

namespace goanna {

namespace {

const char kMagic[4] = {'G', 'O', 'S', 'T'};
const uint32_t kVersion = 1;
const size_t kHeader = 16;
const size_t kEntry = 16;
const size_t kIndexBytes = kHeader + (size_t)BlockStore::kSlots * kEntry;

inline void put32(uint8_t *p, uint32_t v) {
    p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; p[2] = (v >> 16) & 0xff; p[3] = (v >> 24) & 0xff;
}
inline uint32_t get32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
inline int fdiv(int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }

} // namespace

BlockStore::~BlockStore() { close(); }

v3s16 BlockStore::regionOf(v3s16 bp) {
    return v3s16(fdiv(bp.X, kRegionBlocks), fdiv(bp.Y, kRegionBlocks), fdiv(bp.Z, kRegionBlocks));
}

int BlockStore::slotOf(v3s16 bp) {
    const int x = bp.X - regionOf(bp).X * kRegionBlocks;
    const int y = bp.Y - regionOf(bp).Y * kRegionBlocks;
    const int z = bp.Z - regionOf(bp).Z * kRegionBlocks;
    return (z * kRegionBlocks + y) * kRegionBlocks + x;
}

std::string BlockStore::pathFor(v3s16 region) const {
    return m_dir + "/r." + std::to_string(region.X) + "." + std::to_string(region.Y) + "." +
            std::to_string(region.Z) + ".gbs";
}

bool BlockStore::open(const std::string &dir, uint64_t cap_bytes) {
    close();
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    if (ec)
        return false;
    std::lock_guard<std::mutex> lk(m_mutex);
    m_dir = dir;
    m_cap = cap_bytes;
    m_bytes = 0;
    m_blocks_known = 0;
    // Index what is there: names and sizes only, the indices load on use.
    for (auto it = std::filesystem::directory_iterator(dir, ec);
            !ec && it != std::filesystem::directory_iterator(); it.increment(ec)) {
        const std::string name = it->path().filename().string();
        if (name.size() < 7 || name.compare(0, 2, "r.") != 0 ||
                name.compare(name.size() - 4, 4, ".gbs") != 0)
            continue;
        int x, y, z;
        if (sscanf(name.c_str(), "r.%d.%d.%d.gbs", &x, &y, &z) != 3)
            continue;
        Region r;
        r.path = it->path().string();
        r.file_size = it->file_size(ec);
        m_bytes += r.file_size;
        m_regions[v3s16(x, y, z)] = r;
    }
    return true;
}

void BlockStore::close() {
    std::lock_guard<std::mutex> lk(m_mutex);
    for (auto &kv : m_regions)
        if (kv.second.f) {
            fclose(kv.second.f);
            kv.second.f = nullptr;
        }
    m_regions.clear();
    m_dir.clear();
    m_bytes = 0;
}

bool BlockStore::loadIndex(Region &r) {
    if (r.loaded)
        return true;
    r.index.assign(kSlots, Entry());
    r.live = 0;
    r.filled = 0;
    r.newest = 0;
    if (!r.f) {
        r.f = fopen(r.path.c_str(), "r+b");
        if (!r.f) {
            // new file: header and empty index
            r.f = fopen(r.path.c_str(), "w+b");
            if (!r.f)
                return false;
            std::vector<uint8_t> hdr(kIndexBytes, 0);
            memcpy(hdr.data(), kMagic, 4);
            put32(hdr.data() + 4, kVersion);
            put32(hdr.data() + 8, kRegionBlocks);
            if (fwrite(hdr.data(), 1, hdr.size(), r.f) != hdr.size())
                return false;
            fflush(r.f);
            r.file_size = kIndexBytes;
            m_bytes += kIndexBytes;
            r.loaded = true;
            return true;
        }
    }
    std::vector<uint8_t> hdr(kIndexBytes);
    fseek(r.f, 0, SEEK_SET);
    if (fread(hdr.data(), 1, hdr.size(), r.f) != hdr.size() || memcmp(hdr.data(), kMagic, 4) != 0 ||
            get32(hdr.data() + 4) != kVersion || get32(hdr.data() + 8) != (uint32_t)kRegionBlocks) {
        // Not ours, or damaged: start again rather than read garbage as
        // terrain. The old bytes are dropped with the file.
        fclose(r.f);
        m_bytes -= std::min<uint64_t>(m_bytes, r.file_size);
        r.f = fopen(r.path.c_str(), "w+b");
        if (!r.f)
            return false;
        std::fill(hdr.begin(), hdr.end(), 0);
        memcpy(hdr.data(), kMagic, 4);
        put32(hdr.data() + 4, kVersion);
        put32(hdr.data() + 8, kRegionBlocks);
        fwrite(hdr.data(), 1, hdr.size(), r.f);
        fflush(r.f);
        r.file_size = kIndexBytes;
        m_bytes += kIndexBytes;
        r.loaded = true;
        return true;
    }
    for (int i = 0; i < kSlots; ++i) {
        const uint8_t *e = hdr.data() + kHeader + (size_t)i * kEntry;
        Entry &en = r.index[i];
        en.offset = get32(e);
        en.length = get32(e + 4);
        en.stamp = get32(e + 8);
        en.ser_ver = e[12];
        if (en.length) {
            r.live += en.length;
            ++r.filled;
            r.newest = std::max(r.newest, en.stamp);
        }
    }
    fseek(r.f, 0, SEEK_END);
    r.file_size = (uint64_t)ftell(r.f);
    r.loaded = true;
    m_blocks_known += (size_t)r.filled; // counted as indices load, so a lower bound
    return true;
}

bool BlockStore::writeEntry(Region &r, int slot) {
    uint8_t e[kEntry] = {0};
    const Entry &en = r.index[slot];
    put32(e, en.offset);
    put32(e + 4, en.length);
    put32(e + 8, en.stamp);
    e[12] = en.ser_ver;
    fseek(r.f, (long)(kHeader + (size_t)slot * kEntry), SEEK_SET);
    return fwrite(e, 1, kEntry, r.f) == kEntry;
}

BlockStore::Region *BlockStore::regionFor(v3s16 region, bool create) {
    auto it = m_regions.find(region);
    if (it == m_regions.end()) {
        if (!create)
            return nullptr;
        Region r;
        r.path = pathFor(region);
        it = m_regions.emplace(region, r).first;
    }
    Region &r = it->second;
    if (!loadIndex(r))
        return nullptr;
    // Bound open file handles: close the others' handles but keep their
    // indices, they reopen on the next touch.
    int open_count = 0;
    for (auto &kv : m_regions)
        if (kv.second.f)
            ++open_count;
    if (open_count > 48) {
        for (auto &kv : m_regions) {
            if (&kv.second == &r || !kv.second.f)
                continue;
            fclose(kv.second.f);
            kv.second.f = nullptr;
            if (--open_count <= 32)
                break;
        }
    }
    if (!r.f) {
        r.f = fopen(r.path.c_str(), "r+b");
        if (!r.f)
            return nullptr;
    }
    return &r;
}

void BlockStore::put(v3s16 bp, uint8_t ser_ver, const std::string &payload, uint32_t stamp) {
    if (payload.empty() || payload.size() > 0x7fffffffu)
        return;
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_dir.empty())
        return;
    Region *r = regionFor(regionOf(bp), true);
    if (!r)
        return;
    const int slot = slotOf(bp);
    Entry &en = r->index[slot];
    if (en.length) {
        r->live -= std::min<uint64_t>(r->live, en.length);
    } else {
        ++r->filled;
        ++m_blocks_known;
    }
    fseek(r->f, 0, SEEK_END);
    const long at = ftell(r->f);
    if (at < 0 || fwrite(payload.data(), 1, payload.size(), r->f) != payload.size())
        return;
    en.offset = (uint32_t)at;
    en.length = (uint32_t)payload.size();
    en.stamp = stamp;
    en.ser_ver = ser_ver;
    writeEntry(*r, slot);
    fflush(r->f);
    r->file_size = (uint64_t)at + payload.size();
    r->live += payload.size();
    r->newest = std::max(r->newest, stamp);
    m_bytes += payload.size();
    // Rewrites leave dead bytes behind; fold them once they outweigh the
    // live ones and the file is big enough to care about.
    const uint64_t dead = r->file_size > kIndexBytes + r->live ? r->file_size - kIndexBytes - r->live : 0;
    if (dead > r->live && dead > (1u << 20))
        compact(*r, regionOf(bp));
    if (++m_puts % 64 == 0)
        evictToCap();
}

void BlockStore::compact(Region &r, v3s16 rpos) {
    // Copy every live payload into a fresh file beside the old one, then
    // swap the names. A crash mid way leaves the old file intact.
    const std::string tmp = r.path + ".tmp";
    FILE *out = fopen(tmp.c_str(), "w+b");
    if (!out)
        return;
    std::vector<uint8_t> hdr(kIndexBytes, 0);
    memcpy(hdr.data(), kMagic, 4);
    put32(hdr.data() + 4, kVersion);
    put32(hdr.data() + 8, kRegionBlocks);
    fwrite(hdr.data(), 1, hdr.size(), out);
    std::vector<Entry> fresh(kSlots);
    std::string buf;
    uint64_t pos = kIndexBytes;
    for (int i = 0; i < kSlots; ++i) {
        const Entry &en = r.index[i];
        if (!en.length)
            continue;
        buf.resize(en.length);
        fseek(r.f, (long)en.offset, SEEK_SET);
        if (fread(&buf[0], 1, en.length, r.f) != en.length)
            continue;
        fwrite(buf.data(), 1, en.length, out);
        fresh[i] = en;
        fresh[i].offset = (uint32_t)pos;
        pos += en.length;
    }
    for (int i = 0; i < kSlots; ++i) {
        uint8_t e[kEntry] = {0};
        put32(e, fresh[i].offset);
        put32(e + 4, fresh[i].length);
        put32(e + 8, fresh[i].stamp);
        e[12] = fresh[i].ser_ver;
        fseek(out, (long)(kHeader + (size_t)i * kEntry), SEEK_SET);
        fwrite(e, 1, kEntry, out);
    }
    fclose(out);
    fclose(r.f);
    r.f = nullptr;
    std::error_code ec;
    std::filesystem::rename(tmp, r.path, ec);
    if (ec) {
        std::filesystem::remove(tmp, ec);
        r.loaded = false; // reload from the untouched old file
        return;
    }
    m_bytes -= std::min<uint64_t>(m_bytes, r.file_size);
    m_bytes += pos;
    r.file_size = pos;
    r.index = fresh;
    r.f = fopen(r.path.c_str(), "r+b");
    (void)rpos;
}

void BlockStore::evictToCap() {
    if (!m_cap || m_bytes <= m_cap)
        return;
    // Oldest region files first, by the newest block each holds when the
    // index is loaded and by file time otherwise.
    std::vector<std::pair<uint64_t, v3s16>> order;
    for (auto &kv : m_regions) {
        uint64_t key;
        if (kv.second.loaded) {
            key = kv.second.newest;
        } else {
            std::error_code ec;
            auto t = std::filesystem::last_write_time(kv.second.path, ec);
            key = ec ? 0 : (uint64_t)t.time_since_epoch().count();
        }
        order.emplace_back(key, kv.first);
    }
    std::sort(order.begin(), order.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
    for (const auto &o : order) {
        if (m_bytes <= m_cap)
            break;
        auto it = m_regions.find(o.second);
        if (it == m_regions.end())
            continue;
        if (it->second.f)
            fclose(it->second.f);
        std::error_code ec;
        std::filesystem::remove(it->second.path, ec);
        m_bytes -= std::min<uint64_t>(m_bytes, it->second.file_size);
        m_blocks_known -= std::min<size_t>(m_blocks_known, (size_t)it->second.filled);
        m_regions.erase(it);
    }
}

bool BlockStore::get(v3s16 bp, uint8_t &ser_ver, std::string &payload, uint32_t *stamp) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_dir.empty())
        return false;
    Region *r = regionFor(regionOf(bp), false);
    if (!r)
        return false;
    const Entry &en = r->index[slotOf(bp)];
    if (!en.length)
        return false;
    payload.resize(en.length);
    fseek(r->f, (long)en.offset, SEEK_SET);
    if (fread(&payload[0], 1, en.length, r->f) != en.length) {
        payload.clear();
        return false;
    }
    ser_ver = en.ser_ver;
    if (stamp)
        *stamp = en.stamp;
    return true;
}

bool BlockStore::has(v3s16 bp) {
    std::lock_guard<std::mutex> lk(m_mutex);
    if (m_dir.empty())
        return false;
    Region *r = regionFor(regionOf(bp), false);
    return r && r->index[slotOf(bp)].length != 0;
}

bool BlockStore::regionMask(v3s16 region, std::vector<uint8_t> &bits) {
    std::lock_guard<std::mutex> lk(m_mutex);
    bits.assign(kSlots / 8, 0);
    if (m_dir.empty())
        return false;
    Region *r = regionFor(region, false);
    if (!r)
        return false;
    for (int i = 0; i < kSlots; ++i)
        if (r->index[i].length)
            bits[i >> 3] |= (uint8_t)(1u << (i & 7));
    return true;
}

} // namespace goanna
