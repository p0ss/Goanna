// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#ifndef GOANNA_MESH_POOL_H
#define GOANNA_MESH_POOL_H

// A small pool of worker threads that build mesh geometry away from Godot's
// main thread, with a result queue the main thread drains at its own pace.
//
// The shape is Luanti's own, from client/mesh_generator_thread.h: work is
// captured into an immutable input, several workers turn inputs into results,
// results land in an output queue, and only the thread that owns the scene
// publishes them. Goanna needs that shape over two different job types (near
// mapblocks and far LOD regions) rather than over MapBlock alone, so this is
// its own class rather than Luanti's MeshUpdateManager, which is built around
// MapBlock in and MapBlockMesh out.
//
// The rule a job must obey is the same rule the session thread obeys, stated
// in CLAUDE.md: no Godot objects, and no reading of live client state. A job
// carries everything it needs, captured on the main thread when it is made.

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "irrlichttypes_bloated.h"

namespace goanna {

// What a job is about, and what makes two jobs the same job. A second job
// with a key already queued replaces the first rather than queueing behind
// it, which is what stops a region that keeps changing from meshing once per
// change while the player walks past it.
struct MeshJobKey {
    enum Kind : uint8_t { kNearBlock = 0, kLodRegion = 1 };
    Kind kind = kNearBlock;
    v3s16 pos;      // block position, or the region key's position
    int16_t tier = 0; // 0 for a near block

    bool operator==(const MeshJobKey &o) const {
        return kind == o.kind && pos == o.pos && tier == o.tier;
    }
    bool operator<(const MeshJobKey &o) const {
        if (kind != o.kind)
            return kind < o.kind;
        if (pos.X != o.pos.X)
            return pos.X < o.pos.X;
        if (pos.Y != o.pos.Y)
            return pos.Y < o.pos.Y;
        if (pos.Z != o.pos.Z)
            return pos.Z < o.pos.Z;
        return tier < o.tier;
    }
};

// One unit of work. Everything run() reads must have been captured before it
// was handed to the pool; everything it produces must be readable by the main
// thread once run() has returned.
class MeshJob {
public:
    virtual ~MeshJob() = default;
    // Called on a worker thread. Must not touch Godot objects, the session's
    // map, or any client state that the main thread can change.
    virtual void run() = 0;
};

class MeshPool {
public:
    MeshPool() = default;
    ~MeshPool() { stop(); }

    MeshPool(const MeshPool &) = delete;
    MeshPool &operator=(const MeshPool &) = delete;

    // threads <= 0 picks from the hardware, leaving the main thread and the
    // session thread a core each.
    void start(int threads = 0);
    void stop();
    bool running() const { return m_running.load(std::memory_order_acquire); }

    // Queue a job. `generation` stamps the state the job was captured from:
    // a result arriving with a generation older than the key's current one is
    // stale and the caller drops it. `priority` orders the queue, lower
    // first, and is the distance in blocks from the player in practice.
    void submit(const MeshJobKey &key, uint64_t generation, int priority,
            std::unique_ptr<MeshJob> job);

    // Forget a queued job that has not started. A job already running is left
    // to finish and its result discarded by the generation test on the way
    // out, because a worker cannot be interrupted safely part way through.
    void cancel(const MeshJobKey &key);
    void cancelAll();

    struct Done {
        MeshJobKey key;
        uint64_t generation = 0;
        std::unique_ptr<MeshJob> job;
    };

    // Take one finished job, main thread. False when there are none waiting.
    bool next(Done &out);

    // How many jobs are queued, running and waiting to be collected. Reported
    // through render_stats so a backlog is visible rather than guessed at.
    struct Stats {
        int queued = 0;
        int running = 0;
        int ready = 0;
        int threads = 0;
    };
    Stats stats() const;

private:
    struct Queued {
        MeshJobKey key;
        uint64_t generation = 0;
        int priority = 0;
        std::unique_ptr<MeshJob> job;
    };

    void workerMain();
    // Caller holds m_mutex. Lowest priority first, oldest first within a
    // priority, so a region does not starve behind a stream of nearer ones.
    bool takeLocked(Queued &out);

    mutable std::mutex m_mutex;
    std::condition_variable m_wake;
    std::deque<Queued> m_queue;
    std::deque<Done> m_ready;
    std::map<MeshJobKey, uint64_t> m_inflight; // key -> generation being run
    std::vector<std::thread> m_threads;
    std::atomic<bool> m_running{false};
    int m_active = 0; // jobs inside run()
};

} // namespace goanna

#endif
