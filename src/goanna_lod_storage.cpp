// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_lod_storage.h"

#include <algorithm>
#include <cstring>
#include <ctime>
#include <stdexcept>
#include <zstd.h>

namespace goanna {

uint64_t terrainFingerprint(const std::string &bytes) {
    uint64_t h = 14695981039346656037ull;
    for (unsigned char c : bytes) {
        h ^= c;
        h *= 1099511628211ull;
    }
    return h;
}

namespace {
// Fixed bounds precede every allocation. The schema stores fields explicitly,
// never compiler struct layouts or pointers. Change the version when the
// reducer's meaning changes, even if the byte layout remains compatible.
constexpr uint32_t kSchema = 4;  // materials represent visible faces, not buried opaque nodes
constexpr size_t kMaxRecord = 256 * 1024;
constexpr size_t kMaxSummary = 1024 * 1024;
struct Writer {
    std::string bytes;
    void put(uint64_t v, int n) {
        for (int i = 0; i < n; ++i) bytes.push_back((char)(v >> (i * 8)));
    }
    void cell(const LodLevel::Cell &c) {
        for (auto v : c.face) put(v, 2);
        for (auto v : c.param2) put(v, 1);
        put(c.day, 1); put(c.night, 1); put(c.flags, 1); put(c.top, 1);
        put(c.coverage, 1);
        put(c.liquid, 2); put(c.liquid_param2, 1); put(c.liquid_top, 1);
    }
};
struct Reader {
    const std::string &bytes;
    size_t at = 0;
    uint64_t get(int n) {
        if (at + n > bytes.size()) throw std::runtime_error("short terrain record");
        uint64_t v = 0;
        for (int i = 0; i < n; ++i) v |= (uint64_t)(uint8_t)bytes[at++] << (i * 8);
        return v;
    }
    LodLevel::Cell cell(int edge) {
        LodLevel::Cell c;
        for (auto &v : c.face) v = (content_t)get(2);
        for (auto &v : c.param2) v = (uint8_t)get(1);
        c.day = get(1); c.night = get(1); c.flags = get(1); c.top = get(1);
        c.coverage = get(1);
        c.liquid = get(2); c.liquid_param2 = get(1); c.liquid_top = get(1);
        if (c.flags > 63 || c.top > edge || c.liquid_top > edge)
            throw std::runtime_error("invalid terrain cell");
        return c;
    }
};

std::string packSummary(const std::string &message, uint64_t definitions) {
    if (message.empty() || message.size() > kMaxSummary) return {};
    std::string compressed(ZSTD_compressBound(message.size()), '\0');
    size_t n = ZSTD_compress(compressed.data(), compressed.size(), message.data(), message.size(), 1);
    if (ZSTD_isError(n)) return {};
    compressed.resize(n);
    Writer header;
    header.bytes = "GLDS";
    header.put(2, 4); header.put(definitions, 8); header.put(message.size(), 4);
    header.put(terrainFingerprint(compressed), 8);
    return header.bytes + compressed;
}
std::string unpackSummary(const std::string &record, uint64_t definitions) {
    if (record.size() < 28 || record.compare(0, 4, "GLDS")) return {};
    Reader r{record, 4};
    if (r.get(4) != 2 || r.get(8) != definitions) return {};
    const size_t size = r.get(4);
    const uint64_t hash = r.get(8);
    if (!size || size > kMaxSummary || terrainFingerprint(record.substr(r.at)) != hash) return {};
    std::string message(size, '\0');
    size_t n = ZSTD_decompress(message.data(), size, record.data() + r.at, record.size() - r.at);
    if (ZSTD_isError(n) || n != size) return {};
    return message;
}
}

std::string encodeLodRecord(const BlockLodChain &ch, uint64_t definitions, uint64_t source) {
    Writer w;
    w.put((ch.summary ? 1 : 0) | (ch.surface_shell ? 2 : 0), 1);
    for (int l = 0; l < BlockLodChain::kLevels; ++l) {
        const auto &lv = ch.level[l];
        const size_t n = 16 >> l;
        if ((!lv.cells.empty() && (lv.cells.size() != n*n*n || lv.cell != (1 << l))) ||
                (!lv.terrain.empty() && lv.terrain.size() != n*n))
            return {};
        w.put(lv.cells.size(), 2);
        for (const auto &c : lv.cells) w.cell(c);
        w.put(lv.terrain.size(), 2);
        for (auto h : lv.terrain) w.put(h, 1);
    }
    w.put(ch.fine_available, 1);
    for (auto v : ch.fine_filled) w.put(v, 8);
    for (auto v : ch.fine_occludes) w.put(v, 8);
    if (ch.fine_records.size() > 4096) return {};
    w.put(ch.fine_records.size(), 2);
    for (const auto &r : ch.fine_records) {
        w.put(r.index, 2); w.cell(r.cell);
    }
    if (w.bytes.size() > kMaxRecord) return {};
    std::string compressed(ZSTD_compressBound(w.bytes.size()), '\0');
    size_t n = ZSTD_compress(compressed.data(), compressed.size(), w.bytes.data(), w.bytes.size(), 1);
    if (ZSTD_isError(n)) return {};
    compressed.resize(n);
    Writer header;
    header.bytes = "GLDC";
    header.put(kSchema, 4); header.put(definitions, 8); header.put(source, 8);
    header.put(w.bytes.size(), 4); header.put(terrainFingerprint(compressed), 8);
    return header.bytes + compressed;
}

std::shared_ptr<BlockLodChain> decodeLodRecord(
        const std::string &bytes, uint64_t definitions, uint64_t source) {
    try {
        if (bytes.size() < 36 || bytes.size() > kMaxRecord || bytes.compare(0, 4, "GLDC"))
            return {};
        Reader header{bytes, 4};
        if (header.get(4) != kSchema || header.get(8) != definitions || header.get(8) != source)
            return {};
        const size_t size = header.get(4);
        const uint64_t hash = header.get(8);
        if (!size || size > kMaxRecord) return {};
        if (terrainFingerprint(bytes.substr(header.at)) != hash) return {};
        std::string unpacked(size, '\0');
        size_t got = ZSTD_decompress(unpacked.data(), size, bytes.data() + header.at,
                bytes.size() - header.at);
        if (ZSTD_isError(got) || got != size) return {};
        Reader r{unpacked};
        auto ch = std::make_shared<BlockLodChain>();
        const int summary = r.get(1);
        if (summary > 3) return {};
        ch->summary = (summary & 1) != 0;
        ch->surface_shell = (summary & 2) != 0;
        ch->stored = true;
        for (int l = 0; l < BlockLodChain::kLevels; ++l) {
            auto &lv = ch->level[l];
            const int n = 16 >> l;
            size_t count = r.get(2);
            if (count != 0 && count != (size_t)n*n*n) return {};
            if (count) { lv.cell = 1 << l; lv.n = n; }
            lv.cells.reserve(count);
            for (size_t i = 0; i < count; ++i) lv.cells.push_back(r.cell(1 << l));
            count = r.get(2);
            if (count != 0 && (count != (size_t)n*n || lv.cells.empty())) return {};
            for (size_t i = 0; i < count; ++i) {
                uint8_t h = r.get(1);
                if (h > 16) return {};
                lv.terrain.push_back(h);
            }
        }
        const int fine = r.get(1);
        if (fine > 1) return {};
        ch->fine_available = fine;
        for (auto &v : ch->fine_filled) v = r.get(8);
        for (auto &v : ch->fine_occludes) v = r.get(8);
        const size_t count = r.get(2);
        if (count > 4096 || (!fine && count)) return {};
        for (size_t i = 0; i < count; ++i) {
            BlockLodChain::FineRecord rec;
            rec.index = r.get(2);
            if (rec.index >= 4096 || (i && rec.index <= ch->fine_records.back().index)) return {};
            rec.cell = r.cell(1);
            ch->fine_record_mask[rec.index >> 6] |= uint64_t(1) << (rec.index & 63);
            ch->fine_records.push_back(rec);
        }
        uint16_t base = 0;
        for (int i = 0; i < 64; ++i) {
            ch->fine_record_base[i] = base;
            uint64_t mask = ch->fine_record_mask[i];
            while (mask) { ++base; mask &= mask - 1; }
        }
        if (r.at != unpacked.size()) return {};
        return ch;
    } catch (const std::exception &) {
        return {};
    }
}

void LodStorage::start(std::string directory, uint64_t definitions, Load load, Build build, Prime prime) {
    stop();
    std::lock_guard<std::mutex> lock(m_mutex);
    m_running = true;
    m_stats = Stats();
    m_thread = std::thread(&LodStorage::work, this, std::move(directory), definitions,
            std::move(load), std::move(build), std::move(prime));
}

void LodStorage::stop() {
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_running = false;
        m_queue.clear();
        m_ready.clear();
    }
    m_wake.notify_all();
    if (m_thread.joinable()) m_thread.join();
}

