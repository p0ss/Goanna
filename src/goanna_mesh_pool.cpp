// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_mesh_pool.h"
#include "goanna_schedule.h"

#include <algorithm>

namespace goanna {

void MeshPool::start(int threads) {
    if (m_running.load(std::memory_order_acquire))
        return;
    if (threads <= 0) {
        // Half the machine, leaving the other half for Godot's main thread,
        // the session thread and everything else. The old rule capped at four
        // whatever the machine had, which on a sixteen thread desktop left
        // three quarters of it idle while the player watched terrain arrive.
        // Still one on anything small, and still bounded, because past about
        // eight the meshers start costing more in cache pressure than they
        // return.
        unsigned hw = std::thread::hardware_concurrency();
        threads = (int)std::clamp<unsigned>(hw / 2, 1, 8);
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
        std::lock_guard<std::mutex> lock(m_mutex);
        m_queue.clear();
        m_ready.clear();
        m_inflight.clear();
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

void MeshPool::setLimits(int queued, int noncoverage, int refinement, int ready) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_max_queued = std::max(1, queued);
    m_max_noncoverage = std::clamp(noncoverage, 0, m_max_queued);
    // The coverage reserve is symmetric: coverage must not fill every slot
    // and prevent an urgent stale or near update from being admitted.
    m_max_coverage = std::max(1, m_max_noncoverage);
    m_max_refinement = std::clamp(refinement, 0, m_max_noncoverage);
    m_max_ready = std::max(1, ready);
}

bool MeshPool::canAdmitLocked(const MeshJobKey &key, MeshWorkStage stage) const {
    int coverage = 0;
    int noncoverage = 0;
    int refinement = 0;
    for (const Queued &q : m_queue) {
        if (q.key == key)
            return true; // replacing a queued capture does not consume space
        if (q.stage == MeshWorkStage::kCoverage)
            ++coverage;
        else
            ++noncoverage;
        if (q.stage >= MeshWorkStage::kStructure)
            ++refinement;
    }
    return (int)m_queue.size() < m_max_queued &&
            (stage != MeshWorkStage::kCoverage || coverage < m_max_coverage) &&
            (stage == MeshWorkStage::kCoverage || noncoverage < m_max_noncoverage) &&
            (stage < MeshWorkStage::kStructure || refinement < m_max_refinement);
}

bool MeshPool::canSubmit(const MeshJobKey &key, MeshWorkStage stage) const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return canAdmitLocked(key, stage);
}

bool MeshPool::submit(const MeshJobKey &key, uint64_t generation, MeshWorkStage stage, int priority,
        std::unique_ptr<MeshJob> job) {
    if (!job)
        return false;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        // Replace a queued job for the same key rather than queueing behind
        // it. Without this a region that changes every poll meshes once per
        // change, and the newest capture is the only one worth building.
        for (auto &q : m_queue) {
            if (q.key == key) {
                q.generation = generation;
                q.stage = stage;
                q.priority = priority;
                q.job = std::move(job);
                m_wake.notify_one();
                return true;
            }
        }
        if (!canAdmitLocked(key, stage)) {
            ++m_rejected;
            return false;
        }
        Queued q;
        q.key = key;
        q.generation = generation;
        q.stage = stage;
        q.priority = priority;
        q.queued_at = std::chrono::steady_clock::now();
        q.job = std::move(job);
        m_queue.push_back(std::move(q));
    }
    m_wake.notify_one();
    return true;
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

void MeshPool::cancelKind(MeshJobKey::Kind kind) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_queue.erase(std::remove_if(m_queue.begin(), m_queue.end(),
                          [kind](const Queued &q) { return q.key.kind == kind; }),
            m_queue.end());
    m_ready.erase(std::remove_if(m_ready.begin(), m_ready.end(),
                          [kind](const Done &d) { return d.key.kind == kind; }),
            m_ready.end());
    m_wake.notify_all();
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
        if (effectivePriorityLocked(*it) < effectivePriorityLocked(*best) ||
                (effectivePriorityLocked(*it) == effectivePriorityLocked(*best) &&
                        it->stage < best->stage))
            best = it;
    out = std::move(*best);
    m_queue.erase(best);
    return true;
}

int MeshPool::effectivePriorityLocked(const Queued &q) const {
    constexpr double kAgeMs = 4000.0;
    const double waited = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - q.queued_at).count();
    const ViewPriority::Class cls = ViewPriority::aged(
            ViewPriority::classOf(q.priority), waited, kAgeMs);
    return (int)cls * ViewPriority::kClassStride + ViewPriority::distanceOf(q.priority);
}

int MeshPool::effectivePriorityLocked(const Done &d) const {
    constexpr double kAgeMs = 4000.0;
    const double waited = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - d.queued_at).count();
    const ViewPriority::Class cls = ViewPriority::aged(
            ViewPriority::classOf(d.priority), waited, kAgeMs);
    return (int)cls * ViewPriority::kClassStride + ViewPriority::distanceOf(d.priority);
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
            std::unique_lock<std::mutex> lock(m_mutex);
            m_wake.wait(lock, [&] {
                return !m_running.load(std::memory_order_acquire) ||
                        (int)m_ready.size() < m_max_ready;
            });
            --m_active;
            auto it = m_inflight.find(q.key);
            if (it != m_inflight.end() && it->second == q.generation)
                m_inflight.erase(it);
            if (!m_running.load(std::memory_order_acquire))
                return;
            Done d;
            d.key = q.key;
            d.generation = q.generation;
            d.stage = q.stage;
            d.priority = q.priority;
            d.queued_at = q.queued_at;
            d.job = std::move(q.job);
            m_ready.push_back(std::move(d));
        }
    }
}

bool MeshPool::next(Done &out) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_ready.empty())
        return false;
    auto best = m_ready.begin();
    for (auto it = std::next(best); it != m_ready.end(); ++it)
        if (effectivePriorityLocked(*it) < effectivePriorityLocked(*best) ||
                (effectivePriorityLocked(*it) == effectivePriorityLocked(*best) &&
                        it->stage < best->stage))
            best = it;
    out = std::move(*best);
    m_ready.erase(best);
    m_wake.notify_one();
    return true;
}

void MeshPool::requeueReady(Done &&d) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_ready.push_front(std::move(d));
}

MeshPool::Stats MeshPool::stats() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    Stats s;
    s.queued = (int)m_queue.size();
    s.running = m_active;
    s.ready = (int)m_ready.size();
    s.threads = (int)m_threads.size();
    s.rejected = m_rejected;
    const Queued *head = nullptr;
    const Queued *nearest = nullptr;
    for (const Queued &q : m_queue) {
        ++s.queued_stage[(int)q.stage];
        // The same choice takeLocked makes, so the reported head is the job
        // that really does run next rather than whatever is at the front of
        // the deque.
        if (!head || effectivePriorityLocked(q) < effectivePriorityLocked(*head) ||
                (effectivePriorityLocked(q) == effectivePriorityLocked(*head) &&
                        q.stage < head->stage))
            head = &q;
        if (!nearest || ViewPriority::distanceOf(q.priority) <
                        ViewPriority::distanceOf(nearest->priority))
            nearest = &q;
    }
    if (head) {
        s.has_head = true;
        s.head_stage = head->stage;
        s.head_priority = effectivePriorityLocked(*head);
    }
    if (nearest) {
        s.has_nearest = true;
        s.nearest_priority = nearest->priority;
    }
    return s;
}

} // namespace goanna
