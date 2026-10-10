// SPDX-License-Identifier: LGPL-2.1-or-later
// Prepared terrain records and a bounded background reader. No Godot state.
//
// A far region is meshed from each block's BlockLodChain (goanna_lod.h).
// Deriving a chain means reading the block's bytes from the BlockStore,
// decompressing and deserialising them and reducing all five levels, which
// is too slow to do on the main thread for thousands of blocks. LodStorage
// does it on one worker thread and keeps the result on disk as a compact
// record (encodeLodRecord), keyed by the definitions and the source bytes, so
// the next visit reads the record instead of deriving it again. The same
// worker reads and writes the server's far summaries (summaries/ under the
// cache directory).
//
// Threads: GoannaClient calls every public method of LodStorage from
// Godot's main thread; work() and the callbacks it was started with run on
// the worker. The record codec (encodeLodRecord, decodeLodRecord) is plain
// and runs wherever it is called. sharedLodChain is safe from any thread.
// See docs/systems/terrain-storage.md and docs/develop/architecture.md,
// "From the main thread to the workers".
//
// Main types: LodStorage, its Result and Stats.
#pragma once

#include "goanna_lod.h"
#include "goanna_store.h"

#include <condition_variable>
#include <deque>
#include <functional>
#include <string>
#include <thread>

namespace goanna {

// FNV-1a over the bytes. Used as a revision and definitions stamp, not as a
// security hash.
uint64_t terrainFingerprint(const std::string &bytes);
std::string encodeLodRecord(const BlockLodChain &chain, uint64_t definitions, uint64_t source);
std::shared_ptr<BlockLodChain> decodeLodRecord(
        const std::string &bytes, uint64_t definitions, uint64_t source);

// A process wide cache of immutable chains, keyed by exactly the inputs that
// made them, so the clients of a split screen session (each its own
// GoannaClient in one process) derive a block once between them. `build` runs
// at most once per key while other callers wait for it. An empty key, or
// GOANNA_NO_SHARED_TERRAIN in the environment, skips the cache. The cache has
// its own mutex (SharedCache in goanna_shared_cache.h); callers must not hold
// the map lock or touch Godot inside `build`.
std::shared_ptr<const BlockLodChain> sharedLodChain(const std::string &key,
        const std::function<std::shared_ptr<const BlockLodChain>()> &build);
uint64_t sharedLodHits(); // for render_stats

// The prepared terrain worker. Requests go in through request, prime,
// requestSummary and saveSummary; results come out through next, which the
// main thread polls. Each request carries a ticket the caller compares on
// collection, because clear() cannot recall a job the worker has already
// taken. The queue is bounded (128 jobs, 16 of them summaries) and a full
// queue refuses rather than blocks; the caller keeps its state and asks again.
class LodStorage {
public:
    // Load reads a block's stored bytes (version byte first) from the
    // BlockStore. Build derives a chain from those bytes. Both run on the
    // worker, so they may only read things that are safe off the main thread:
    // the store, which locks itself, and the session's node definitions,
    // which do not change once content is prepared. LiveBuild derives a chain
    // from nodes the main thread copied out of the map under its lock. Prime
    // warms the store's region index so a later main thread lookup does not
    // wait on disk.
    using Load = std::function<bool(v3s16, std::string &)>;
    using Build = std::function<std::shared_ptr<BlockLodChain>(v3s16, const std::string &)>;
    using LiveBuild = std::function<std::shared_ptr<const BlockLodChain>()>;
    using Prime = std::function<void(v3s16)>;
    // One finished job. `chain` is null when the block could not be read or
    // derived; `summary` marks a summary read, with the stored message (empty
    // on a miss); `primed` marks a finished prime.
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
    // A chain for one block: through `live` when given, else from the store
    // and the record cache. A queued request for the same block is replaced.
    // Lower priority runs first; queued jobs age so none waits for ever.
    bool request(v3s16 pos, uint64_t ticket, int priority, LiveBuild live = {});
    void prime(v3s16 region);
    // Read a cached far summary for the area at `origin`, or store one the
    // server sent. A save produces no Result, and runs behind everything else.
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
    // The worker. It owns the two BlockStore caches (records and summaries),
    // which no other thread sees, and stops taking jobs while 32 results wait
    // uncollected.
    void work(std::string directory, uint64_t definitions, Load load, Build build, Prime prime);
    // Guards m_running, m_queue, m_ready and m_stats. The main thread takes
    // it in every public method; the worker takes it to take a job and to
    // hand a result back, never while loading or deriving.
    mutable std::mutex m_mutex;
    // Wakes the worker when a job is queued, when next() frees a ready slot,
    // and when stop() asks it to leave.
    std::condition_variable m_wake;
    std::thread m_thread; // started by start(), joined by stop(), main thread
    bool m_running = false;
    // Jobs waiting: written by the main thread, taken by the worker.
    std::deque<Job> m_queue;
    // Results waiting: written by the worker, drained by next().
    std::deque<Result> m_ready;
    Stats m_stats; // counters written by the worker, copied out by stats()
};

} // namespace goanna
