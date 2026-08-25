// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_mesh_pool.h"

#include <algorithm>

namespace goanna {

void MeshPool::start(int threads) {
    if (m_running.load(std::memory_order_acquire))
        return;
    if (threads <= 0) {
        // Leave a core for Godot's main thread and one for the session
        // thread. Four is enough to keep a region backlog moving and small
        // enough that the meshers do not evict the renderer's working set on
        // a four core machine, where hardware_concurrency() - 2 is 2 anyway.
        unsigned hw = std::thread::hardware_concurrency();
        threads = (int)std::clamp<unsigned>(hw > 2 ? hw - 2 : 1, 1, 4);
    }
    m_running.store(true, std::memory_order_release);
    m_threads.reserve((size_t)threads);
    for (int i = 0; i < threads; ++i)
        m_threads.emplace_back(&MeshPool::workerMain, this);
}

void MeshPool::stop() {
    if (!m_running.exchange(false, std::memory_order_acq_rel)) {
        // Not running, but a previous stop may have left threads to join.
        for (auto &t : m_threads)
            if (t.joinable())
                t.join();
        m_threads.clear();
        return;
    }
    m_wake.notify_all();
    for (auto &t : m_threads)
        if (t.joinable())
            t.join();
    m_threads.clear();
    std::lock_guard<std::mutex> lock(m_mutex);
    m_queue.clear();
    m_ready.clear();
    m_inflight.clear();
}

void MeshPool::submit(const MeshJobKey &key, uint64_t generation, int priority,
        std::unique_ptr<MeshJob> job) {
    if (!job)
        return;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        // Replace a queued job for the same key rather than queueing behind
        // it. Without this a region that changes every poll meshes once per
        // change, and the newest capture is the only one worth building.
        for (auto &q : m_queue) {
            if (q.key == key) {
                q.generation = generation;
                q.priority = priority;
                q.job = std::move(job);
                m_wake.notify_one();
                return;
            }
        }
        Queued q;
        q.key = key;
        q.generation = generation;
        q.priority = priority;
        q.job = std::move(job);
        m_queue.push_back(std::move(q));
    }
    m_wake.notify_one();
}

void MeshPool::cancel(const MeshJobKey &key) {
    std::lock_guard<std::mutex> lock(m_mutex);
    for (auto it = m_queue.begin(); it != m_queue.end(); ++it) {
        if (it->key == key) {
            m_queue.erase(it);
            return;
        }
    }
}

void MeshPool::cancelAll() {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_queue.clear();
}

bool MeshPool::takeLocked(Queued &out) {
    if (m_queue.empty())
        return false;
    auto best = m_queue.begin();
    for (auto it = std::next(best); it != m_queue.end(); ++it)
        if (it->priority < best->priority)
            best = it;
    out = std::move(*best);
    m_queue.erase(best);
    return true;
}

void MeshPool::workerMain() {
    for (;;) {
        Queued q;
        {
            std::unique_lock<std::mutex> lock(m_mutex);
            m_wake.wait(lock, [&] {
                return !m_running.load(std::memory_order_acquire) || !m_queue.empty();
            });
            if (!m_running.load(std::memory_order_acquire))
                return;
            if (!takeLocked(q))
                continue;
            m_inflight[q.key] = q.generation;
            ++m_active;
        }

        q.job->run();

        {
            std::lock_guard<std::mutex> lock(m_mutex);
            --m_active;
            auto it = m_inflight.find(q.key);
            if (it != m_inflight.end() && it->second == q.generation)
                m_inflight.erase(it);
            Done d;
            d.key = q.key;
            d.generation = q.generation;
            d.job = std::move(q.job);
            m_ready.push_back(std::move(d));
        }
    }
}

bool MeshPool::next(Done &out) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_ready.empty())
        return false;
    out = std::move(m_ready.front());
    m_ready.pop_front();
    return true;
}

MeshPool::Stats MeshPool::stats() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    Stats s;
    s.queued = (int)m_queue.size();
    s.running = m_active;
    s.ready = (int)m_ready.size();
    s.threads = (int)m_threads.size();
    return s;
}

} // namespace goanna