bool LodStorage::running() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_running;
}

bool LodStorage::request(v3s16 pos, uint64_t ticket, int priority, LiveBuild live) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_running) return false;
    for (auto &j : m_queue) {
        if (!j.prime && !j.summary && j.pos == pos) {
            j = {pos, ticket, priority, false, std::move(live)};
            return true;
        }
    }
    if (m_queue.size() >= 128) { ++m_stats.rejected; return false; }
    m_queue.push_back({pos, ticket, priority, false, std::move(live)});
    m_wake.notify_one();
    return true;
}

void LodStorage::prime(v3s16 region) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_running || m_queue.size() >= 128) return;
    for (const auto &j : m_queue) if (j.prime && j.pos == region) return;
    m_queue.push_back({region, 0, 0, true, {}});
    m_wake.notify_one();
}

bool LodStorage::requestSummary(v3s16 origin, uint64_t ticket, int priority) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_running || m_queue.size() >= 128) return false;
    int summaries = 0;
    for (auto &j : m_queue) {
        summaries += j.summary;
        if (j.summary && j.message.empty() && j.pos == origin) {
            j.ticket = ticket; j.priority = priority;
            return true;
        }
    }
    if (summaries >= 16) return false;
    Job job; job.pos = origin; job.ticket = ticket; job.priority = priority; job.summary = true;
    m_queue.push_back(std::move(job));
    m_wake.notify_one();
    return true;
}

