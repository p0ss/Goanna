// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The far field beyond the live map. lodUpdateFar assigns blocks the store
// holds within the granted far distance to tiers, and lets go of those that
// pass out of range. lodRequestSummaries and lodTakeSummaries ask the server
// mod to summarise terrain this client has never been near, and turn the
// replies into coarse chains. horizon_bake_request, horizonExtractSlice and
// horizon_bake_poll make the horizon panorama beyond the drawn far field.
//
// Threads: Godot's main thread. update_lod calls lodUpdateFar,
// lodRequestSummaries and lodTakeSummaries with the session's map lock held.
// The panorama is built on m_horizon_thread from a snapshot the main thread
// extracts a slice per frame, and comes back under m_horizon_mutex.

#include "goanna_client_internal.h"

using namespace godot;

namespace goanna {

void GoannaClient::horizon_bake_request(const Vector3 &origin, float r0, float r1) {
    if (!m_session)
        return;
    {
        std::lock_guard<std::mutex> lk(m_horizon_mutex);
        if (m_horizon_busy)
            return;
    }
    if (m_horizon_extracting)
        return;
    // The snapshot is extracted incrementally: this only opens the cursor,
    // and horizon_bake_poll walks a bounded slice of the chains per frame
    // until it is done, then hands the snapshot to the worker. A single
    // full walk here was a guaranteed hitch on the half-million-chain
    // worlds, the exact intermittent cratering this client is fighting.
    m_horizon_pending = HorizonSnapshot();
    m_horizon_pending.origin_x = origin.x;
    m_horizon_pending.origin_y = origin.y;
    m_horizon_pending.origin_z = -origin.z;
    m_horizon_pending.r0 = std::max(64.0f, r0);
    m_horizon_pending.r1 = std::clamp(r1, m_horizon_pending.r0 + 256.0f, 8192.0f);
    m_horizon_pending.columns.reserve(m_lod_chains.size() / 4 + 16);
    m_horizon_colours.clear();
    m_horizon_extract_cursor = v3s16(-32768, -32768, -32768);
    m_horizon_extracting = true;
}

// Walk up to `budget` chains from the cursor into the pending snapshot.
// Returns true when the extraction is complete. The chains map can gain
// and lose entries between slices, like the prune sweeps' cursors; a
// column that is a frame staler than its neighbour is invisible in a
// background panorama.
bool GoannaClient::horizonExtractSlice(int budget) {
    const NodeDefManager *ndef = m_session->nodeDefs();
    GoannaTextureSource *tsrc = m_session->tsrc();
    const MaterialTable *materials = &m_session->materialTable();
    auto it = m_lod_chains.lower_bound(m_horizon_extract_cursor);
    int visited = 0;
    const auto started = clock_t_::now();
    while (it != m_lod_chains.end() && visited < budget && ms_since(started) < 2.0) {
        ++visited;
        const v3s16 bp = it->first;
        const BlockLodChain *chain = it->second.get();
        ++it;
        const LodTopSample top = lodHorizonTop(*chain);
        if (top.height == 0)
            continue;
        const content_t content = top.content;
        const uint8_t p2 = top.param2;
        const int16_t top_y = (int16_t)(bp.Y * MAP_BLOCKSIZE + top.height - 1);
        const uint32_t key = HorizonSnapshot::key(bp.X, bp.Z);
        auto &col = m_horizon_pending.columns[key];
        if (col.top_y != -32768 && col.top_y >= top_y)
            continue;
        const uint32_t ck = (uint32_t)content | ((uint32_t)p2 << 16);
        auto cit = m_horizon_colours.find(ck);
        if (cit == m_horizon_colours.end())
            cit = m_horizon_colours.emplace(ck,
                    lodFlatColour(m_lod_tiles, ndef, tsrc, materials, content, p2)).first;
        col.top_y = top_y;
        col.colour = cit->second;
    }
    if (it == m_lod_chains.end())
        return true;
    m_horizon_extract_cursor = it->first;
    return false;
}

Dictionary GoannaClient::horizon_bake_poll() {
    Dictionary d;
    // Pump the incremental extraction: one bounded slice per frame, and
    // when the walk completes, hand the snapshot to the worker.
    if (m_horizon_extracting && m_session && horizonExtractSlice(8000)) {
        m_horizon_extracting = false;
        {
            std::lock_guard<std::mutex> lk(m_horizon_mutex);
            m_horizon_busy = true;
        }
        if (m_horizon_thread.joinable())
            m_horizon_thread.join();
        m_horizon_thread = std::thread(
                [this, snap = std::move(m_horizon_pending)]() mutable {
                    HorizonResult res = buildHorizonPanorama(snap);
                    std::lock_guard<std::mutex> lk(m_horizon_mutex);
                    m_horizon_result = std::move(res);
                    m_horizon_fresh = true;
                    m_horizon_busy = false;
                });
        m_horizon_pending = HorizonSnapshot();
        m_horizon_colours.clear();
    }
    HorizonResult res;
    {
        std::lock_guard<std::mutex> lk(m_horizon_mutex);
        if (!m_horizon_fresh)
            return d;
        m_horizon_fresh = false;
        res = std::move(m_horizon_result);
    }
    PackedByteArray alb;
    alb.resize((int64_t)res.albedo.size());
    memcpy(alb.ptrw(), res.albedo.data(), res.albedo.size());
    PackedByteArray dist;
    dist.resize((int64_t)res.distance.size() * 4);
    memcpy(dist.ptrw(), res.distance.data(), res.distance.size() * 4);
    d["albedo"] = Image::create_from_data(res.width, res.height, false,
            Image::FORMAT_RGBA8, alb);
    d["dist"] = Image::create_from_data(res.width, res.height, false,
            Image::FORMAT_RF, dist);
    d["origin"] = Vector3(res.origin_x, res.origin_y, -res.origin_z);
    d["r0"] = res.r0;
    d["r1"] = res.r1;
    d["y_min"] = res.y_min;
    d["y_max"] = res.y_max;
    return d;
}

// Blocks the server is not sending but the store holds, within the granted
// far distance: assigned to tiers like received blocks and drawn from their
// chains. Rescans when the player crosses a block boundary or every two
// seconds, and lets go of what has passed out of range. Caller holds the map
// lock.
void GoannaClient::lodUpdateFar(const Vector3 &around) {
    if (!m_session)
        return;
    int grant = m_session->farRenderingGrant();
    // The default is the grant, not a fixed number (docs/develop/launch-target.md
    // task 2d): a 512 node default left half of a 1024 node grant unused
    // until someone thought to raise it. An explicit choice, env var or
    // settings panel, still wins.
    if (!m_far_distance_explicit && grant > 0 && grant != m_far_distance) {
        m_far_distance = std::clamp(grant, 0, 8192);
        m_far_dirty = true;
    }
    if (m_lod_distance <= 0 || grant <= 0 || m_store_root.is_empty()) {
        if (!m_far_blocks.empty()) {
            for (const v3s16 &bp : m_far_blocks) {
                lodForget(bp);
                m_block_tier.erase(bp);
            }
            m_far_blocks.clear();
        }
        return;
    }
    // Stored, actually visited geometry still refines the baked surface.
    // Only synthetic summary requests are limited to the local join below.
    const int dist = std::min(grant, m_far_distance);
    const int radius = std::max(1, dist / MAP_BLOCKSIZE);
    // The mesh horizon in block units, for lodAssign and the reach
    // histogram. 0 when the split is off.
    m_far_mesh_radius = m_far_mesh_distance > 0
            ? std::min(radius, std::max(1, m_far_mesh_distance / MAP_BLOCKSIZE))
            : 0;
    const v3s16 centre((s16)std::floor(around.x / MAP_BLOCKSIZE), (s16)std::floor(around.y / MAP_BLOCKSIZE),
            (s16)std::floor(-around.z / MAP_BLOCKSIZE));
    if (!m_far_dirty && centre == m_far_centre && ms_since(m_far_last) < 2000.0)
        return;
    m_far_dirty = false;
    m_far_centre = centre;
    m_far_radius = radius;
    m_far_last = clock_t_::now();
    // Out of range, or now live: let go. Swept a bounded slice per rescan
    // rather than in full: at a 4096 grant the retained set runs to half a
    // million blocks, and walking every one of them under the map lock every
    // two seconds was over 30 ms of main thread on its own (the "far 31.7 ms"
    // HUD line this replaces). A block turning live is already released at
    // once by poll_blocks; leaving range is memory hygiene, and hygiene can
    // be lazy. The cursor makes the sweep complete a full cycle in
    // set size / kFarSweep rescans.
    constexpr int kFarSweep = 16384;
    {
        auto it = m_far_blocks.lower_bound(m_far_prune_cursor);
        int visited = 0;
        while (it != m_far_blocks.end() && visited < kFarSweep) {
            ++visited;
            const v3s16 d = *it - centre;
            const bool out = std::abs(d.X) > radius + 1 || std::abs(d.Y) > radius + 1 || std::abs(d.Z) > radius + 1;
            if (out || m_session->getBlock(*it)) {
                if (out) {
                    lodForget(*it);
                    m_block_tier.erase(*it);
                    m_block_queued_at.erase(*it);
                }
                m_far_remote.erase(*it);
                it = m_far_blocks.erase(it);
            } else {
                // A former local provider shell can remain cached after a
                // flight. The direct surface replaces its distant geometry;
                // genuine stored voxels retain their ordinary far range.
                auto chain = m_lod_chains.find(*it);
                if (!m_surface_revision.empty() && chain != m_lod_chains.end() &&
                        chain->second->surface_shell) {
                    const bool draw = int64_t(d.X) * d.X + int64_t(d.Z) * d.Z <= 32 * 32;
                    if (draw != (m_lod_member.count(*it) != 0))
                        lodAssign(*it, lodTierFor(*it, around, false));
                }
                ++it;
            }
        }
        m_far_prune_cursor = it == m_far_blocks.end()
                ? v3s16(-32768, -32768, -32768)
                : *it;
    }
    // Summaries inside the near floor are cached but not members of a far
    // region. Prune those caches independently; a live block supersedes one
    // immediately, and an out-of-range summary need not occupy memory. Same
    // bounded sweep as above, for the same reason.
    {
        auto it = m_far_remote.lower_bound(m_far_remote_cursor);
        int visited = 0;
        while (it != m_far_remote.end() && visited < kFarSweep) {
            ++visited;
            if (m_far_blocks.count(*it)) {
                ++it;
                continue;
            }
            const v3s16 d = *it - centre;
            const bool out = std::abs(d.X) > radius + 1 || std::abs(d.Y) > radius + 1 ||
                    std::abs(d.Z) > radius + 1;
            if (out || m_session->getBlock(*it)) {
                auto ch = m_lod_chains.find(*it);
                if (ch != m_lod_chains.end() && ch->second->summary)
                    m_lod_chains.erase(ch);
                it = m_far_remote.erase(it);
            } else {
                ++it;
            }
        }
        m_far_remote_cursor = it == m_far_remote.end()
                ? v3s16(-32768, -32768, -32768)
                : *it;
    }
    // Requested areas that have drifted out of range may be asked again if
    // we come back.
    for (auto it = m_far_requested.begin(); it != m_far_requested.end();) {
        const v3s16 d = it->first - centre;
        if (std::abs(d.X) > radius + 16 || std::abs(d.Z) > radius + 16)
            it = m_far_requested.erase(it);
        else
            ++it;
    }
    // In range, in the store, not live, not yet drawn: assign. Also a
    // bounded slice per rescan: at a 4096 grant the cube is some 36000
    // region mask queries, and on a store holding hundreds of regions each
    // present one churns the bounded file handle pool. The linear cursor
    // wraps over the current cube; the near-to-far handoff in prune_blocks
    // covers freshly pruned ground at once, so this backstop can take a few
    // rescans to come round.
    std::vector<uint8_t> bits;
    const int R = BlockStore::kRegionBlocks;
    auto fdiv = [](int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    const v3s16 lo(fdiv(centre.X - radius, R), fdiv(centre.Y - radius, R), fdiv(centre.Z - radius, R));
    const v3s16 hi(fdiv(centre.X + radius, R), fdiv(centre.Y + radius, R), fdiv(centre.Z + radius, R));
    int added = 0;
    const int64_t span_x = hi.X - lo.X + 1, span_y = hi.Y - lo.Y + 1, span_z = hi.Z - lo.Z + 1;
    const int64_t cube = span_x * span_y * span_z;
    constexpr int64_t kStoreScanRegions = 4096;
    if (m_far_store_cursor >= cube)
        m_far_store_cursor = 0;
    const int64_t scan_end = std::min(cube, m_far_store_cursor + kStoreScanRegions);
    // Revisit a newly loaded index immediately, rather than waiting for the
    // rotating cube scan to reach it again many seconds later.
    const int64_t primed = (int64_t)m_lod_primed_regions.size();
    for (int64_t item = -primed; item < scan_end - m_far_store_cursor; ++item) {
                const int64_t idx = m_far_store_cursor + std::max<int64_t>(0, item);
                v3s16 region(lo.X + (int)(idx % span_x),
                        lo.Y + (int)((idx / span_x) % span_y),
                        lo.Z + (int)(idx / (span_x * span_y)));
                if (item < 0) {
                    region = m_lod_primed_regions.front();
                    m_lod_primed_regions.pop_front();
                }
                const int rx = region.X, ry = region.Y, rz = region.Z;
                BlockStore *store = m_session->store();
                if (!store) continue;
                if (!store->tryRegionMask(region, bits)) {
                    m_lod_storage.prime(region);
                    continue;
                }
                if (bits.empty()) continue;
                for (int i = 0; i < BlockStore::kSlots; ++i) {
                    if (!(bits[i >> 3] & (1u << (i & 7))))
                        continue;
                    const v3s16 bp(rx * R + (i % R), ry * R + ((i / R) % R), rz * R + (i / (R * R)));
                    const v3s16 d = bp - centre;
                    if (std::abs(d.X) > radius || std::abs(d.Y) > radius || std::abs(d.Z) > radius)
                        continue;
                    if (m_session->getBlock(bp))
                        continue;
                    if (m_near_blocks.count(bp))
                        continue; // retained full-detail surface shell
                    // Deterministic source upgrades: a stored block contains
                    // full nodes and must replace an earlier remote summary.
                    // Previously m_far_blocks made the first source win, so
                    // the same place could keep a different shape depending
                    // on whether its summary or store scan arrived first.
                    auto chained = m_lod_chains.find(bp);
                    const bool replace_summary = chained != m_lod_chains.end() && chained->second->summary;
                    if (m_far_blocks.count(bp) && !replace_summary)
                        continue;
                    if (replace_summary) {
                        // Keep the old summary visible until the exact
                        // stored source has actually finished loading.
                        if (!m_lod_chain_missing.count(bp)) lodRequestChain(bp, true);
                        continue;
                    }
                    const int tier = lodTierFor(bp, around, false);
                    if (tier < 1)
                        continue; // tiers off
                    m_lod_chain_missing.erase(bp);
                    lodAssign(bp, tier);
                    m_block_tier[bp] = tier;
                    m_far_blocks.insert(bp);
                    ++added;
                }
    }
    m_far_store_cursor = scan_end >= cube ? 0 : scan_end;
    // Reassign any remote chain that temporarily has no region membership,
    // for example across a live/far ownership change. A complete area will
    // not be requested again, so this cache must remain independently useful.
    // Bounded like the sweeps above: the ordinary path assigns a summary the
    // moment it arrives, so this is a repair pass and can take its time.
    {
        auto it = m_far_remote.lower_bound(m_far_reassign_cursor);
        int visited = 0;
        while (it != m_far_remote.end() && visited < kFarSweep) {
            ++visited;
            const v3s16 bp = *it;
            ++it;
            if (m_far_blocks.count(bp) || m_session->getBlock(bp) || m_near_blocks.count(bp))
                continue;
            const v3s16 d = bp - centre;
            if (std::abs(d.X) > radius || std::abs(d.Y) > radius || std::abs(d.Z) > radius)
                continue;
            const int tier = lodTierFor(bp, around, false);
            if (tier < 1)
                continue;
            lodAssign(bp, tier);
            m_block_tier[bp] = tier;
            m_far_blocks.insert(bp);
            ++added;
        }
        m_far_reassign_cursor = it == m_far_remote.end()
                ? v3s16(-32768, -32768, -32768)
                : *it;
    }
    if (added && getenv("GOANNA_DEBUG_LOD"))
        UtilityFunctions::print("LOD far: ", added, " stored blocks assigned, ", (int)m_far_blocks.size(),
                " in range, grant ", grant, " nodes, radius ", radius, " blocks");
    // How far the far field actually reaches, which is not how far we are
    // allowed to draw. The haze has to close at the edge of what we have or
    // the world is seen ending in clear air (docs/history/far-rendering-log.md,
    // "Background, overlay, foreground"), and what we have is whatever the
    // store held and the server has summarised so far, which on a new world
    // is very little and grows for minutes. Ring histogram by horizontal
    // distance, walked outward to where nine tenths of the blocks are inside,
    // so one straggler beyond a gap does not report a horizon that is not
    // there.
    {
        // Measured per direction rather than as one radius around the player,
        // because the frontier is ragged: the store and the summaries fill
        // outward at whatever rate the server generates, so the field reaches
        // much further one way than another for most of the time it is
        // filling. A single radius describes the directions that happen to
        // hold the most blocks, which are the ones that least need hiding,
        // and leaves the sparse ones ending in clear air. That is why the
        // haze looked right sometimes and not most of the time.
        //
        // Eight sectors, each with its own ring histogram and its own ninetieth
        // percentile, and the extent is the lower quartile across the sectors
        // that hold anything: how far you can see in a poor direction rather
        // than a good one. A sector holding nothing at all is skipped, since
        // the live range floor already covers it.
        //
        // The upper quartile is taken as well, and it is the other half of
        // the answer. One radius cannot describe a ragged frontier, and
        // closing the haze at the poor direction's radius means every good
        // direction has its real terrain flattened to sky colour: measured
        // on the test world at a 1024 node grant, the extent was 496 nodes
        // while the field itself reached past 900, so nearly half of what
        // the client had built, meshed and drawn was behind solid fog. A
        // depth fog has a begin and an end, so main.gd now begins the haze
        // at the extent and closes it at the reach.
        //
        // Only cells that can be seen count. A buried block, the interior of
        // a hill or the rock under a plain, draws no faces at all: every
        // neighbour is filled, so the mesher culls the lot. Counting them
        // measured how far the ground goes down rather than how far the view
        // goes out, and since the vertical walk fills whole columns of them
        // at once they used to be most of the population.
        constexpr int kSectors = 8;
        constexpr float kPi = 3.14159265f;
        const size_t nrings = (size_t)radius + 2;
        std::vector<int> rings((size_t)kSectors * nrings, 0);
        std::vector<size_t> totals((size_t)kSectors, 0);
        // Filled to its ceiling, so the block above rests on it. Read off the
        // coarsest level, which every chain has whatever it was built from.
        auto solid_lid = [&](const v3s16 &at) -> bool {
            auto it = m_lod_chains.find(at);
            if (it == m_lod_chains.end())
                return false;
            const LodLevel *lv = it->second->forCell(MAP_BLOCKSIZE);
            if (!lv || lv->cells.empty())
                return false;
            const LodLevel::Cell &c = lv->cells[0];
            return (c.flags & LodLevel::kFilled) && (c.top == 0 || c.top >= MAP_BLOCKSIZE);
        };
        auto count_reach = [&](const v3s16 &bp) {
            const v3s16 d = bp - centre;
            const int r = std::max(std::abs(d.X), std::abs(d.Z));
            if (r < 0 || r >= (int)nrings)
                return;
            // Beyond the mesh horizon nothing is drawn, so it must not
            // stretch the fog: the haze closes at the drawn edge and the
            // baked horizon carries the rest behind the wall.
            if (m_far_mesh_radius > 0 && r > m_far_mesh_radius)
                return;
            if (solid_lid(bp) && solid_lid(bp + v3s16(0, 1, 0)))
                return; // buried: draws nothing, so it is not a horizon
            const float a = std::atan2((float)d.Z, (float)d.X); // -pi to pi
            int s = (int)std::floor((a + kPi) / (2.0f * kPi) * (float)kSectors);
            s = std::clamp(s, 0, kSectors - 1);
            ++rings[(size_t)s * nrings + (size_t)r];
            ++totals[(size_t)s];
        };
		// Answered summary areas describe coverage directly and are three orders
		// of magnitude fewer than their constituent mapblocks. Scanning every
		// retained block whenever new summaries arrived turned a full TDL field
		// into a main-thread performance cliff even though rendering took 5 ms.
		// Use one representative surface point per non-air area. Stored-only
		// worlds have no such evidence and retain the block fallback below.
		//
		// Partial areas count. They are drawn, so they are part of the
		// horizon; requiring completeness pinned the reach at the complete
		// core on any world without a provider, where a mapgen chunk
		// boundary keeps most areas partial forever. Measured on a vanilla
		// Mineclonia world: reach stuck at 352 against a 1024 grant, with
		// the drawn fragments beyond it culled by the far plane and the fog
		// closed over them, and fifteen minutes changed nothing.
		size_t covered_areas = 0;
		for (const auto &kv : m_far_requested) {
			const FarAsk &a = kv.second;
			if (!a.answered || a.empty || a.air || a.available_records == 0)
				continue;
			count_reach(kv.first + v3s16(4, 0, 4));
			++covered_areas;
		}
		if (covered_areas == 0) {
			for (const v3s16 &bp : m_far_blocks)
				count_reach(bp);
			// Pruned full-detail surface shells are part of the far view too.
			for (const auto &kv : m_near_blocks)
				if (!m_session->getBlock(kv.first))
					count_reach(kv.first);
		}
        std::vector<int> reach;
        for (int s = 0; s < kSectors; ++s) {
            if (!totals[s])
                continue;
            size_t seen = 0;
            for (size_t r = 0; r < nrings; ++r) {
                seen += (size_t)rings[(size_t)s * nrings + r];
                if (seen * 10 >= totals[s] * 9) {
                    reach.push_back((int)r);
                    break;
                }
            }
        }
        if (reach.empty()) {
            m_far_extent = 0;
            m_far_reach = 0;
        } else {
            std::sort(reach.begin(), reach.end());
            m_far_extent = reach[reach.size() / 4] * MAP_BLOCKSIZE;
            m_far_reach = reach[(reach.size() * 3) / 4] * MAP_BLOCKSIZE;
        }
    }
    // The ridge probe (docs/systems/sky-orchestration.md): how high the drawn
    // terrain stands toward the sun's azimuth, as the eye sees it. main.gd
    // re-bases its dawn ramps on the sun's altitude relative to this, so
    // the true dawn holds until the sun crests what actually occludes it.
    // A max over block tops needs no buried test: a buried block's top
    // always sits under the surface block above it, so it can never win.
    // The near set is small and walked whole; the far set is walked with
    // the same bounded cursor discipline as the prune sweeps above (a full
    // walk cost tens of milliseconds at a 4096 grant), accumulating a
    // cycle's best and publishing when the cursor wraps.
    {
        SkyState sst = m_session->skyState();
        v3f sd = sunDirection(sst.time_of_day, sst.sky.body_orbit_tilt);
        const float ah = std::hypot(sd.X, sd.Z);
        if (ah > 1e-4f) {
            const float ax = sd.X / ah, az = sd.Z / ah;
            // The eye in Luanti node space, the same mapping `centre` uses.
            const float eye_x = around.x, eye_y = around.y, eye_z = -around.z;
            // Inside 128 nodes the canopy beside the player would report a
            // horizon halfway up the sky; the gate is for ridge lines.
            constexpr float kMinDist = 128.0f;
            // cos of about 20 degrees either side of the azimuth.
            constexpr float kCosFan = 0.94f;
            float best_sin = 0.0f, best_h = 0.0f, best_d = 0.0f;
            auto probe = [&](const v3s16 &bp) {
                const float dx = ((float)bp.X + 0.5f) * MAP_BLOCKSIZE - eye_x;
                const float dz = ((float)bp.Z + 0.5f) * MAP_BLOCKSIZE - eye_z;
                const float dh = std::hypot(dx, dz);
                if (dh < kMinDist || dx * ax + dz * az < kCosFan * dh)
                    return;
                const float top = ((float)bp.Y + 1.0f) * MAP_BLOCKSIZE;
                const float dy = top - eye_y;
                if (dy <= 0.0f)
                    return;
                const float s = dy / std::sqrt(dh * dh + dy * dy);
                if (s > best_sin) {
                    best_sin = s;
                    best_h = top;
                    best_d = dh;
                }
            };
            for (const auto &kv : m_near_blocks)
                probe(kv.first);
            const float near_sin = best_sin, near_h = best_h, near_d = best_d;
            best_sin = m_ridge_scan_sin;
            best_h = m_ridge_scan_height;
            best_d = m_ridge_scan_dist;
            constexpr int kRidgeSweep = 24576;
            auto it = m_far_blocks.lower_bound(m_ridge_cursor);
            int visited = 0;
            while (it != m_far_blocks.end() && visited < kRidgeSweep) {
                ++visited;
                probe(*it);
                ++it;
            }
            if (it == m_far_blocks.end()) {
                // Cycle complete: publish and start the next accumulation.
                m_ridge_far_sin = best_sin;
                m_ridge_far_height = best_h;
                m_ridge_far_dist = best_d;
                m_ridge_scan_sin = 0.0f;
                m_ridge_scan_height = 0.0f;
                m_ridge_scan_dist = 0.0f;
                m_ridge_cursor = v3s16(-32768, -32768, -32768);
            } else {
                m_ridge_scan_sin = best_sin;
                m_ridge_scan_height = best_h;
                m_ridge_scan_dist = best_d;
                m_ridge_cursor = *it;
            }
            if (near_sin > m_ridge_far_sin) {
                m_ridge_sin = near_sin;
                m_ridge_height = near_h;
                m_ridge_dist = near_d;
            } else {
                m_ridge_sin = m_ridge_far_sin;
                m_ridge_height = m_ridge_far_height;
                m_ridge_dist = m_ridge_far_dist;
            }
        }
    }
    lodRequestSummaries(centre, radius);
}

// The other half of the far view: places this client has never been. The
// server mod summarises terrain the server has already generated, at the
// operator's granted distance and rate, and those summaries become coarse
// chains exactly as stored blocks do (docs/systems/far-rendering.md). Areas are
// asked for nearest first, a few in flight, and never asked twice.
void GoannaClient::lodRequestSummaries(const v3s16 &centre, int radius) {
    if (surfaceOffered()) radius = std::min(radius, 512 / MAP_BLOCKSIZE);
    if (!m_session || !m_session->farSummariesOffered())
        return;
	constexpr int kEdge = 8; // blocks per area side
	// Procedural-provider replies are cheap and the 4096-node horizon contains
	// thousands of horizontal areas. Four requests kept the server mostly idle
	// while the balanced reach stalled around 1.5 km. Twelve remains a small
	// bounded network window (the server emits at most four replies per step)
	// but completes the silhouette before spending minutes on refinement.
	constexpr int kMaxFarInflight = 12;
    // How long to leave a partly generated area alone before asking again.
    // Long enough that a server generating steadily is not asked the same
    // question every second, short enough that a player standing still sees
    // the gaps close rather than waiting out the session.
    constexpr double kFarRetryEmptyMs = 20000.0;
    constexpr double kFarRetryPartialMs = 2000.0;
    // The server refuses silently: an area outside its grant, a full queue,
    // a duplicate ask it collapsed, a player it cannot find. Each ask expires
    // on its own clock. The old rule expired the whole window at once, only
    // after 15 seconds with no reply at all, so a window holding even one
    // dropped ask pinned at twelve until every reply went quiet: measured as
    // "requests 12" all session and an effective ask rate under one a second
    // against thousands of areas. The areas stay in m_far_requested, so an
    // expired one is not asked again here until its retry delay passes.
    constexpr double kFarAskTimeoutMs = 10000.0;
    for (auto it = m_far_pending.begin(); it != m_far_pending.end();) {
        if (ms_since(it->second) > kFarAskTimeoutMs)
            it = m_far_pending.erase(it);
        else
            ++it;
    }
    m_far_inflight = (int)m_far_pending.size();
	if (m_far_inflight >= kMaxFarInflight)
        return;
    m_far_scan = clock_t_::now();
    // As many as there is room for, so a server that answers from a store
    // is kept busy rather than asked once a scan. The scan itself is the
    // cost, not the asking, so the best few are kept from one pass.
	const size_t want = (size_t)(kMaxFarInflight - m_far_inflight);
    struct Pick {
        int key;
        v3s16 origin;
    };
    std::vector<Pick> fresh_picks;
    std::vector<Pick> retry_picks;
    // Areas a ray reached. Kept apart because they are the ones the player
    // is looking at, and because they are the only ones allowed past the
    // topological veto below.
    std::vector<Pick> seen_picks;
    // The same rule the mesh queues use, so an area in front of the player is
    // asked about before one behind it at the same range. Until this existed
    // the scan was purely radial, and a player who stood and looked at a
    // horizon watched the ring fill in every direction but the one they were
    // facing (goanna_schedule.h).
    const goanna::ViewPriority vp = viewPriority();
    auto fdiv = [](int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    const v3s16 ac(fdiv(centre.X, kEdge), fdiv(centre.Y, kEdge), fdiv(centre.Z, kEdge));
    const int aradius = radius / kEdge;
    // Vertical window. A fixed one area either side (docs/history/far-rendering-log.md's
    // "seam" defect) was too narrow for a hill or a valley near the player,
    // and widening it to four was worse: nine layers of 512 blocks each per
    // column, of which at most two hold anything a player can see. The rest
    // is sky the server has not generated, so it is never complete and is
    // asked again every retry for the whole session, and solid rock, which is
    // complete and answers with 512 buried blocks. Both crowd out the
    // horizontal fill, which is the frontier anyone actually looks at.
    //
    // So this is now a bound on a walk rather than a window. The layer the
    // player is in is always eligible; a layer above is eligible only once
    // the one below it has answered that terrain reaches its top face, and a
    // layer below only once the one above it has answered that its floor is
    // not solid. See "Lids, layers and the vertical walk" in
    // docs/systems/far-rendering.md.
    const int varadius = std::min(aradius, 4);
    auto answered = [&](const v3s16 &origin) -> const FarAsk * {
        auto it = m_far_requested.find(origin);
        return it != m_far_requested.end() && it->second.answered ? &it->second : nullptr;
    };
    // --- what the player can actually see ----------------------------------
    // The walk below decides eligibility from topology: an area is worth
    // asking for only if the one between it and the player answered that it
    // is open in that direction, and an area the server has nothing for
    // vetoes everything behind it. That encodes an assumption which does not
    // hold in a world generated where players have been. Such a map is
    // corridors of generated chunks with ungenerated gaps between them, and
    // the veto turns every gap into a permanent wall: measured at one vista,
    // 30 areas complete against 90 empty, the far field stopped at 240 nodes
    // of a 512 node grant, and flying out so the server generated the
    // missing ground did not move it by a single area.
    //
    // So ask what is visible instead of what is adjacent. Sample directions
    // around where the player is looking and march the area lattice: whole
    // cells, integer arithmetic, no map access and no geometry, because a
    // ray cannot hit terrain the client does not have. Each ray takes the
    // first area it reaches that has never been described. A ray walks
    // straight through an ungenerated gap, so one gap stops one ray and not
    // the fan, and what is behind it stays reachable on another bearing.
    //
    // This asks for no more than the walk does and never past the grant: it
    // is the same budget of summaries the server already offers, spent on
    // areas the player is looking at rather than on areas that happen to be
    // adjacent.
    std::set<v3s16> ray_picks;
    {
        // Sky and bedrock need no memory to reject. The lattice is bounded
        // vertically by varadius, so a ray leaving through the top or the
        // bottom before it reaches the grant can never find anything, and
        // the march simply stops. Everything else it walks through is an
        // area already answered, which costs a map lookup and no request.
        constexpr int kRayMin = 24;
        constexpr int kRayMax = 192;
        const int rays = kRayMin + (int)((kRayMax - kRayMin) *
                std::clamp(m_far_ray_yield, 0.0f, 1.0f));
        const float stride = 0.5f * (float)kEdge * (float)MAP_BLOCKSIZE;
        const int steps = (int)((float)(radius * MAP_BLOCKSIZE) / stride) + 2;
        // Godot mirrors Z; the lattice is in Luanti coordinates.
        const v3f eye(vp.eye.X, vp.eye.Y, -vp.eye.Z);
        v3f fwd(vp.forward.X, vp.forward.Y, -vp.forward.Z);
        const float flen = fwd.getLength();
        if (flen > 0.001f && rays > 0) {
            fwd /= flen;
            // An orthonormal pair about the view direction.
            v3f up(0, 1, 0);
            if (std::fabs(fwd.Y) > 0.95f)
                up = v3f(1, 0, 0);
            v3f right = fwd.crossProduct(up);
            right.normalize();
            v3f vup = right.crossProduct(fwd);
            int found = 0;
            for (int i = 0; i < rays; ++i) {
                // A counter, not a clock, so a repeated run walks the same
                // directions in the same order.
                m_far_ray_seed = m_far_ray_seed * 1664525u + 1013904223u;
                const float u1 = (float)((m_far_ray_seed >> 8) & 0xFFFF) / 65536.0f;
                m_far_ray_seed = m_far_ray_seed * 1664525u + 1013904223u;
                const float u2 = (float)((m_far_ray_seed >> 8) & 0xFFFF) / 65536.0f;
                // u1 squared crowds the samples toward the middle of the
                // view, which is where the player is looking and where a
                // hole is most worth closing. It is a weight and not a
                // window: the tail still reaches the frustum corners.
                const float theta = 1.22f * u1 * u1;      // up to about 70 degrees
                const float phi = 6.2831853f * u2;
                const float st = std::sin(theta);
                v3f d = fwd * std::cos(theta) + right * (st * std::cos(phi))
                        + vup * (st * std::sin(phi));
                d.normalize();
                v3f p = eye;
                for (int step = 0; step < steps; ++step) {
                    p += d * stride;
                    const v3s16 cell(fdiv((int)std::floor(p.X) / MAP_BLOCKSIZE, kEdge),
                            fdiv((int)std::floor(p.Y) / MAP_BLOCKSIZE, kEdge),
                            fdiv((int)std::floor(p.Z) / MAP_BLOCKSIZE, kEdge));
                    if (std::abs(cell.X - ac.X) > aradius || std::abs(cell.Z - ac.Z) > aradius)
                        break;
                    if (std::abs(cell.Y - ac.Y) > varadius)
                        break;   // out of the lattice: sky above or rock below
                    const v3s16 origin(cell.X * kEdge, cell.Y * kEdge, cell.Z * kEdge);
                    auto at = m_far_requested.find(origin);
                    if (at == m_far_requested.end()) {
                        ray_picks.insert(origin);
                        ++found;
                        break;
                    }
                    if (!at->second.answered)
                        break;   // asked and still in flight; the answer is coming
                    if (at->second.empty || at->second.air)
                        continue; // nothing here to see or to hide what is behind it
                    break;        // answered with ground: it may occlude, stop
                }
            }
            // Smoothed, so one scan that happens to look at the sky does not
            // starve the next. Never reaches zero: kRayMin keeps enough rays
            // alive to notice when the world changes.
            m_far_ray_yield = 0.75f * m_far_ray_yield + 0.25f * ((float)found / (float)rays);
        }
    }

    auto layer_wanted = [&](int ax, int ay, int az) -> bool {
        if (ay == ac.Y)
            return true;
        const int towards = ay > ac.Y ? -1 : 1; // the layer nearer the player
        const FarAsk *n = answered(v3s16(ax * kEdge, (ay + towards) * kEdge, az * kEdge));
        if (!n)
            return false;
        // An area the server has nothing at all for is not evidence about
        // the area beyond it. Letting it open the next one walked the queue
        // out of the bottom of the world: measured over one session, 38 of
        // 105 requests went to the two lowest layers, every one of them came
        // back with 0 of 512 blocks generated, and each cost the server 512
        // VoxelManip reads out of a budget that fills the horizon at about
        // half an area a second. The retry brings this area back once the
        // server has made something here, and then its answer means
        // something (docs/history/far-rendering-log.md, "Where the summary budget
        // actually went").
        if (n->empty)
            return false;
        return ay > ac.Y ? n->open_above : n->open_below;
    };
    // Nearest unrequested area that is not entirely live and not entirely
    // known already. Both conditions used to be centre-of-area tests, which
    // left a band unasked: an area whose centre sat just past the live range
    // but whose near edge was still inside it, and an area where a single
    // sampled cell happened to be known. lodTakeSummaries already keeps only
    // the blocks that are neither live nor chained (a request for an area we
    // partly know just re-describes the part we already have), so asking
    // liberally here costs bandwidth, not correctness.
    auto add_pick = [want](std::vector<Pick> &into, int key, const v3s16 &origin) {
        auto at = into.begin();
        while (at != into.end() && at->key <= key)
            ++at;
        into.insert(at, Pick{key, origin});
        if (into.size() > want)
            into.pop_back();
    };
    // The lattice walk is sliced by Z row and rotates through the whole
    // lattice across calls. At a 4096 node grant the full walk is a 65 by
    // 65 by 9 sweep with a map lookup per cell, and running all of it on
    // every 250 ms firing burned milliseconds of main thread per second on
    // the big worlds while finding nothing new (the field mostly asked,
    // every cell a continue). A slice bounds the cost per call; full
    // coverage still comes around about every two seconds, which was the
    // whole rate of this scan before it was hoisted out of lodUpdateFar.
    // The ray picks above stay global on every call, so what the player is
    // looking at never waits for the rotation.
    const int rows = 2 * aradius + 1;
    const int row_budget = std::max(3, rows / 8);
    const int row0 = m_far_ask_row % rows;
    m_far_ask_row = (m_far_ask_row + row_budget) % rows;
    for (int rz = row0; rz < row0 + row_budget; ++rz) {
        const int az = ac.Z - aradius + (rz % rows);
        for (int ay = ac.Y - varadius; ay <= ac.Y + varadius; ++ay)
            for (int ax = ac.X - aradius; ax <= ac.X + aradius; ++ax) {
                const v3s16 origin(ax * kEdge, ay * kEdge, az * kEdge);
                // Asked once and never again was why a half generated area
                // stayed half generated: the server answers from what it has
                // made so far, and terrain keeps being made afterwards, by
                // this mod's pregeneration and by every other player walking
                // about. An area that came back whole is finished with. One
                // that came back with any ungenerated record in it is asked
                // again once the retry delay has passed.
                auto ask = m_far_requested.find(origin);
                const bool retrying = ask != m_far_requested.end();
                if (ask != m_far_requested.end()) {
                    // No-progress partial answers back off 2, 4, 8 seconds
                    // and so on, up to about four minutes. Partial areas are
                    // drawn now, so the retry is refinement rather than
                    // repair, and an area stuck at 511 of 512 records (a
                    // mapgen chunk boundary the server may never fill) is
                    // not worth 512 VoxelManip reads every half minute for
                    // the rest of the session. Pregeneration offers the
                    // completed area without being asked, so hammering the
                    // same hole cannot make it finish sooner; it only
                    // prevents the frontier from being described.
                    const int shift = std::min<int>(ask->second.stalled_replies, 7);
                    const double retry = ask->second.answered && !ask->second.empty ?
                            kFarRetryPartialMs * (1 << shift) : kFarRetryEmptyMs;
                    if (ask->second.complete || ms_since(ask->second.asked) < retry)
                        continue;
                }
                const int dx = (ax * kEdge + kEdge / 2) - centre.X;
                const int dz = (az * kEdge + kEdge / 2) - centre.Z;
                // The vertical term below only adds, so an area already
                // further out horizontally than the best so far is out before
                // the lookups that term costs.
                // Visibility beats adjacency. An area a ray reached is asked
                // for whatever the walk thinks of the layer it sits in: the
                // walk cannot know about a corridor of generated terrain
                // behind an ungenerated gap, and the ray has just been down
                // one.
                const bool seen = ray_picks.count(origin) != 0;
                if (!seen && !layer_wanted(ax, ay, az))
                    continue;
                // Horizontal distance and the view cone decide the order,
                // and a layer off the player's own is ranked as though it
                // were several areas further out, because the frontier that
                // needs filling is horizontal.
                //
                // The old weight was the vertical offset in blocks, squared
                // and divided by 64, which put a layer four down at 16
                // against 64 for the very next area sideways. So a whole
                // column, five layers of 512 blocks each, was always asked
                // before the next ring out: over one session two thirds of
                // every request went to layers the player cannot see, on a
                // queue that fills about half an area a second. That is what
                // made the horizon arrive as a mosaic rather than as a
                // frontier.
                //
                // kLayerCost is in areas: one layer of vertical offset ranks
                // like this many areas of horizontal distance, so the ground
                // in front of the player fills out to four areas before
                // anything above or below it is asked about, and a hill or a
                // valley near the player is still reached long before a
                // distant one.
                //
                // A layer the server has answered as nothing but air does not
                // count. Under a player flying at 260 nodes the ground is two
                // layers down, and pricing those two layers put it behind some
                // eighty areas of sky, each costing the server 512 reads to
                // say so again: measured as 115 asks in two minutes with the
                // ground under the player still unasked. Sky that has been
                // confirmed is walked through for free, so the ground ranks
                // as it would with the player standing on it.
                constexpr int kLayerCost = 4;
                int layers = 0;
                const int towards = ay > ac.Y ? -1 : 1;
                for (int y = ay; y != ac.Y; y += towards) {
                    const FarAsk *n = answered(v3s16(ax * kEdge, (y + towards) * kEdge, az * kEdge));
                    if (!(n && n->air))
                        ++layers;
                }
                const int dl = layers * kLayerCost * kEdge;
                // In nodes, with the layer walk above standing in for the
                // vertical term. Whether the server has answered that the
                // layers between hold anything is knowledge no geometric rule
                // can have, so ViewPriority takes this distance as measured
                // and contributes the cone and the class band.
                const float measured =
                        std::sqrt((float)(dx * dx + dz * dz + dl * dl)) * (float)MAP_BLOCKSIZE;
                const int key = vp.of(goanna::ViewPriority::kCoverage,
                        goanna::godotCentreOfBlocks(origin, kEdge, MAP_BLOCKSIZE), measured);
                // Do not infer 512-block area coverage from a diagonal
                // sample. Sixteen resident blocks used to vouch for the other
                // 496, permanently skipping precisely the areas that appear
                // as a sparse lattice in the distance. Every area is asked
                // once; m_far_requested suppresses repeats for complete
                // answers and paces retries for incomplete ones. Ray picks
                // are added globally after the slice, and are never-asked by
                // construction, so they cannot be retries.
                if (!seen)
                    add_pick(retrying ? retry_picks : fresh_picks, key, origin);
            }
    }
    // What the player is looking at joins every call, whatever the slice
    // rotation is showing.
    for (const v3s16 &origin : ray_picks) {
        const int dx = origin.X + kEdge / 2 - centre.X;
        const int dz = origin.Z + kEdge / 2 - centre.Z;
        const float measured = std::sqrt((float)(dx * dx + dz * dz)) * (float)MAP_BLOCKSIZE;
        const int key = vp.of(goanna::ViewPriority::kCoverage,
                goanna::godotCentreOfBlocks(origin, kEdge, MAP_BLOCKSIZE), measured);
        add_pick(seen_picks, key, origin);
    }
    // Reserve one slot for healing an old partial area and use the rest for
    // never-seen frontier. Previously distance alone let the same nearest
    // partial areas win all four slots forever. If either class has fewer
    // candidates, the other class uses the spare capacity.
    std::vector<Pick> picks;
    const size_t fresh_quota = want > 1 ? want - 1 : want;
    // What the player is looking at first, then the frontier the walk found,
    // then one slot for healing an old partial area.
    for (size_t i = 0; i < seen_picks.size() && picks.size() < fresh_quota; ++i)
        picks.push_back(seen_picks[i]);
    for (size_t i = 0; i < fresh_picks.size() && picks.size() < fresh_quota; ++i)
        picks.push_back(fresh_picks[i]);
    for (size_t i = 0; i < retry_picks.size() && picks.size() < want; ++i)
        picks.push_back(retry_picks[i]);
    for (size_t i = fresh_quota; i < fresh_picks.size() && picks.size() < want; ++i)
        picks.push_back(fresh_picks[i]);
    for (const Pick &pk : picks) {
        m_far_requested[pk.origin].asked = clock_t_::now();
        m_far_pending[pk.origin] = clock_t_::now();
        m_far_inflight = (int)m_far_pending.size();
        // Cache reads are provisional. Always refresh through the server,
        // even when the cached area used to be complete.
        FarAsk &ask = m_far_requested[pk.origin];
        if (!ask.answered && ask.cache_ticket == 0) {
            const uint64_t ticket = ++m_lod_load_ticket;
            if (m_lod_storage.requestSummary(pk.origin, ticket, 0)) ask.cache_ticket = ticket;
        }
        m_session->requestFarSummary(pk.origin, kEdge, 16);
        if (getenv("GOANNA_DEBUG_LOD"))
            UtilityFunctions::print("LOD far: asked for area ", pk.origin.X, ",", pk.origin.Y, ",",
                    pk.origin.Z);
    }
}

// Parse "farsum <who> <ver> <cell> <ox> <oy> <oz> <edge> <names,csv>|<base64>"
// into coarse chains. Version 7 is a 4 by 4 by 4 field of coarse voxels per
// mapblock: flags, 64 content indices, packed liquid tops, and block-level
// day/night light. Its flags distinguish partial emerged data from a complete
// block, so partial mountains remain drawable but are requested again. Unlike
// the old height record it retains Y occupancy, so
// caves, overhangs and floating islands have ordinary exposed lower faces.
// See block_summary in goanna_server_mod/init.lua. Caller holds the map lock.
void GoannaClient::lodTakeSummaries(const Vector3 &around) {
    if (!m_session)
        return;
    static const int kRecordSize = 92;
    static const int kVer = 7;
    // Record offsets.
    enum { rFlags = 0, rContent = 1, rLiquidTop = 65, rDay = 81, rNight = 82,
        rLiquid = 83, rLiquidMask = 84 };
    struct Reply { std::string message; uint64_t ticket = 0; };
    std::vector<Reply> replies;
    for (auto &msg : m_session->takeFarSummaries()) replies.push_back({std::move(msg), 0});
    while (!m_lod_cached_summaries.empty()) {
        auto &result = m_lod_cached_summaries.front();
        auto ask = m_far_requested.find(result.pos);
        if (ask != m_far_requested.end() && ask->second.cache_ticket == result.ticket)
            replies.push_back({"farsum " + m_session->playerName() + " " + result.message, result.ticket});
        m_lod_cached_summaries.pop_front();
    }
    for (const Reply &reply : replies) {
        const std::string &msg = reply.message;
        const bool cached = reply.ticket != 0;
        if (cached && (m_session->farRenderingGrant() <= 0 || !m_session->farSummariesOffered()))
            continue;
        // "farsum <who> <ver> <cell> <ox> <oy> <oz> <edge> ..."; a mod
        // channel has no unicast, so every client sees every reply and takes
        // its own.
        char who[64] = {0};
        int ver = 0, cell = 0, ox = 0, oy = 0, oz = 0, edge = 0, off = 0;
        const int got = sscanf(msg.c_str(), "farsum %63s %d %d %d %d %d %d %n", who, &ver, &cell,
                &ox, &oy, &oz, &edge, &off);
        if (m_session->playerName() != who)
            continue;
        // A v1 server mod's reply has no version field, so its "ver" here is
        // actually cell (16) and the field count comes up short; either way
        // this is not a reply this client can read, and staying quiet about
        // it would look like the far field had simply gone empty. Once per
        // reply, not once per record.
        if (got != 7 || ver != kVer) {
            UtilityFunctions::push_error("goanna_server_mod's far summary reply does not match "
                    "protocol version 7 (an older mod?); update goanna_server_mod. Message: ",
                    String(msg.substr(0, 80).c_str()));
            continue;
        }
        // This reply answers this client's ask for this area, so release
        // exactly that slot. The old accounting decremented one shared
        // counter per message before the name check, so another client's
        // replies freed slots this client's asks were still using, and a
        // silently dropped ask never freed its slot at all (the sweep in
        // lodRequestSummaries now times those out one by one).
        const v3s16 origin(ox, oy, oz);
        if (cached) {
            auto ask = m_far_requested.find(origin);
            if (ask == m_far_requested.end() || ask->second.cache_ticket != reply.ticket) continue;
        } else {
            m_far_pending.erase(origin);
            m_far_inflight = (int)m_far_pending.size();
        }
        if (cell != 16 || edge <= 0 || edge > 16)
            continue;
        const size_t bar = msg.find('|', off);
        if (bar == std::string::npos)
            continue;
        // names
        std::vector<content_t> ids;
        ids.push_back(CONTENT_AIR); // index 0: none
        int unresolved = 0;
        std::string first_unresolved;
        {
            std::string csv = msg.substr(off, bar - off);
            while (!csv.empty() && csv.back() == ' ')
                csv.pop_back();
            size_t pos = 0;
            const NodeDefManager *ndef = m_session->nodeDefs();
            while (pos <= csv.size() && !csv.empty()) {
                size_t comma = csv.find(',', pos);
                std::string name = csv.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
                pos = comma == std::string::npos ? csv.size() + 1 : comma + 1;
                // CONTENT_UNKNOWN, not CONTENT_AIR: NodeDefManager::get(name)
                // itself defaults there when getId fails, and its tile is
                // unknown_node.png, the classic magenta checker, for exactly
                // this reason. Defaulting to air instead (found while chasing
                // docs/develop/launch-target.md's purple cells) turned a name this
                // client cannot resolve into an invisible hole, which is a
                // worse failure than an ugly one: a hole reads as there being
                // nothing there at all.
                content_t id = CONTENT_UNKNOWN;
                if (ndef && !name.empty())
                    ndef->getId(name, id);
                if (id == CONTENT_UNKNOWN) {
                    ++unresolved;
                    if (first_unresolved.empty())
                        first_unresolved = name;
                }
                ids.push_back(id);
            }
        }
        const std::string blob = base64_decode(msg.substr(bar + 1));
        const size_t total = (size_t)edge * edge * edge;
        if (blob.size() < total * kRecordSize)
            continue;
        if (!cached) {
            m_far_requested[origin].cache_ticket = 0; // late disk reads cannot replace this reply
            const size_t name_end = msg.find(' ', 7);
            if (name_end != std::string::npos)
                m_lod_storage.saveSummary(origin, msg.substr(name_end + 1));
        }
        // Record the ask even for a reply nobody asked for, which is how the
        // mod hands over an area its pregeneration has just finished, and
        // count how much of it the server actually had. Every record
        // Complete means the area is done and never needs asking again. A
        // partial record is still rendered, but remains due for retry: v5
        // treated any emerged fragment as complete and permanently cached
        // its unknown cells as holes through mountains.
        size_t available_records = 0, complete_records = 0;
        // Which way this area is worth walking from, which is what replaces
        // the fixed window of layers in lodRequestSummaries. Terrain reaching
        // the area's top face means it may carry on above; air anywhere along
        // the area's floor means what is under it could be seen. A layer of
        // solid rock is neither, and it is most of what a nine layer window
        // spent its requests on.
        bool open_above = false, open_below = false;
        bool any_ground = false;
        for (size_t i = 0; i < total; ++i) {
            const uint8_t *r = (const uint8_t *)blob.data() + i * kRecordSize;
            const bool available = (r[rFlags] & 16) != 0;
            const bool complete = (r[rFlags] & 8) != 0;
            if (available) {
                ++available_records;
                if (complete)
                    ++complete_records;
                for (int c = 0; c < 64 && !any_ground; ++c)
                    any_ground = r[rContent + c] > 0 && r[rContent + c] < 255;
            }
            const int ly = (int)((i / (size_t)edge) % (size_t)edge);
            if (ly != 0 && ly != edge - 1)
                continue;
            // Downward asks whether the floor is solid, and a block the
            // server has not generated is not known to be solid, so it does
            // not stop the walk. Without that a player flying above a column
            // the server has never made would get an ungenerated answer for
            // their own layer and never ask about the ground under it.
            // Upward asks for evidence instead, terrain reaching the top
            // face, because nothing is the usual answer up there and taking
            // it as a reason to climb is the scan this replaces.
            if (ly == 0 && !available)
                open_below = true;
            if (!available)
                continue;
			for (int z = 0; z < 4; ++z)
                for (int x = 0; x < 4; ++x) {
                    const uint8_t bottom = r[rContent + (z * 4) * 4 + x];
                    const uint8_t top = r[rContent + (z * 4 + 3) * 4 + x];
                    if (ly == edge - 1 && top > 0 && top < 255)
                        open_above = true;
                    if (ly == 0 && (bottom == 0 || bottom == 255))
                        open_below = true;
                }
        }
        FarAsk &ask = m_far_requested[v3s16(ox, oy, oz)];
        const bool made_progress = !ask.answered || available_records > ask.available_records ||
                complete_records > ask.complete_records;
        if (made_progress)
            ask.stalled_replies = 0;
        else if (ask.stalled_replies < 255)
            ++ask.stalled_replies;
        ask.asked = clock_t_::now();
        ask.complete = !cached && complete_records == total;
        ask.available_records = (uint16_t)std::min<size_t>(available_records, UINT16_MAX);
        ask.complete_records = (uint16_t)std::min<size_t>(complete_records, UINT16_MAX);
        ask.answered = true;
        ask.empty = available_records == 0;
        ask.air = available_records > 0 && !any_ground;
        ask.open_above = open_above;
        ask.open_below = open_below;
        // Publish whatever the server had. This used to wait for the whole
        // 8-cubed area to be complete, so one ungenerated mapblock (the
        // normal state at a mapgen chunk boundary: Luanti generates five
        // blocks tall, an area is eight) held back the other 511 for the
        // whole session, and the horizon was full of 128-node holes that
        // never closed. A partial area drawn now is half a hill for a while;
        // an atomic one was a hole through the mountain forever. The records
        // that are missing stay unknown rather than invented, the area stays
        // due for retry until it is complete, and a later reply's summary
        // chains replace these ones, so the half hill heals as the server
        // generates.
        // The wire record is a 4 by 4 by 4 field of 4-node voxels, so 4 nodes is the
        // finest level a summary can honestly fill, and every level from
        // there up is built rather than only that one. A region reads its own
        // tier's cell out of a block's chain, and a chain holding one level
        // answers "nothing known" at every other, so a coarse region beside
        // summarised terrain culled its whole boundary against it and the two
        // never joined. Building the rest recursively reduces the same voxel
        // field twice more, without discarding its Y occupancy.
        const int first_level = BlockLodChain::levelForCell(4);
        int taken = 0;
        int dbg_miny = 32767, dbg_maxy = -32768;
        for (size_t i = 0; i < total; ++i) {
            const uint8_t *r = (const uint8_t *)blob.data() + i * kRecordSize;
            if (!(r[rFlags] & 16))
                continue; // no emerged data: stays unknown, never invented
            const v3s16 bp(ox + (int)(i % edge), oy + (int)((i / edge) % edge),
                    oz + (int)(i / (edge * edge)));
            if (fineOffered() && !(r[rFlags] & 32) && (r[rFlags] & 8)) {
                auto inserted = m_fine_states.try_emplace(bp);
                if (!cached && !inserted.second && inserted.first->second.token &&
                        !inserted.first->second.pending)
                    inserted.first->second.asked = {};
                m_far_blocks.insert(bp); // known air also replaces a predicted crown
            }
            if (m_session->getBlock(bp))
                continue; // live: known better
            if (m_near_blocks.count(bp))
                continue; // resident exact mesh: visibly known better
            {
                // A chain from the store or from live nodes is known better
                // than a summary and stays. One built from an earlier summary
                // is replaced: that is how a server's real summary of a block
                // it has just generated takes over from the provider's guess,
                // and how a changed block reaches a client that is offered
                // its area again.
                auto old = m_lod_chains.find(bp);
                if (old != m_lod_chains.end() && (!old->second->summary || old->second->fine_available))
                    continue;
            }
            auto name_of = [&](uint8_t idx, content_t fallback) -> content_t {
                return idx != 0 && idx < ids.size() ? ids[idx] : fallback;
            };
            auto ch_owned = std::make_shared<BlockLodChain>();
            BlockLodChain &ch = *ch_owned;
            ch.surface_shell = (r[rFlags] & 32) != 0;
            for (LodLevel &lv : ch.level)
                lv = LodLevel();
            ch.fine_available = false;
            ch.fine_filled.fill(0);
            ch.fine_occludes.fill(0);
            ch.fine_record_mask.fill(0);
            ch.fine_record_base.fill(0);
            ch.fine_records.clear();
            bool any_filled = false;
            const uint8_t day = decode_light(r[rDay]);
            LodLevel &lv = ch.level[first_level];
            lv.cell = 4;
            lv.n = 4;
            lv.cells.assign(64, LodLevel::Cell());
            lv.terrain.clear();
            const NodeDefManager *ndef = m_session->nodeDefs();
            for (int z = 0; z < 4; ++z)
                for (int y = 0; y < 4; ++y)
                    for (int x = 0; x < 4; ++x) {
                        const int ci = (z * 4 + y) * 4 + x;
                        const uint8_t code = r[rContent + ci];
                        if (code == 255)
                            continue;
                        LodLevel::Cell &c = lv.at(x, y, z);
                        c.flags = LodLevel::kKnown;
                        if (code != 0) {
                            const content_t content = name_of(code, CONTENT_UNKNOWN);
                            const ContentFeatures &f = ndef->get(content);
                            // A summary carries node identities, not a promise
                            // that every non-air identity has visible geometry.
                            // In particular Mineclonia stores large volumes of
                            // airlike barrier/structure nodes. Treating those as
                            // cubes exposes their item/PBR texture at range even
                            // though the near mesher correctly draws nothing.
                            // Keep this classification in step with buildLodChain.
                            const bool visible = f.drawtype != NDT_AIRLIKE;
                            const bool solid = visible && f.visuals &&
                                    f.visuals->solidness == 2;
                            const bool filled = visible && (solid ||
                                    (f.visuals && f.visuals->visual_solidness >= 1) ||
                                    f.isLiquid());
                            if (filled) {
                                c.flags |= LodLevel::kFilled;
                                if (solid)
                                    c.flags |= LodLevel::kOccludes;
                                for (int d = 0; d < 6; ++d)
                                    c.face[d] = content;
                                // A summary voxel is one content id for four
                                // nodes and says nothing about how many of them
                                // there were, so the honest reading is full.
                                // Openness therefore begins at cell 8, where it
                                // is the count of filled 4-voxels among eight,
                                // and that is the tier the wall of cubes is at.
                                c.coverage = 255;
                                any_filled = true;
                            }
                        }
                        const bool has_liquid =
                                (r[rLiquidMask + ci / 8] & (1u << (ci % 8))) != 0;
                        if (has_liquid) {
                            c.flags |= LodLevel::kLiquid;
                            c.liquid = name_of(r[rLiquid], CONTENT_UNKNOWN);
                            c.liquid_top = (r[rLiquidTop + ci / 4] >> ((ci % 4) * 2)) & 3;
							any_filled = true;
						}
					}
			// Complete provider records include known empty and deliberately
			// omitted buried-interior blocks so an area can be atomically complete.
			// They are useful protocol evidence, not drawable objects. Retaining a
			// chain for each one grew a 4 km height field past a million blocks and
			// made retiering dominate the main thread despite an idle renderer.
            if (!any_filled) {
                // Known empty supersedes an older cached summary. Unknown
                // records above deliberately keep their provisional cover.
                auto old = m_lod_chains.find(bp);
                if (old != m_lod_chains.end() && old->second->summary) {
                    lodForget(bp);
                    m_far_remote.erase(bp);
                    m_far_blocks.erase(bp);
                    m_block_tier.erase(bp);
                }
                continue;
            }
			// The wire only has one light pair for the block. Applying its
            // maximum to every occupied cell made the interior of hills as
            // bright as their tops. Reconstruct the useful part of sky light
            // from the occupancy we do have: known air with an unobstructed
            // column to the block's top carries the summary light. Faces read
            // light from their adjacent air cell, so exposed terrain remains
            // lit while caves and undersides no longer glow.
            for (int z = 0; z < 4; ++z)
                for (int x = 0; x < 4; ++x) {
                    bool sky_open = true;
                    for (int y = 3; y >= 0; --y) {
                        LodLevel::Cell &c = lv.at(x, y, z);
                        if (!(c.flags & LodLevel::kKnown)) {
                            sky_open = false;
                            continue;
                        }
                        if (!(c.flags & LodLevel::kFilled)) {
                            c.flags |= LodLevel::kLit;
                            c.day = sky_open ? day : 0;
                            // One block-wide maximum cannot locate a torch;
                            // spreading it through all 64 cells makes whole
                            // distant hills emissive. Local/store chains have
                            // spatial light, but a summary stays dark rather
                            // than inventing its position.
                            c.night = 0;
                        }
                        if (c.flags & LodLevel::kOccludes)
                            sky_open = false;
                    }
                }
            buildLodMipLevels(ch, first_level);
            buildLodTerrainSurface(ndef, ch, first_level);
            // A disk summary is provisional. A fresh server reply restores
            // its current-source shading and supersedes the cached chain.
            ch.stored = cached;
            ch.summary = true;
            m_lod_chains[bp] = std::move(ch_owned);
            m_lod_chain_missing.erase(bp);
            // The regions beside this block share corners with it now, and
            // its own region, if it is in one already, holds a changed chain.
            lodDirtyAround(bp, nullptr);
            {
                auto mit = m_lod_member.find(bp);
                if (mit != m_lod_member.end())
                    lodMarkDirty(mit->second);
            }
            if (any_filled) {
                // The same tier a stored block at this distance would get,
                // floored at the finest level a summary can fill. It used to
                // be that floor whatever the distance, so a summarised block
                // was drawn at 4 node cells a kilometre away while the stored
                // block beside it was at 16, which put the two in different
                // regions that could not cull against each other.
                int tier = lodTierFor(bp, around, false);
                while (tier < lodTierCount() && lodCellFor(tier) < 4)
                    ++tier;
                m_far_remote.insert(bp);
                if (tier >= 1) {
                    lodAssign(bp, tier);
                    m_block_tier[bp] = tier;
                    m_far_blocks.insert(bp);
                    dbg_miny = std::min(dbg_miny, (int)bp.Y);
                    dbg_maxy = std::max(dbg_maxy, (int)bp.Y);
                    ++taken;
                }
            }
        }
        if (getenv("GOANNA_DEBUG_LOD"))
            UtilityFunctions::print("LOD far: summary area ", ox, ",", oy, ",", oz, " gave ", taken,
                    " blocks, blockY ", dbg_miny, "..", dbg_maxy, ", available ",
                    (int)available_records, "/", (int)total, ", complete ",
                    (int)complete_records, "/", (int)total, ", names ", (int)ids.size() - 1, " (", unresolved,
                    " unresolved, first \"", String(first_unresolved.c_str()), "\")");
    }
}

} // namespace goanna
