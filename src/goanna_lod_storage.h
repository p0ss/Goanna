// SPDX-License-Identifier: LGPL-2.1-or-later
// Prepared terrain records and a bounded background reader. No Godot state.
#pragma once

#include "goanna_lod.h"
#include "goanna_store.h"

#include <condition_variable>
#include <deque>
#include <functional>
#include <string>
#include <thread>

namespace goanna {

uint64_t terrainFingerprint(const std::string &bytes);
std::string encodeLodRecord(const BlockLodChain &chain, uint64_t definitions, uint64_t source);
std::shared_ptr<BlockLodChain> decodeLodRecord(
        const std::string &bytes, uint64_t definitions, uint64_t source);

class LodStorage {
public:
    using Load = std::function<bool(v3s16, std::string &)>;
    using Build = std::function<std::shared_ptr<BlockLodChain>(v3s16, const std::string &)>;
    using LiveBuild = std::function<std::shared_ptr<BlockLodChain>()>;
    using Prime = std::function<void(v3s16)>;
    struct Result {
        v3s16 pos;
        uint64_t ticket = 0;
        std::shared_ptr<const BlockLodChain> chain;
        bool summary = false;
        std::string message;
        bool primed = false;
    };
    struct Stats {
        uint64_t hits = 0, misses = 0, built = 0, errors = 0, rejected = 0;
        uint64_t summary_hits = 0, summary_writes = 0;
        int queued = 0, ready = 0, active = 0;
    };
    ~LodStorage() { stop(); }
    // Callbacks and everything they read must outlive stop(). Opening the
    // cache, disk access, decompression and derivation all run on the worker.
    void start(std::string directory, uint64_t definitions, Load load, Build build, Prime prime);
    void stop();
    bool running() const;
    bool request(v3s16 pos, uint64_t ticket, int priority, LiveBuild live = {});
    void prime(v3s16 region);
    bool requestSummary(v3s16 origin, uint64_t ticket, int priority);
    bool saveSummary(v3s16 origin, std::string message);
    bool next(Result &result);
    Stats stats() const;
    // Abandon queued and completed work after a renderer reset. An active
    // result may still arrive; the consumer must validate its ticket.
    void clear();

private:
    struct Job {
        v3s16 pos;
        uint64_t ticket = 0;
        int priority = 0;
        bool prime = false;
        LiveBuild live;
        bool summary = false;
        std::string message; // non-empty means a summary write
    };
    void work(std::string directory, uint64_t definitions, Load load, Build build, Prime prime);
    mutable std::mutex m_mutex;
    std::condition_variable m_wake;
    std::thread m_thread;
    bool m_running = false;
    std::deque<Job> m_queue;
    std::deque<Result> m_ready;
    Stats m_stats;
};

} // namespace goanna
