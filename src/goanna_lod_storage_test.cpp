// SPDX-License-Identifier: LGPL-2.1-or-later
// Persistence, source invalidation, record bounds and asynchronous admission.
#include "goanna_lod_storage.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <future>
#include <iostream>

using namespace goanna;
using namespace std::chrono_literals;

namespace {
void expect(bool ok, const char *message) {
    if (!ok) { std::cerr << "FAIL: " << message << '\n'; std::abort(); }
}
BlockLodChain fixture() {
    BlockLodChain ch;
    auto &lv = ch.level[0];
    lv.cell = 1; lv.n = 16; lv.cells.resize(4096);
    for (auto &c : lv.cells) c.flags = LodLevel::kKnown | LodLevel::kLit;
    auto &c = lv.at(3, 0, 5);
    c.flags |= LodLevel::kFilled | LodLevel::kOccludes | LodLevel::kLiquid;
    for (int i = 0; i < 6; ++i) { c.face[i] = 200 + i; c.param2[i] = 17 + i; }
    c.liquid = 300; c.liquid_param2 = 9; c.day = 132; c.night = 46;
    lv.at(15, 15, 15).flags = 0; // unknown is not known air
    buildLodMipLevels(ch, 0);
    buildLodTerrainSurface(nullptr, ch, 0);
    compactLodFineBoundary(ch);
    return ch;
}
LodStorage::Result waitResult(LodStorage &s) {
    LodStorage::Result r;
    auto until = std::chrono::steady_clock::now() + 5s;
    while (std::chrono::steady_clock::now() < until) {
        if (s.next(r)) return r;
        std::this_thread::sleep_for(1ms);
    }
    expect(false, "worker failed to return within five seconds");
    return r;
}
void records() {
    const auto ch = fixture();
    const auto bytes = encodeLodRecord(ch, 123, 456);
    auto copy = decodeLodRecord(bytes, 123, 456);
    expect(copy != nullptr, "valid record rejected");
    expect(encodeLodRecord(*copy, 123, 456) == bytes, "hierarchy changed on round trip");
    expect(copy->fine_record_mask == ch.fine_record_mask &&
            copy->fine_record_base == ch.fine_record_base, "sparse index was not reconstructed");
    expect(copy->fine_filled == ch.fine_filled && copy->fine_occludes == ch.fine_occludes,
            "exact occupancy was lost");
    expect(!decodeLodRecord(bytes, 124, 456), "changed node definitions accepted");
    expect(!decodeLodRecord(bytes, 123, 457), "changed source accepted");
    for (size_t n = 0; n < bytes.size(); ++n)
        expect(!decodeLodRecord(bytes.substr(0, n), 123, 456), "truncated record accepted");
    for (size_t n = 0; n < bytes.size(); ++n) {
        auto damaged = bytes; damaged[n] ^= 0x40;
        expect(!decodeLodRecord(damaged, 123, 456), "corrupt record accepted");
    }
    auto oversized = bytes;
    for (int i = 24; i < 28; ++i) oversized[i] = (char)255;
    expect(!decodeLodRecord(oversized, 123, 456), "unbounded allocation accepted");
    BlockLodChain air;
    air.summary = true;
    air.surface_shell = true;
    auto &lv = air.level[2]; lv.cell = 4; lv.n = 4; lv.cells.resize(64);
    for (auto &c : lv.cells) c.flags = LodLevel::kKnown;
    lv.at(0, 0, 0).flags = 0;
    buildLodMipLevels(air, 2);
    auto known = decodeLodRecord(encodeLodRecord(air, 1, 2), 1, 2);
    expect(known && known->summary && !known->hasCell(1), "summary invented fine detail");
    expect(known->surface_shell, "provider surface provenance was lost");
    expect(known->level[2].at(0, 0, 0).flags == 0 &&
            known->level[2].at(1, 0, 0).flags == LodLevel::kKnown,
            "known empty and unknown were conflated");
}
void persistence(const std::string &dir) {
    LodStorage s;
    std::string source = "revision one";
    int builds = 0;
    const auto main = std::this_thread::get_id();
    auto load = [&](v3s16 p, std::string &out) {
        expect(std::this_thread::get_id() != main, "source read ran on caller");
        out = source; return p.X != 99;
    };
    auto build = [&](v3s16, const std::string &input) {
        expect(std::this_thread::get_id() != main, "derivation ran on caller");
        ++builds;
        auto chain = std::make_shared<BlockLodChain>(fixture());
        chain->level[4].cells[0].night = input == "revision two" ? 75 : 25;
        return chain;
    };
    auto request = [&](uint64_t ticket) {
        expect(s.request(v3s16(-17, 4, 32), ticket, 0), "request refused");
        auto r = waitResult(s);
        expect(r.chain && r.ticket == ticket, "result lost identity or data");
        expect(r.chain->level[4].cells[0].night == (source == "revision two" ? 75 : 25),
                "source edit did not reach the returned terrain");
    };
    s.start(dir, 7, load, build, {});
    request(1);
    expect(s.stats().misses == 1 && builds == 1, "cold request did not derive");
    s.stop();
    s.start(dir, 7, load, build, {});
    request(2);
    expect(s.stats().hits == 1 && builds == 1, "reopen did not reuse prepared hierarchy");
    s.stop();
    source = "revision two";
    s.start(dir, 7, load, build, {});
    request(3);
    expect(s.stats().misses == 1 && builds == 2, "edit reused stale hierarchy");
    s.stop();
    s.start(dir, 8, load, build, {});
    request(4);
    expect(builds == 3, "definition change reused old IDs");
    expect(s.request(v3s16(99, 0, 0), 5, 0), "missing source request refused");
    expect(!waitResult(s).chain, "missing source became known air");
    s.stop();
    {
        BlockStore corrupt;
        expect(corrupt.open(dir, 512ull << 20), "cache reopen failed");
        corrupt.put(v3s16(-17, 4, 32), 1, "damaged cache", 1);
    }
    s.start(dir, 8, load, build, {});
    request(6);
    expect(builds == 4, "damaged cache did not rebuild from source");
    s.stop();
}
void bounds() {
    LodStorage s;
    std::promise<void> started, release;
    auto gate = release.get_future().share();
    s.start("", 1, {}, {}, {});
    expect(s.request(v3s16(0, 0, 0), 1, 0, [&] {
        started.set_value(); gate.wait(); return std::make_shared<BlockLodChain>(fixture());
    }), "blocking request refused");
    expect(started.get_future().wait_for(5s) == std::future_status::ready, "worker did not start");
    for (int i = 1; i <= 128; ++i)
        expect(s.request(v3s16(i, 0, 0), i, i), "queue filled prematurely");
    expect(!s.request(v3s16(129, 0, 0), 129, 0), "queue exceeded its bound");
    expect(s.request(v3s16(1, 0, 0), 900, -100), "replacement incorrectly needed another slot");
    expect(s.stats().queued == 128, "replacement expanded queue");
    release.set_value();
    expect(waitResult(s).ticket == 1, "active request was lost");
    expect(waitResult(s).ticket == 900, "superseded queued request survived");
    s.stop();
    expect(s.stats().queued == 0 && s.stats().ready == 0 && !s.running(), "stop retained work");
}
void masks(const std::string &dir) {
    const v3s16 bp(-17, 3, 4), region = BlockStore::regionOf(bp);
    BlockStore store;
    expect(store.open(dir, 1024 * 1024), "source store open failed");
    store.put(bp, 29, "source", 1);
    store.close();
    expect(store.open(dir, 1024 * 1024), "source store reopen failed");
    std::vector<uint8_t> mask;
    bool present = false;
    expect(!store.tryHas(bp, present), "cold block lookup performed I/O");
    expect(!store.tryRegionMask(region, mask), "cold index loaded synchronously");
    expect(store.regionMask(region, mask), "background prime failed");
    expect(store.tryRegionMask(region, mask), "primed mask unavailable");
    expect(store.tryHas(bp, present) && present, "primed block lookup lost source");
    expect(store.tryHas(v3s16(1600, 0, 0), present) && !present,
            "absent source required a worker request");
    const int slot = BlockStore::slotOf(bp);
    expect(mask[slot >> 3] & (1 << (slot & 7)), "negative-coordinate block missing");
    expect(store.tryRegionMask(v3s16(100, 0, 0), mask) && mask.empty(), "absent region required I/O");
    std::string payload; uint8_t version = 0;
    expect(!store.get(bp, version, payload, nullptr, 2), "payload size limit ignored");
}

void summaries(const std::string &dir) {
    LodStorage s;
    const v3s16 origin(-8, 24, 32);
    const std::string message = "7 16 -8 24 32 8 test:stone|known-empty-and-partial-records";
    s.start(dir, 33, {}, {}, {});
    expect(s.saveSummary(origin, message), "summary write refused");
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    while (s.stats().summary_writes != 1 && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(1ms);
    expect(s.stats().summary_writes == 1, "summary write did not complete");
    s.stop();
    s.start(dir, 33, {}, {}, {});
    expect(s.requestSummary(origin, 1234, 0), "summary read refused");
    auto result = waitResult(s);
    expect(result.summary && result.ticket == 1234 && result.pos == origin &&
            result.message == message, "reopened summary lost coverage or request identity");
    expect(s.stats().summary_hits == 1, "summary hit not counted");
    s.stop();
    s.start(dir, 34, {}, {}, {});
    s.requestSummary(origin, 1235, 0);
    expect(waitResult(s).message.empty(), "summary crossed definition namespace");
    s.stop();
    expect(!s.saveSummary(origin, std::string(1024 * 1024 + 1, 'x')), "oversized summary admitted");
}
}

int main() {
    auto root = std::filesystem::temp_directory_path() / ("goanna-lod-storage-test-" +
            std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    records();
    persistence((root / "prepared").string());
    bounds();
    masks((root / "source").string());
    summaries((root / "summaries").string());
    std::filesystem::remove_all(root);
    std::cout << "LOD storage: persistence, invalidation, bounds and worker checks passed\n";
}
