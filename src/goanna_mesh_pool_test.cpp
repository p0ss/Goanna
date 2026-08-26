// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The mesh pool's contract: every job submitted comes back exactly once, a
// second submission for a key already queued replaces it rather than running
// twice, cancel drops a queued job, and priority decides what runs first.
//
// Threading faults do not fail the same way twice, so the counts here are
// checked over enough jobs that a lost or duplicated result shows up, and the
// dedup and priority cases are made deterministic by holding the workers
// still while the queue is loaded.

#include "goanna_mesh_pool.h"

#include <atomic>
#include <cstdio>
#include <mutex>
#include <set>
#include <vector>

using namespace goanna;

namespace {

int g_failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

std::atomic<int> g_ran{0};

struct CountingJob : MeshJob {
    int id = 0;
    int spin = 0;
    explicit CountingJob(int id_, int spin_ = 0) : id(id_), spin(spin_) {}
    void run() override {
        // A little work, so jobs actually overlap on more than one worker.
        volatile int acc = 0;
        for (int i = 0; i < spin; ++i)
            acc += i;
        (void)acc;
        g_ran.fetch_add(1, std::memory_order_relaxed);
    }
};

MeshJobKey regionKey(int x, int tier = 1) {
    MeshJobKey k;
    k.kind = MeshJobKey::kLodRegion;
    k.pos = v3s16((s16)x, 0, 0);
    k.tier = (int16_t)tier;
    return k;
}

MeshJobKey nearKey(int x) {
    MeshJobKey k;
    k.kind = MeshJobKey::kNearBlock;
    k.pos = v3s16((s16)x, 0, 0);
    return k;
}

// Drain until `want` results have arrived. Returns how many were collected;
// the caller checks that against `want` rather than looping for ever.
int drain(MeshPool &pool, int want, std::vector<int> *order = nullptr) {
    int got = 0;
    for (int spins = 0; spins < 200000 && got < want; ++spins) {
        MeshPool::Done d;
        while (pool.next(d)) {
            if (order)
                order->push_back(static_cast<CountingJob *>(d.job.get())->id);
            ++got;
        }
    }
    return got;
}

void testEveryJobReturnsOnce() {
    g_ran.store(0);
    MeshPool pool;
    pool.setLimits(1024, 1024, 1024, 1024);
    pool.start(4);
    const int n = 500;
    for (int i = 0; i < n; ++i)
        pool.submit(regionKey(i), 1, MeshWorkStage::kStructure, i,
                std::make_unique<CountingJob>(i, 200));

    std::vector<int> ids;
    int got = drain(pool, n, &ids);
    check(got == n, "every submitted job comes back");
    check(g_ran.load() == n, "every job ran exactly once");

    std::set<int> unique(ids.begin(), ids.end());
    check(unique.size() == ids.size(), "no result is delivered twice");
    check((int)unique.size() == n, "no result is lost");

    pool.stop();
    MeshPool::Stats s = pool.stats();
    check(s.queued == 0 && s.running == 0, "stop leaves nothing queued or running");
}

void testResubmitReplaces() {
    g_ran.store(0);
    MeshPool pool; // not started: nothing can run while the queue is loaded
    for (int i = 0; i < 10; ++i)
        pool.submit(regionKey(7), (uint64_t)(i + 1), MeshWorkStage::kStructure, 0,
                std::make_unique<CountingJob>(i));
    check(pool.stats().queued == 1, "ten submissions of one key queue one job");

    pool.start(2);
    std::vector<int> ids;
    int got = drain(pool, 1, &ids);
    check(got == 1, "the replaced key runs once");
    check(g_ran.load() == 1, "the nine replaced jobs never ran");
    check(!ids.empty() && ids[0] == 9, "the newest capture is the one that runs");
    pool.stop();
}

void testCancel() {
    g_ran.store(0);
    MeshPool pool;
    for (int i = 0; i < 5; ++i)
        pool.submit(regionKey(i), 1, MeshWorkStage::kStructure, i,
                std::make_unique<CountingJob>(i));
    pool.cancel(regionKey(2));
    check(pool.stats().queued == 4, "cancel drops the queued job");

    pool.start(2);
    std::vector<int> ids;
    int got = drain(pool, 4, &ids);
    check(got == 4, "the rest still run");
    bool saw_cancelled = false;
    for (int id : ids)
        if (id == 2)
            saw_cancelled = true;
    check(!saw_cancelled, "the cancelled job does not come back");
    pool.stop();
}

void testCancelKindKeepsOtherWork() {
    g_ran.store(0);
    MeshPool pool;
    pool.submit(regionKey(1), 1, MeshWorkStage::kStructure, 0, std::make_unique<CountingJob>(1));
    pool.submit(nearKey(2), 1, MeshWorkStage::kNear, 0, std::make_unique<CountingJob>(2));
    pool.submit(regionKey(3), 1, MeshWorkStage::kStructure, 0, std::make_unique<CountingJob>(3));
    pool.cancelKind(MeshJobKey::kLodRegion);
    check(pool.stats().queued == 1, "kind cancellation retains unrelated jobs");
    pool.start(1);
    std::vector<int> ids;
    int got = drain(pool, 1, &ids);
    check(got == 1 && ids[0] == 2, "LOD reset does not cancel near work");
    pool.stop();
}

void testCancelKindDropsReadyResults() {
    g_ran.store(0);
    MeshPool pool;
    pool.start(1);
    pool.submit(regionKey(1), 1, MeshWorkStage::kStructure, 0, std::make_unique<CountingJob>(1));
    pool.submit(nearKey(2), 1, MeshWorkStage::kNear, 1, std::make_unique<CountingJob>(2));
    for (int spins = 0; spins < 200000 && pool.stats().ready < 2; ++spins) {
    }
    check(pool.stats().ready == 2, "jobs reached the ready queue before kind cancellation");
    pool.cancelKind(MeshJobKey::kLodRegion);
    MeshPool::Done done;
    check(pool.next(done) && done.key.kind == MeshJobKey::kNearBlock,
            "kind cancellation drops stale ready LOD results only");
    check(!pool.next(done), "no cancelled ready result remains");
    pool.stop();
}

void testPriorityOrder() {
    g_ran.store(0);
    MeshPool pool;
    // Load the queue with the workers stopped, then run one worker, so the
    // order out is the order the queue chose rather than a race.
    for (int i = 0; i < 20; ++i)
        pool.submit(regionKey(i), 1, MeshWorkStage::kStructure, 100 - i,
                std::make_unique<CountingJob>(i));
    pool.start(1);
    std::vector<int> ids;
    int got = drain(pool, 20, &ids);
    check(got == 20, "all priority jobs return");
    // Submitted with priority 100-i, so the highest i has the lowest number
    // and must come out first.
    check(!ids.empty() && ids[0] == 19, "the lowest priority number runs first");
    bool descending = true;
    for (size_t i = 1; i < ids.size(); ++i)
        if (ids[i] > ids[i - 1])
            descending = false;
    check(descending, "one worker drains strictly in priority order");
    pool.stop();
}

void testStageOrder() {
    g_ran.store(0);
    MeshPool pool;
    pool.submit(regionKey(1), 1, MeshWorkStage::kStructure, -1000,
            std::make_unique<CountingJob>(1));
    pool.submit(nearKey(2), 1, MeshWorkStage::kNear, 1000,
            std::make_unique<CountingJob>(2));
    pool.submit(regionKey(3), 1, MeshWorkStage::kCoverage, 2000,
            std::make_unique<CountingJob>(3));
    pool.start(1);
    std::vector<int> ids;
    check(drain(pool, 3, &ids) == 3, "all staged jobs return");
    check(ids.size() == 3 && ids[0] == 3 && ids[1] == 2 && ids[2] == 1,
            "coverage dispatches before near and refinement regardless of distance");
    pool.stop();
}

void testBoundedAdmissionReservesCoverage() {
    MeshPool pool;
    pool.setLimits(4, 2, 1, 2);
    check(pool.submit(regionKey(1), 1, MeshWorkStage::kStructure, 0,
                  std::make_unique<CountingJob>(1)),
            "first refinement is admitted");
    check(!pool.submit(regionKey(2), 1, MeshWorkStage::kStructure, 0,
                   std::make_unique<CountingJob>(2)),
            "refinement capacity is bounded");
    check(pool.submit(nearKey(3), 1, MeshWorkStage::kNear, 0,
                  std::make_unique<CountingJob>(3)),
            "near work uses its reserved non-refinement space");
    check(!pool.submit(nearKey(4), 1, MeshWorkStage::kNear, 0,
                   std::make_unique<CountingJob>(4)),
            "noncoverage work cannot consume the coverage reserve");
    check(pool.submit(regionKey(5), 1, MeshWorkStage::kCoverage, 0,
                  std::make_unique<CountingJob>(5)) &&
                  pool.submit(regionKey(6), 1, MeshWorkStage::kCoverage, 0,
                          std::make_unique<CountingJob>(6)),
            "coverage can use the reserved queue slots");
    check(!pool.submit(regionKey(7), 1, MeshWorkStage::kCoverage, 0,
                   std::make_unique<CountingJob>(7)),
            "total queue capacity remains bounded");
    check(pool.stats().queued == 4 && pool.stats().rejected == 3,
            "admission accounting reports the bound");
    pool.stop();
}

void testReadyBackpressure() {
    MeshPool pool;
    pool.setLimits(8, 8, 8, 1);
    pool.start(1);
    pool.submit(regionKey(1), 1, MeshWorkStage::kCoverage, 0,
            std::make_unique<CountingJob>(1));
    pool.submit(regionKey(2), 1, MeshWorkStage::kCoverage, 1,
            std::make_unique<CountingJob>(2));
    for (int spins = 0; spins < 200000 &&
            !(pool.stats().ready == 1 && pool.stats().running == 1); ++spins) {
    }
    check(pool.stats().ready == 1 && pool.stats().running == 1,
            "a full ready queue applies worker backpressure");
    MeshPool::Done done;
    check(pool.next(done), "the main thread can release ready capacity");
    check(drain(pool, 1) == 1, "the waiting completed job advances after collection");
    pool.stop();
}

void testStopWithoutStart() {
    MeshPool pool;
    pool.submit(regionKey(1), 1, MeshWorkStage::kStructure, 0,
            std::make_unique<CountingJob>(1));
    pool.stop(); // must not hang or crash
    check(true, "stop on a pool that never started is safe");
}

} // namespace

int main() {
    testEveryJobReturnsOnce();
    testResubmitReplaces();
    testCancel();
    testCancelKindKeepsOtherWork();
    testCancelKindDropsReadyResults();
    testPriorityOrder();
    testStageOrder();
    testBoundedAdmissionReservesCoverage();
    testReadyBackpressure();
    testStopWithoutStart();

    if (g_failures) {
        std::printf("goanna_mesh_pool_test: %d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("goanna_mesh_pool_test: ok\n");
    return 0;
}