bool LodStorage::saveSummary(v3s16 origin, std::string message) {
    if (message.empty() || message.size() > kMaxSummary) return false;
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_running) return false;
    int summaries = 0;
    for (auto &j : m_queue) {
        summaries += j.summary;
        if (j.summary && !j.message.empty() && j.pos == origin) {
            j.message = std::move(message);
            return true;
        }
    }
    if (m_queue.size() >= 128 || summaries >= 16) return false;
    Job job; job.pos = origin; job.summary = true; job.message = std::move(message);
    job.priority = 100000; // cache maintenance cannot lead missing terrain
    m_queue.push_back(std::move(job));
    m_wake.notify_one();
    return true;
}

bool LodStorage::next(Result &result) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_ready.empty()) return false;
    result = std::move(m_ready.front());
    m_ready.pop_front();
    m_wake.notify_one();
    return true;
}

LodStorage::Stats LodStorage::stats() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    Stats s = m_stats;
    s.queued = (int)m_queue.size(); s.ready = (int)m_ready.size();
    return s;
}

void LodStorage::clear() {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_queue.clear(); m_ready.clear();
    m_wake.notify_one();
}

void LodStorage::work(std::string directory, uint64_t definitions, Load load, Build build, Prime prime) {
    BlockStore cache;
    const bool disk = !directory.empty() && cache.open(directory, 512ull << 20);
    BlockStore summaries;
    const bool summary_disk = !directory.empty() && summaries.open(directory + "/summaries", 128ull << 20);
    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lock(m_mutex);
            m_wake.wait(lock, [&] { return !m_running || (!m_queue.empty() && m_ready.size() < 32); });
            if (!m_running) break;
            // Let an old request advance even when new nearby work keeps
            // arriving. A bounded queue has at most 128 requests to age past.
            auto best = m_queue.begin();
            for (auto it = m_queue.begin(); it != m_queue.end(); ++it) {
                if (it->priority < best->priority) best = it;
                it->priority = std::max(-1000000000, it->priority - 4096);
            }
            job = std::move(*best); m_queue.erase(best);
            m_stats.active = 1;
        }
        Result result{job.pos, job.ticket, {}};
        bool hit = false, miss = false, built = false, error = false;
        bool summary_hit = false, summary_write = false;
        try {
            if (job.summary) {
                result.summary = true;
                if (summary_disk && !job.message.empty()) {
                    auto record = packSummary(job.message, definitions);
                    if (!record.empty()) {
                        summaries.put(job.pos, 1, record, (uint32_t)time(nullptr));
                        summary_write = true;
                    }
                } else if (summary_disk) {
                    uint8_t version = 0;
                    std::string record;
                    if (summaries.get(job.pos, version, record, nullptr, kMaxSummary + 1024))
                        result.message = unpackSummary(record, definitions);
                    summary_hit = !result.message.empty();
                }
            } else if (job.prime) {
                if (prime) prime(job.pos);
                result.primed = true;
            } else if (job.live) {
                result.chain = job.live();
                built = result.chain != nullptr;
            } else {
                std::string source;
                if (load && load(job.pos, source)) {
                    const uint64_t revision = terrainFingerprint(source);
                    uint8_t version = 0;
                    std::string record;
                    if (disk && cache.get(job.pos, version, record, nullptr, kMaxRecord))
                        result.chain = decodeLodRecord(record, definitions, revision);
                    hit = result.chain != nullptr;
                    if (!hit) {
                        miss = true;
                        auto chain = build(job.pos, source);
                        if (chain) {
                            chain->stored = true;
                            if (disk) {
                                record = encodeLodRecord(*chain, definitions, revision);
                                if (!record.empty()) cache.put(job.pos, 1, record, (uint32_t)time(nullptr));
                            }
                            result.chain = std::move(chain);
                            built = true;
                        }
                    }
                }
            }
        } catch (const std::exception &) { error = true; }
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_stats.active = 0;
            m_stats.hits += hit; m_stats.misses += miss; m_stats.built += built;
            m_stats.summary_hits += summary_hit; m_stats.summary_writes += summary_write;
            m_stats.errors += error;
            if (m_running && !(job.summary && !job.message.empty()))
                m_ready.push_back(std::move(result));
        }
    }
}

} // namespace goanna
