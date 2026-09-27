// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_shared_cache.h"
#include <atomic>
#include <cassert>
#include <future>
#include <stdexcept>
#include <thread>
#include <vector>

int main() {
    goanna::SharedCache<int> cache(32);
    cache.put("received-A", std::make_shared<int>(1), 4);
    assert(*cache.find("received-A") == 1);
    assert(!cache.find("received-B")); // changed or missing input cannot reuse
    cache.put("received-B", std::make_shared<int>(2), 4);
    cache.find("received-A");
    cache.put("received-C", std::make_shared<int>(3), 4);
    assert(cache.find("received-A") && !cache.find("received-B"));
    auto held = cache.find("received-A");
    cache.put("replacement", std::make_shared<int>(4), 20);
    assert(*held == 1); // eviction must not invalidate a published view
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
        assert(*value == 17);
    });
    release.set_value();
    for (auto &thread : threads) thread.join();
    assert(builds == 1);
    bool reused = false;
    try {
        concurrent.get("failure", []() -> std::shared_ptr<const int> { throw std::runtime_error("test"); },
                [](const int &) { return 4; }, reused);
        assert(false);
    } catch (const std::runtime_error &) {}
    assert(*concurrent.get("failure", [] { return std::make_shared<int>(5); },
            [](const int &) { return 4; }, reused) == 5);
}
