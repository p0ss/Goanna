// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The shared cache's contract: a result is reused only for the same key,
// eviction keeps the recently used entries and never invalidates a view a
// caller already holds, concurrent callers for one key build it once, and a
// failed build is not cached.
//
// The checks do not use assert(), which the default RelWithDebInfo build
// compiles out under NDEBUG, so a test written with it could never fail.

#include "goanna_shared_cache.h"

#include <atomic>
#include <cstdio>
#include <future>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {

std::atomic<int> g_failures{0};

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}

} // namespace

int main() {
    goanna::SharedCache<int> cache(32);
    cache.put("received-A", std::make_shared<int>(1), 4);
    auto a = cache.find("received-A");
    check(a && *a == 1, "a stored result is found under its key");
    check(!cache.find("received-B"), "changed or missing input cannot reuse");
    cache.put("received-B", std::make_shared<int>(2), 4);
    cache.find("received-A");
    cache.put("received-C", std::make_shared<int>(3), 4);
    check(cache.find("received-A") && !cache.find("received-B"),
          "eviction drops the least recently used entry");
    auto held = cache.find("received-A");
    cache.put("replacement", std::make_shared<int>(4), 20);
    check(held && *held == 1, "eviction must not invalidate a published view");

    goanna::SharedCache<int> concurrent(1024);
    std::atomic<int> builds{0};
    std::vector<std::thread> threads;
    std::promise<void> release;
    auto ready = release.get_future().share();
    for (int i = 0; i < 8; ++i) threads.emplace_back([&] {
        ready.wait();
        bool reused = false;
        auto value = concurrent.get("same-definition-and-input", [&] {
            ++builds;
            return std::make_shared<int>(17);
        }, [](const int &) { return sizeof(int); }, reused);
        check(value && *value == 17, "every concurrent caller gets the built value");
    });
    release.set_value();
    for (auto &thread : threads) thread.join();
    check(builds == 1, "concurrent callers for one key build it once");

    bool reused = false;
    bool threw = false;
    try {
        concurrent.get("failure", []() -> std::shared_ptr<const int> { throw std::runtime_error("test"); },
                [](const int &) { return 4; }, reused);
    } catch (const std::runtime_error &) {
        threw = true;
    }
    check(threw, "a failed build reaches its caller");
    auto retried = concurrent.get("failure", [] { return std::make_shared<int>(5); },
            [](const int &) { return 4; }, reused);
    check(retried && *retried == 5, "a failed build is not cached");

    if (g_failures != 0) {
        std::printf("goanna_shared_cache_test: %d failure(s)\n", g_failures.load());
        return 1;
    }
    std::printf("goanna_shared_cache_test: ok\n");
    return 0;
}
