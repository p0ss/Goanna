// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// GoannaClient's far field tiers and regions. update_lod is the per frame
// step: it retiers blocks as the player moves and drives everything below.
// Here are the tier and region arithmetic (lodTierFor, lodRegionFor,
// lodCellFor) and the view priority every scheduler shares; region
// membership and dirt (lodAssign, lodMarkDirty, lodDirtyAround, lodForget,
// the near hand-off); chains from the LodStorage worker (lodStartStorage,
// lodRequestChain, lodCollectChains); lodRebuild, which picks the regions to
// capture; lodPublishRegion, which puts a finished region mesh in the scene;
// lodReset; and the far settings. Blocks beyond the live map, server
// summaries and the horizon are in goanna_client_far.cpp, the mesh jobs in
// goanna_client_jobs.cpp, and the surface and fine data halves in
// goanna_client_surface.cpp and goanna_client_fine.cpp.
//
// Threads: main thread except prepareLodUpload, which fills worker-owned
// value arrays. Chains are prepared on the LodStorage worker, which has its
// own queue and mutex (goanna_lod_storage.h); lodRequestChain and
// lodCollectChains are this side of it.

#include "goanna_client_internal.h"

using namespace godot;

namespace goanna {

void GoannaClient::set_lod_distance(int blocks) {
    if (blocks < 0)
        blocks = 0;
    if (blocks == m_lod_distance)
        return;
    m_lod_distance = blocks;
    m_lod_retier_pending = true;
    m_lod_retier_cursor = v3s16(-32768, -32768, -32768);
    if (m_session) { // every block may change tier
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_block_tier)
            m_session->requeueBlock(kv.first);
    }
}


void GoannaClient::set_lod_cell(int nodes) {
    // Protocol summaries retain cell 4 as their finest occupancy. Keeping the
    // exposed boundary consistent across sources is more important than a
    // cell-2 local-store exception, so supported presentation levels begin at
    // 4 (then 8 or 16 when explicitly requested).
    int cell = 4;
    while (cell * 2 <= nodes && cell * 2 <= MAP_BLOCKSIZE)
        cell *= 2;
    if (cell == m_lod_cell)
        return;
    m_lod_cell = cell;
    lodReset();
}

// --- far rendering: tiers and regions (docs/design/far-rendering-plan.md rungs 2, 3) ---

// Tier 0 is the live Luanti mesh. The five cached mesh tiers retain cell
// sizes 1, 2, 4, 8 and 16. Cached one-node geometry preserves tree silhouettes
// beyond the live radius, without keeping those blocks active on the server.
int GoannaClient::lodTierCount() const {
    return BlockLodChain::kLevels;
}

int GoannaClient::lodCellFor(int tier) const {
    // Protocol summaries start at m_lod_cell (normally cell 4), while exact
    // chains retain finer rungs. This is the fallback pass used for summaries;
    // lodBuildRegion separately selects 1 << (tier - 1) for exact data.
    const int rung = 1 << std::clamp(tier - 1, 0, BlockLodChain::kLevels - 1);
    return std::min(MAP_BLOCKSIZE, std::max(m_lod_cell, rung));
}

// Region edge, in blocks. Keep the finest pass at roughly 32 cells per axis:
// an indivisible cell-1 build over the old four-block edge visited a 64-cubed
// volume and took 16 to 42 ms by itself, making any per-frame time budget
// meaningless. Coarser tiers grow spatially while retaining the same meshing
// workload and better batching at distance.
int GoannaClient::lodRegionBlocks(int tier) const {
    // Two mapblocks at cell 1, four at cell 2, through 32 at cell 16.
    // This bounds work per region while batching the wider distant bands.
    return 1 << std::clamp(tier, 1, BlockLodChain::kLevels);
}

GoannaClient::LodRegionKey GoannaClient::lodRegionFor(int tier, const v3s16 &bp) const {
    const int rb = lodRegionBlocks(tier);
    auto fdiv = [](int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    LodRegionKey k;
    k.tier = tier;
    k.pos = v3s16(fdiv(bp.X, rb), fdiv(bp.Y, rb), fdiv(bp.Z, rb));
    return k;
}

// Which tier a block should be drawn at, from its distance to the player.
// Thresholds double per tier, and a block only comes back finer once it is
// well inside the threshold it crossed, or a player standing at the edge
// rebuilds the same blocks every step.
// Godot's camera forward from pitch and yaw. main.gd builds the camera the
// same way (Basis.from_euler with rotation.x = pitch, rotation.y = yaw, and
// forward at -Z), so this is the direction the player is actually looking,
// not the Luanti look_dir above, which is mirrored in Z and exists only to
// tell the server what to send.
void GoannaClient::setViewAngles(float pitch_deg, float yaw_deg) {
    constexpr float kDeg = 3.14159265358979323846f / 180.0f;
    const float p = pitch_deg * kDeg, y = yaw_deg * kDeg;
    const v3f dir(-std::cos(p) * std::sin(y), std::sin(p), -std::cos(p) * std::cos(y));
    // Five degrees. Small enough that a mouse twitch does not shut the cone,
    // large enough that a real look around does.
    if (m_view_dir.getLengthSQ() < 0.5f || dir.dotProduct(m_view_dir) < 0.996f)
        noteViewMoved();
    m_view_dir = dir;
}

// The one scheduling rule, built from where the camera is and what it is
// doing. See goanna_schedule.h for what the numbers mean.
goanna::ViewPriority GoannaClient::viewPriority() const {
    // The camera holding still is the signal that the player is looking at
    // something rather than travelling through it, so the cone relaxes and
    // the schedulers fill outward in every direction instead of only forward.
    // Two seconds before it starts to open and eight more to open completely:
    // long enough that a glance sideways does not lose the weighting, short
    // enough that standing and watching a horizon fills the whole horizon.
    constexpr double kHoldMs = 2000.0;
    constexpr double kOpenMs = 8000.0;
    goanna::ViewPriority vp;
    vp.eye = v3f(m_lod_centre.x, m_lod_centre.y, m_lod_centre.z);
    vp.forward = m_view_dir;
    vp.widen = (float)std::clamp((ms_since(m_view_still) - kHoldMs) / kOpenMs, 0.0, 1.0);
    return vp;
}

int GoannaClient::lodTierFor(const v3s16 &bp, const Vector3 &around, bool live) const {
    if (m_lod_distance <= 0)
        return 0;
    Vector3 centre((bp.X + 0.5f) * MAP_BLOCKSIZE, (bp.Y + 0.5f) * MAP_BLOCKSIZE,
            -(bp.Z + 0.5f) * MAP_BLOCKSIZE);
    auto cur = m_block_tier.find(bp);
    const int current = cur == m_block_tier.end() ? 0 : cur->second;
    const Vector3 delta = centre - around;
    int tier = goanna::lodProjectedTier(v3f(delta.x, delta.y, delta.z), current, live,
            (float)m_lod_distance * MAP_BLOCKSIZE, m_lod_focal_pixels);
    if (surfaceOffered() && fineOffered()) {
        const float dx = std::max(0.0f, std::abs((float)delta.x)-8.0f);
        const float dz = std::max(0.0f, std::abs((float)delta.z)-8.0f);
        const int cell = goanna::surfaceForestCell(std::sqrt(dx*dx+dz*dz));
        if (cell <= 4) tier = std::min(tier, cell == 1 ? 1 : cell == 2 ? 2 : 3);
    }
    return tier;
}

void GoannaClient::lodStartStorage() {
    if (m_lod_storage.running() || !m_session || !m_session->contentPrepared())
        return;
    GoannaSession *session = m_session.get();
    BlockStore *store = session->store();
    const std::string directory = store ? store->directory() + "/lod-v1" : "";
    m_lod_storage.start(directory, session->terrainVisualDefinitions(),
            [store](v3s16 bp, std::string &source) {
                uint8_t version = 0;
                if (!store || !store->get(bp, version, source)) return false;
                source.insert(source.begin(), (char)version);
                return true;
            },
            [session](v3s16 bp, const std::string &source) {
                if (source.empty()) return std::shared_ptr<BlockLodChain>();
                MapBlock block(bp, session);
                std::istringstream input(source.substr(1), std::ios::binary);
                block.deSerialize(input, (uint8_t)source[0], false);
                block.deSerializeNetworkSpecific(input);
                auto chain = std::make_shared<BlockLodChain>();
                buildLodChain(session->nodeDefs(), &block, *chain);
                return chain;
            },
            [store](v3s16 region) {
                std::vector<uint8_t> mask;
                if (store) store->regionMask(region, mask);
            });
}

bool GoannaClient::lodRequestChain(v3s16 bp, bool replace_summary) {
    if ((!replace_summary && m_lod_chains.count(bp)) || m_lod_loads.count(bp)) return true;
    if (!m_session || !m_lod_storage.running()) return false;
    const uint64_t revision = m_session->blockRevision(bp);
    const uint64_t ticket = ++m_lod_load_ticket;
    LodStorage::LiveBuild live;
    if (MapBlock *block = m_session->getBlock(bp)) {
        // Copy only immutable nodes while holding the map lock. Classification,
        // lighting reduction and all five LOD levels are worker work.
        auto nodes = std::make_shared<std::vector<MapNode>>();
        nodes->reserve(4096);
        for (int z = 0; z < 16; ++z)
            for (int y = 0; y < 16; ++y)
                for (int x = 0; x < 16; ++x)
                    nodes->push_back(block->getNodeNoCheck(x, y, z));
        const NodeDefManager *ndef = m_session->nodeDefs();
        const std::string shared_key = getenv("GOANNA_NO_SHARED_TERRAIN") ? "" :
                "live:" + m_session->terrainPeer() + ":" +
                std::to_string(m_session->terrainVisualDefinitions()) + ":" + m_session->blockContentDigest(bp);
        live = [nodes, ndef, bp, shared_key] {
            return sharedLodChain(shared_key, [nodes, ndef, bp] {
            MapBlock copy(bp, nullptr);
            size_t i = 0;
            for (int z = 0; z < 16; ++z)
                for (int y = 0; y < 16; ++y)
                    for (int x = 0; x < 16; ++x)
                        copy.setNodeNoCheck(x, y, z, (*nodes)[i++]);
            auto chain = std::make_shared<BlockLodChain>();
            buildLodChain(ndef, &copy, *chain);
            return chain;
            });
        };
    } else if (m_session->farRenderingGrant() <= 0) {
        m_lod_chain_missing.insert(bp);
        return true;
    }
    const int priority = viewPriority().of(goanna::ViewPriority::kCoverage,
            goanna::godotCentreOfBlock(bp, MAP_BLOCKSIZE)) % goanna::ViewPriority::kClassStride;
    if (!m_lod_storage.request(bp, ticket, priority, std::move(live))) return false;
    m_lod_loads[bp] = {ticket, revision};
    return true;
}

void GoannaClient::lodCollectChains() {
    if (!m_session) return;
    const auto start = clock_t_::now();
    LodStorage::Result result;
    int count = 0;
    while (count < 16 && ms_since(start) < 2.0 && m_lod_storage.next(result)) {
        ++count;
        if (result.primed) {
            m_lod_primed_regions.push_back(result.pos);
            m_far_dirty = true;
            continue;
        }
        if (result.summary) {
            if (!result.message.empty()) m_lod_cached_summaries.push_back(std::move(result));
            continue;
        }
        auto pending = m_lod_loads.find(result.pos);
        if (pending == m_lod_loads.end() || pending->second.ticket != result.ticket) continue;
        const uint64_t fine_token = pending->second.fine_token;
        const uint64_t fine_fingerprint = pending->second.fine_fingerprint;
        const uint64_t revision = pending->second.revision;
        m_lod_loads.erase(pending);
        auto fine = m_fine_states.find(result.pos);
        if (fine_token && (fine == m_fine_states.end() || fine->second.token != fine_token ||
                m_near_blocks.count(result.pos))) continue;
        if (revision != m_session->blockRevision(result.pos)) {
            lodEnqueueChain(result.pos);
            continue;
        }
        const bool wanted = m_lod_member.count(result.pos) ||
                m_lod_chain_waiters.count(result.pos) ||
                (!m_surface_revision.empty() && m_far_blocks.count(result.pos));
        if (!wanted) continue;
        if (result.chain) {
            // Fresh server nodes may replace retained data outside the near
            // field. The revision check above protects newer live updates.
            auto old = m_lod_chains.find(result.pos);
            if (old == m_lod_chains.end() || old->second->summary || fine_token) {
                if (fine_token) {
                    fine->second.fingerprint=fine_fingerprint;
                    fine->second.applied=result.chain;
                }
                m_lod_chains[result.pos] = std::move(result.chain);
                if (fine_token) m_block_tier[result.pos]=lodTierFor(result.pos,m_lod_centre,false);
                if (!fine_token) m_far_remote.erase(result.pos);
                if (!m_surface_revision.empty() && m_far_blocks.count(result.pos) &&
                        (fine_token || !m_lod_member.count(result.pos)))
                    lodAssign(result.pos, lodTierFor(result.pos, m_lod_centre, false));
                lodDirtyAround(result.pos, nullptr);
            }
            ++m_lod_chains_built_last;
        } else {
            m_lod_chain_missing.insert(result.pos);
        }
        auto waiters = m_lod_chain_waiters.find(result.pos);
        if (waiters != m_lod_chain_waiters.end()) {
            for (const LodRegionKey &key : waiters->second)
                if (m_lod_regions.count(key)) lodMarkDirty(key);
            m_lod_chain_waiters.erase(waiters);
        }
    }
}

void GoannaClient::set_store_path(const String &root) {
    m_store_root = root;
}

void GoannaClient::set_far_distance(int nodes) {
    // Negative means "whatever the server grants". The graphics profiles and
    // goanna.cfg store -1 with that meaning, and clamping it to 0 here turned
    // the whole far field off while the HUD still showed the grant: radius one
    // block, no summary requests, and every pruned near block forgotten
    // instead of degrading to a far tier.
    if (nodes < 0) {
        m_far_distance_explicit = false;
    } else {
        m_far_distance = std::clamp(nodes, 0, 8192);
        m_far_distance_explicit = true;
    }
    m_far_dirty = true;
}

void GoannaClient::set_occluder_boxes(bool on) {
    if (on == m_occluder_boxes)
        return;
    m_occluder_boxes = on;
    // Chains for the near field arrive lazily as blocks are (re)assigned;
    // enqueue the ones already resident so coverage does not wait for a
    // world's worth of remeshes.
    if (on)
        // Tier 0 entries, not just surfaced blocks: fully buried live
        // blocks never enter m_near_blocks, and they are exactly the
        // solids the boxes are made of.
        for (const auto &kv : m_block_tier)
            if (kv.second <= 0)
                lodEnqueueChain(kv.first);
}

void GoannaClient::set_occluder_distance(int nodes) {
    m_occluder_distance = std::max(0, nodes);
    // Existing occluders re-evaluate as their regions next rebuild; a
    // measurement sweep restarts the client or waits out the churn.
}

void GoannaClient::set_far_mesh_distance(int nodes) {
    // The knowledge/mesh split (docs/systems/sky-orchestration.md, "The baked
    // horizon"): chains, summaries and the store walk keep filling to the
    // far distance, but region meshes are only built inside this radius;
    // beyond it the terrain is carried by the horizon bake alone, at zero
    // draw calls. 0 or negative means no split, the old behaviour.
    const int v = nodes <= 0 ? 0 : std::clamp(nodes, 256, 8192);
    if (v == m_far_mesh_distance)
        return;
    m_far_mesh_distance = v;
    m_far_dirty = true;
}

void GoannaClient::lodMarkDirty(const LodRegionKey &key) {
    LodRegion &r = m_lod_regions[key];
    r.priority_members_valid = false;
    ++r.state_revision;
    if (!r.dirty) {
        r.dirty = true;
        r.dirty_at = clock_t_::now();
    }
}

// A block has left this region. If the region is already drawing, what is on
// screen now contains geometry that belongs to the near field or to another
// tier, and it hangs over the top of the real thing until the rebuild lands.
// That is worse than a region that draws nothing yet, so it is ranked ahead
// of one rather than behind every one of them.
void GoannaClient::lodMarkStale(const LodRegionKey &key) {
    LodRegion &r = m_lod_regions[key];
    if (r.node)
        r.stale = true;
    lodMarkDirty(key);
}

// A block changing moves the faces its six neighbours cull against it, so
// the regions drawing those neighbours are rebuilt too. The region the block
// itself belongs to is passed as `except` when the caller has already done it.
void GoannaClient::lodDirtyAround(const v3s16 &bp, const LodRegionKey *except) {
    // The six face neighbours, and the four horizontal diagonals as well: the
    // far surface's corners are the mean of the four columns around them, so
    // a column arriving or changing moves a corner shared with the region
    // diagonally beside it, and that region has to be re-meshed or its edge
    // no longer meets this one (docs/history/far-rendering-log.md, "The far field as a
    // surface").
    static const v3s16 around[10] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
            {1, 0, 1}, {1, 0, -1}, {-1, 0, 1}, {-1, 0, -1}};
    for (const v3s16 &o : around) {
        auto it = m_lod_member.find(bp + o);
        if (it == m_lod_member.end())
            continue;
        if (except && it->second == *except)
            continue;
        lodMarkDirty(it->second);
    }
}

bool GoannaClient::lodEnqueueChain(const v3s16 &bp) {
    if (m_lod_chains.count(bp) || m_lod_loads.count(bp) || m_lod_chain_missing.count(bp) ||
            m_lod_chain_queued.count(bp)) return true;
    // Most cells in a far region's 3D halo have no stored source at all.
    // The in-memory index can answer that without disk or a blocking lock;
    // sending every absent cell through a worker overwhelms any queue.
    if (m_session && !m_session->getBlock(bp)) {
        BlockStore *store = m_session->store();
        bool present = false;
        if (!store || (store->tryHas(bp, present) && !present)) return true;
    }
    if (m_lod_chain_queue.size() >= 4096) return false;
    m_lod_chain_queued.insert(bp);
    m_lod_chain_queue.push_back(bp);
    return true;
}

void GoannaClient::lodDropHandoffCount(const LodRegionKey &key) {
    auto count = m_lod_handoff_old_counts.find(key);
    if (count != m_lod_handoff_old_counts.end() && --count->second <= 0) {
        m_lod_handoff_old_counts.erase(count);
        m_lod_frozen_at.erase(key);
    }
}

void GoannaClient::lodAssign(const v3s16 &bp, int tier) {
    auto old = m_lod_member.find(bp);
    // Beyond the mesh horizon a block is known but not drawn: it keeps its
    // chain built (the ridge probe and the horizon bake read it), stays in
    // m_far_blocks, and is pruned by the ordinary sweeps, but it owns no
    // region, so it costs no mesh and no draw. It takes the removal branch
    // below to release any membership it held when the horizon moved, then
    // still enqueues its own chain, which the membership path would have
    // done.
    bool beyond_mesh = false;
    if (tier > 0 && m_far_mesh_radius > 0) {
        const int64_t dx = bp.X - m_far_centre.X;
        const int64_t dz = bp.Z - m_far_centre.Z;
        beyond_mesh = dx * dx + dz * dz >
                (int64_t)m_far_mesh_radius * m_far_mesh_radius;
    }
    if (tier > 0 && !m_surface_revision.empty()) {
        auto chain = m_lod_chains.find(bp);
        if (chain != m_lod_chains.end() && chain->second->surface_shell) {
            const int64_t dx = bp.X - m_far_centre.X, dz = bp.Z - m_far_centre.Z;
            beyond_mesh = beyond_mesh || dx * dx + dz * dz > 32 * 32;
        }
    }
    // A coarse actual summary must not replace a finer forest preview.
    // Keep it as discovery data until the detailed block has been meshed.
    if (tier > 0 && tier < 3 && fineOffered() && surfaceOffered()) {
        auto chain = m_lod_chains.find(bp);
        if (chain != m_lod_chains.end() && chain->second->summary &&
                !chain->second->surface_shell && !chain->second->hasCell(1))
            beyond_mesh = true;
    }
    if (beyond_mesh) {
        lodEnqueueChain(bp);
        tier = -1;
    }
    if (tier > 0) {
        // The player moved away again before a pending batched-near upload.
        // Keep the already visible far owner, release its rebuild freeze and
        // let the ordinary near->far handoff below decide when near data can
        // be discarded.
        auto nh = m_lod_handoff_to_near.find(bp);
        if (nh != m_lod_handoff_to_near.end()) {
            lodDropHandoffCount(nh->second);
            m_lod_handoff_to_near.erase(nh);
        }
    }
    if (tier <= 0) {
        // The block is leaving the far system entirely: it is near-owned,
        // known empty, or out of the grant. A pending far-to-near handoff
        // finishes now, releasing the old region's rebuild freeze. Every
        // caller on this path either has the near mesh already visible or is
        // discarding the block outright, so there is nothing left to wait
        // for; leaving the entry behind froze the old region's mesh over
        // the real terrain for the rest of the session (the HUD's
        // stale-drawn count with an oldest age in the hundreds of seconds).
        lodFinishNearHandoff(bp);
        old = m_lod_member.find(bp); // lodFinishNearHandoff may have erased it
        // Near publication is already delayed until its mesh exists. Retire
        // every far copy accumulated by an interrupted/multi-tier handoff.
        auto pending = m_lod_handoff_far.find(bp);
        if (pending != m_lod_handoff_far.end()) {
            for (const LodRegionKey &key : pending->second.old_regions) {
                LodRegion &r = m_lod_regions[key];
                r.members.erase(bp);
                lodMarkStale(key);
                lodDropHandoffCount(key);
            }
            m_lod_handoff_far.erase(pending);
        }
        if (old != m_lod_member.end()) {
            LodRegion &r = m_lod_regions[old->second];
            r.members.erase(bp);
            lodMarkStale(old->second);
            m_lod_member.erase(old);
        }
        lodDirtyAround(bp, nullptr);
        return;
    }
    const LodRegionKey key = lodRegionFor(tier, bp);
    if (old != m_lod_member.end() && old->second != key) {
        // Do not remove this block from the old mesh yet. Updating logical
        // ownership immediately is useful for constructing the replacement,
        // but rebuilding the old region from that ownership before the new
        // upload lands creates the one-frame (or many-frame under pressure)
        // transparent flash seen at tier boundaries.
        LodFarHandoff &handoff = m_lod_handoff_far[bp];
        if (handoff.old_regions.insert(old->second).second) {
            ++m_lod_handoff_old_counts[old->second];
            m_lod_frozen_at.emplace(old->second, clock_t_::now());
        }
        handoff.target = key;
    }
    m_lod_regions[key].members.insert(bp);
    lodMarkDirty(key);
    m_lod_member[bp] = key;
    lodDirtyAround(bp, &key);
    // Its own chain and its neighbours', for the faces between them.
    static const v3s16 around[6] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
    lodEnqueueChain(bp);
    for (const v3s16 &o : around)
        lodEnqueueChain(bp + o);
}

void GoannaClient::lodBeginNearHandoff(const v3s16 &bp) {
    if (m_lod_handoff_to_near.count(bp))
        return;
    auto old = m_lod_member.find(bp);
    if (old == m_lod_member.end())
        return;
    m_lod_handoff_to_near[bp] = old->second;
    ++m_lod_handoff_old_counts[old->second];
    m_lod_frozen_at.emplace(old->second, clock_t_::now());
}

void GoannaClient::lodFinishNearHandoff(const v3s16 &bp) {
    auto pending = m_lod_handoff_to_near.find(bp);
    if (pending == m_lod_handoff_to_near.end())
        return;
    const LodRegionKey old_key = pending->second;
    auto old = m_lod_member.find(bp);
    if (old != m_lod_member.end() && old->second == old_key) {
        LodRegion &r = m_lod_regions[old_key];
        r.members.erase(bp);
        lodMarkStale(old_key);
        m_lod_member.erase(old);
    }
    lodDropHandoffCount(old_key);
    m_lod_handoff_to_near.erase(pending);
    lodDirtyAround(bp, nullptr);
}

void GoannaClient::lodForget(const v3s16 &bp) {
    m_lod_loads.erase(bp);
    m_lod_chains.erase(bp);
    lodAssign(bp, 0);
}

std::vector<GoannaClient::LodUploadSurface> GoannaClient::prepareLodUpload(LodRegionMesh &mesh) {
    std::vector<LodUploadSurface> prepared;
    std::vector<LodSurface> metadata;
    prepared.reserve(mesh.surfaces.size());
    metadata.reserve(mesh.surfaces.size());
    for (LodSurface &sf : mesh.surfaces) {
        const int nv = (int)sf.pos.size();
        if (!nv || sf.idx.empty()) continue;
        LodUploadSurface out;
        out.verts.resize(nv);
        out.norms.resize(nv);
        out.uvs.resize(nv);
        out.uv2s.resize(nv);
        out.cols.resize(nv);
        out.custom0.resize(nv * 4);
        out.custom2.resize(nv * 4);
        Vector3 *positions = out.verts.ptrw();
        Vector3 *normals = out.norms.ptrw();
        Vector2 *texcoords = out.uvs.ptrw();
        Vector2 *layers = out.uv2s.ptrw();
        Color *colours = out.cols.ptrw();
        uint8_t *light = out.custom0.ptrw();
        uint8_t *extra = out.custom2.ptrw();
        for (int i = 0; i < nv; ++i) {
            positions[i] = Vector3(sf.pos[i].X, sf.pos[i].Y, sf.pos[i].Z);
            normals[i] = Vector3(sf.nrm[i].X, sf.nrm[i].Y, sf.nrm[i].Z);
            texcoords[i] = Vector2(sf.uv[i].X, sf.uv[i].Y);
            layers[i] = Vector2(sf.uv2[i].X, sf.uv2[i].Y);
            const u32 c = sf.col[i];
            colours[i] = Color(((c >> 16) & 0xff) / 255.0f, ((c >> 8) & 0xff) / 255.0f,
                    (c & 0xff) / 255.0f, 1.0f);
            for (int k = 0; k < 4; ++k)
                light[i * 4 + k] = sf.custom0[i * 4 + k];
            for (int k = 0; k < 4; ++k)
                extra[i * 4 + k] = sf.custom2[i * 4 + k];
        }
        out.idx.resize((int)sf.idx.size());
        int32_t *indices = out.idx.ptrw();
        for (size_t i = 0; i < sf.idx.size(); ++i)
            indices[i] = (int)sf.idx[i];
        out.tangents = node_tangents(out.verts, out.norms, out.uvs, out.idx);
        prepared.push_back(std::move(out));
        LodSurface meta;
        meta.texture_id = sf.texture_id;
        meta.liquid = sf.liquid;
        metadata.push_back(std::move(meta));
        // Release raw geometry on the worker, not when publishing the result.
        sf = LodSurface();
    }
    mesh.surfaces = std::move(metadata);
    return prepared;
}

bool GoannaClient::lodUploadSurface(LodRegion &r,
        const std::vector<LodUploadSurface> &surfaces, uint64_t generation) {
    if (r.upload_mesh.is_null() || r.upload_generation != generation) {
        r.upload_mesh.instantiate();
        r.upload_surface = 0;
        r.upload_total = surfaces.size();
        r.upload_generation = generation;
    }
    if (r.upload_surface == surfaces.size()) return true;
    const LodUploadSurface &sf = surfaces[r.upload_surface++];
    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = sf.verts;
    arrays[Mesh::ARRAY_NORMAL] = sf.norms;
    arrays[Mesh::ARRAY_TANGENT] = sf.tangents;
    arrays[Mesh::ARRAY_TEX_UV] = sf.uvs;
    arrays[Mesh::ARRAY_TEX_UV2] = sf.uv2s;
    arrays[Mesh::ARRAY_COLOR] = sf.cols;
    arrays[Mesh::ARRAY_CUSTOM0] = sf.custom0;
    arrays[Mesh::ARRAY_CUSTOM2] = sf.custom2;
    arrays[Mesh::ARRAY_INDEX] = sf.idx;
    r.upload_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays,
            TypedArray<Array>(), Dictionary(), kNodeSurfaceFlags);
    ++m_lod_surfaces_uploaded;
    return r.upload_surface == surfaces.size();
}

Array GoannaClient::lod_uploads() const {
    Array out;
    auto describe = [&](const LodRegion &r, const String &kind) {
        if (r.upload_mesh.is_null()) return;
        Dictionary entry;
        entry["kind"] = kind;
        entry["surface"] = (int64_t)r.upload_surface;
        entry["total"] = (int64_t)r.upload_total;
        entry["generation"] = (int64_t)r.upload_generation;
        entry["staged_mesh"] = (int64_t)r.upload_mesh->get_instance_id();
        entry["visible_mesh"] = r.node && r.node->get_mesh().is_valid()
                ? (int64_t)r.node->get_mesh()->get_instance_id() : 0;
        entry["visible_node"] = r.node ? (int64_t)r.node->get_instance_id() : 0;
        out.push_back(entry);
    };
    for (const auto &entry : m_lod_regions) describe(entry.second, "region");
    for (const auto &entry : m_surface_staged) describe(entry.second.region, "surface");
    return out;
}

void GoannaClient::lodPublishRegion(const LodRegionKey &key, LodRegion &r, const LodRegionMesh &lm,
        std::chrono::steady_clock::time_point t0, int exact_cell_used, int coarse_cell_used) {
    r.priority_members_valid = false;
    if (!m_surface_uploading) {
        ++m_surface_source_revision;
        r.published_ground=lm.ground;
        r.published_chains.clear();
        for (const auto &bp:r.members) {
            auto it=m_lod_chains.find(bp);
            auto owner=m_lod_member.find(bp);
            if (it!=m_lod_chains.end() && owner!=m_lod_member.end() && owner->second==key)
                r.published_chains[bp]=it->second;
        }
    }
    r.building = false;
    r.stale = false; // what is about to be on screen is current again
    r.faces = lm.faces;
    r.quads = lm.quads;
    r.partial = lm.partial;
    r.surfaces = (int)lm.surfaces.size();
    auto finish_handoffs = [&] {
        // This target is now a real uploaded/publishable replacement. Only
        // now may its previous tier regions stop drawing their copy. Require
        // a chain as well: a region built while its source was still queued
        // is not coverage and must not punch out the fallback.
        std::vector<v3s16> far_done;
        for (const v3s16 &bp : r.members) {
            auto hit = m_lod_handoff_far.find(bp);
            if (hit == m_lod_handoff_far.end() || hit->second.target != key)
                continue;
            // A chain still queued may yet arrive, so its handoff waits.
            // One recorded as missing never will, and a handoff waiting on
            // it froze its old regions permanently; release it and let the
            // old regions rebuild from what is actually known.
            if (!m_lod_chains.count(bp) && !m_lod_chain_missing.count(bp))
                continue;
            for (const LodRegionKey &old_key : hit->second.old_regions) {
                // The count is released even when the old region is this
                // region: a block that left for another tier and came back
                // put its own key in old_regions, and skipping the decrement
                // for it left this region frozen at its own gate forever.
                lodDropHandoffCount(old_key);
                if (old_key == key)
                    continue;
                LodRegion &old_region = m_lod_regions[old_key];
                old_region.members.erase(bp);
                lodMarkStale(old_key);
            }
            far_done.push_back(bp);
        }
        for (const v3s16 &bp : far_done)
            m_lod_handoff_far.erase(bp);
        for (const v3s16 &bp : r.members) {
            if (!m_lod_handoff_near.count(bp) || !m_lod_chains.count(bp))
                continue;
            m_block_lights.erase(bp);
            nearDrop(bp);
            m_lod_handoff_near.erase(bp);
        }
    };
    // GOANNA_DEBUG_LOD=1: what each region build produced, per surface, so a
    // tier that lands on the flat colour fallback instead of the array shader
    // says so in the log rather than only in a screenshot.
    static const bool debug_lod = getenv("GOANNA_DEBUG_LOD") != nullptr;
    if (debug_lod) {
        String line = String("LOD region tier ") + String::num_int64(key.tier) + " at " +
                String::num_int64(key.pos.X) + "," + String::num_int64(key.pos.Y) + "," +
                String::num_int64(key.pos.Z) + " cell " + String::num_int64(exact_cell_used) + "/" +
                String::num_int64(coarse_cell_used) +
                " members " + String::num_int64((int)r.members.size()) + " faces " +
                String::num_int64(lm.faces) + " quads " + String::num_int64(lm.quads) + " |";
        for (const LodSurface &sf : lm.surfaces)
            line += String(" tex ") + String::num_int64(sf.texture_id);
        UtilityFunctions::print(line, " ", String::num(ms_since(t0), 2), " ms");
    }
    if (lm.empty()) {
        r.upload_mesh.unref();
        r.upload_surface = 0;
        if (r.node) {
            surfaceRetire(r.node);
            if (r.node) r.node->queue_free();
            r.node = nullptr;
        }
        // Empty is still a valid published result when the captured region
        // is known air. Preserve its coverage metadata; a partial empty
        // capture remains coverage work until its missing chains arrive.
        r.published = true;
        r.published_members = r.members;
        r.published_partial = lm.partial;
        r.published_exact_cell = exact_cell_used;
        r.published_coarse_cell = coarse_cell_used;
        {
        const double lod_ms_now = ms_since(t0);
        ema(m_ms_lod, lod_ms_now);
        m_ms_lod_worst = std::max(m_ms_lod_worst, lod_ms_now);
    }
        finish_handoffs();
        return;
    }
    Ref<ArrayMesh> mesh = r.upload_mesh;
    r.upload_mesh.unref();
    r.upload_surface = 0;
    // Bind at commit, so a settings change during staging cannot leave
    // half the replacement using materials from an obsolete cache.
    int si = 0;
    for (const LodSurface &sf : lm.surfaces) {
        Ref<Material> mat = lodMaterial(sf.texture_id, sf.liquid);
        if (mat.is_valid())
            mesh->surface_set_material(si, mat);
        ++si;
    }
    goanna::append_grass(mesh, true, this, [this](int x, float y, int z) {
        return grassSubmerged(x, y, z, false);
    }, std::max(1, std::min(exact_cell_used, coarse_cell_used)));
    surfaceRetire(r.node);
    if (!r.node) {
        r.node = memnew(MeshInstance3D);
        // Far tiers cast no shadows. The directional map only covers 200
        // nodes of receivers, so a far region's contribution is a poorly
        // sampled long shadow at best, and the cost was measured on
        // 2026-08-30 at the beach on test_world: 3103 far nodes added 948
        // draw calls to every frame's shadow passes (2307 against 1359
        // with them off), about a fifth of the whole frame's draw calls,
        // for around 4 per cent of the shadow primitives. The dawn gate
        // already holds the sun below a ridge's crest, which covers the
        // moment a distant mountain's long shadow would have sold.
        r.node->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
        // And no GI: a far tier's contribution to SDFGI at its distance is
        // nothing, but a static-GI mesh swapping inside cascade range asks
        // the GPU to re-voxelise, and the far field swaps constantly while
        // the player travels. The flying hitch census (2026-08-31: medians
        // healthy, 0.1 per cent lows above 100 ms, GPU bound, only while
        // the world arrives) is the tail this is aimed at.
        r.node->set_gi_mode(GeometryInstance3D::GI_MODE_DISABLED);
        r.node->set_layer_mask(1u | NODE_SURFACE_LAYER);
        // The region mesher builds a cell for node k across [k, k+1] on every
        // axis, while the near mesh centres node k on k, spanning [k-0.5,
        // k+0.5]; Luanti Z is mirrored into Godot, which flips that axis's
        // sign. Uncorrected, the whole far field sat half a node high and
        // half a node sideways, which flat water made visible: the far sea
        // rode above the near sea as a lip at the hand-off, and sat level
        // with far ice tops it should lie half a node under, where the two
        // fought for the plane. Terrain hid the same offset under its skirts.
        r.node->set_position(Vector3(-0.5f, -0.5f, 0.5f));
        add_child(r.node);
    }
    r.node->set_mesh(mesh);
    surfaceStage(r.node);
    r.published = true;
    r.published_members = r.members;
    r.published_partial = lm.partial;
    r.published_exact_cell = exact_cell_used;
    r.published_coarse_cell = coarse_cell_used;
    finish_handoffs();
    {
        const double lod_ms_now = ms_since(t0);
        ema(m_ms_lod, lod_ms_now);
        m_ms_lod_worst = std::max(m_ms_lod_worst, lod_ms_now);
    }
}

// Rebuild dirty regions inside a time budget, nearest and most looked at
// first (goanna_schedule.h). A region that already has a mesh waits a moment
// after it is first dirtied, so one rebuild covers the many blocks that
// stream into it in that time.
//
// This used to run oldest-dirtied first, which threw away the priority
// lodBuildRegion then computed: with thousands of regions and a two
// millisecond slice, the handful that reached the pool each poll were
// whichever had been waiting longest, not whichever the player could see.
void GoannaClient::lodRebuild(double budget_ms) {
    m_lod_last_built = 0;
    m_lod_chains_built_last = 0;
    lodStartStorage();
    lodCollectChains();
    auto t0 = clock_t_::now();
    // Admission only: disk reads and chain derivation run on the bounded
    // storage worker. Pending is not missing; keep each region's waiters
    // until its validated result actually arrives.
    int admitted = 0;
    while (!m_lod_chain_queue.empty() && admitted < 16 && ms_since(t0) < budget_ms * 0.5) {
        const v3s16 bp = m_lod_chain_queue.front();
        m_lod_chain_queue.pop_front();
        if (!m_lod_chain_queued.erase(bp)) continue;
        const bool wanted = m_lod_member.count(bp) || m_lod_chain_waiters.count(bp);
        if (!wanted) continue;
        if (!lodRequestChain(bp)) {
            lodEnqueueChain(bp);
            break;
        }
        if (m_lod_chain_missing.count(bp)) m_lod_chain_waiters.erase(bp);
        ++admitted;
    }
    if (m_lod_chain_queue.size() < 2048) {
        int retried = 0;
        while (!m_lod_chain_retry_regions.empty() && retried++ < 4) {
            auto it = m_lod_chain_retry_regions.begin();
            const LodRegionKey key = *it;
            m_lod_chain_retry_regions.erase(it);
            if (m_lod_regions.count(key)) lodMarkDirty(key);
        }
    }
    if (m_lod_regions.empty())
        return;
    std::vector<std::pair<int, LodRegionKey>> dirty;
    for (auto &kv : m_lod_regions)
        if (kv.second.dirty)
            dirty.push_back({lodRegionPriority(kv.first, kv.second), kv.first});
    std::sort(dirty.begin(), dirty.end(),
            [](const auto &a, const auto &b) { return a.first < b.first; });
    for (int &n : m_sched_pending)
        n = 0;
    for (const auto &dk : dirty)
        ++m_sched_pending[(int)goanna::ViewPriority::classOf(dk.first)];
    // How many regions are drawing something that has moved on, and how long
    // the region that has waited longest has been waiting. Ordering by
    // priority alone has no fairness: the sort it replaced was oldest first,
    // which was wrong about what to do next but right that everything drains.
    // These two are what say whether that guarantee has been lost.
    m_sched_stale = 0;
    m_sched_oldest_ms = 0.0;
    for (const auto &kv : m_lod_regions) {
        if (!kv.second.dirty)
            continue;
        if (kv.second.stale)
            ++m_sched_stale;
        m_sched_oldest_ms = std::max(m_sched_oldest_ms, ms_since(kv.second.dirty_at));
    }
    for (const auto &dk : dirty) {
        if (m_lod_last_built > 0 && ms_since(t0) > budget_ms)
            break;
        auto it = m_lod_regions.find(dk.second);
        if (it == m_lod_regions.end())
            continue;
        LodRegion &r = it->second;
        if (r.node && !r.members.empty() && ms_since(r.dirty_at) < 250.0)
            continue;
        lodBuildRegion(dk.second, r);
        ++m_lod_last_built;
        if (r.members.empty()) {
            MeshJobKey jk;
            jk.kind = MeshJobKey::kLodRegion;
            jk.pos = dk.second.pos;
            jk.tier = (int16_t)dk.second.tier;
            m_mesh_pool.cancel(jk);
            m_lod_regions.erase(it);
        }
    }
}

// Drop every region and chain and requeue every block: the tier layout
// changed under them.
void GoannaClient::lodReset() {
    surfaceClear();
    m_lod_storage.clear();
    m_lod_loads.clear();
    fineClear();
    m_lod_cached_summaries.clear();
    m_lod_primed_regions.clear();
    // Every queued capture describes the layout that just changed. Jobs
    // already running finish and are dropped by the generation test on the
    // way out; they hold their chains by shared_ptr, so clearing the map
    // below cannot pull the ground out from under them.
    m_mesh_pool.cancelKind(MeshJobKey::kLodRegion);
    for (auto &kv : m_lod_regions)
        if (kv.second.node)
            kv.second.node->queue_free();
    m_lod_regions.clear();
    m_lod_member.clear();
    m_lod_chains.clear();
    {
        // Workers resolve tiles through this cache; take their lock.
        std::lock_guard<std::mutex> tile_lock(m_lod_tiles.mutex);
        m_lod_tiles.entries.clear();
    }
    for (const v3s16 &bp : m_far_blocks)
        m_block_tier.erase(bp);
    m_far_blocks.clear();
    m_far_dirty = true;
    m_lod_retier_pending = true;
    m_lod_retier_centre = v3s16(32767, 32767, 32767);
    m_lod_retier_cursor = v3s16(-32768, -32768, -32768);
    m_lod_chain_queue.clear();
    m_lod_chain_queued.clear();
    m_lod_chain_waiters.clear();
    m_lod_chain_retry_regions.clear();
    m_lod_handoff_near.clear();
    m_lod_handoff_to_near.clear();
    // These as well: the regions they name were just freed, and a new
    // region under the same key inherits a leaked freeze count at the
    // lodBuildRegion gate, dirty but never rebuilt for the whole session.
    // The other two teardown sites already clear the full set together.
    m_lod_handoff_far.clear();
    m_lod_handoff_old_counts.clear();
    m_lod_frozen_at.clear();
    m_lod_chain_missing.clear();
    m_far_remote.clear();
    m_far_requested.clear();
    m_far_pending.clear();
    m_far_inflight = 0;
    if (m_session) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_block_tier)
            m_session->requeueBlock(kv.first);
    }
}

int GoannaClient::update_lod(const Vector3 &around, int max_rebuild) {
    const auto t_update = clock_t_::now();
    if (Viewport *viewport = get_viewport()) {
        const Vector2 size = viewport->get_visible_rect().size;
        // m_view_fov is the diagonal camera angle used for the server cone.
        // Its matching pixel diagonal gives the same focal length as either
        // projection axis. It must not be treated as a vertical FOV.
        const float focal = 0.5f * size.length() /
                std::tan(m_view_fov * 3.14159265358979323846f / 360.0f);
        if (std::isfinite(focal) && focal > 0.0f &&
                std::fabs(focal - m_lod_focal_pixels) > 1.0f) {
            m_lod_focal_pixels = focal;
            m_lod_retier_pending = true;
            m_lod_retier_cursor = v3s16(-32768, -32768, -32768);
        }
    }
    // Moving is as much a reason to shut the view cone as turning is: what is
    // in front of the player is changing either way. Half a mapblock, which a
    // walking player crosses in about two seconds and a standing one never.
    const v3f here(around.x, around.y, around.z);
    if (here.getDistanceFromSQ(m_view_anchor) > 64.0f) {
        m_view_anchor = here;
        noteViewMoved();
    }
    m_lod_centre = around; // poll_blocks tiers new blocks against this too
    // Put finished regions on screen before queueing more, so a worker that
    // has already done the work is not left holding it for another frame.
    lodCollectMeshes();
    surfaceUpdate();
    if (!m_session || m_lod_distance <= 0)
        return 0;
    const v3s16 centre((s16)std::floor(around.x / MAP_BLOCKSIZE),
            (s16)std::floor(around.y / MAP_BLOCKSIZE),
            (s16)std::floor(-around.z / MAP_BLOCKSIZE));
    if (centre != m_lod_retier_centre) {
        m_lod_retier_centre = centre;
        m_lod_retier_pending = true;
        m_lod_retier_cursor = v3s16(-32768, -32768, -32768);
    }
    std::vector<v3s16> changed;
    const auto t_tier = clock_t_::now();
    if (m_lod_retier_pending) {
        // A bounded cursor over the live map, like every prune sweep here.
        // The first cure for this scan copied all of m_block_tier into a
        // deque per camera block crossing, which at half a million retained
        // blocks was itself a 10 ms and worse hitch every 16 nodes of
        // travel: the movement-correlated cratering of 2026-08-31. The
        // cursor tolerates entries appearing and vanishing mid-pass; a
        // block missed by a shifted cursor is caught on the next crossing,
        // and new entries are tiered against m_lod_centre when inserted.
        const int scan_budget = std::max(256, max_rebuild * 128);
        int scanned = 0;
        auto it = m_block_tier.lower_bound(m_lod_retier_cursor);
        while (it != m_block_tier.end() && scanned < scan_budget &&
                (int)changed.size() < max_rebuild) {
            ++scanned;
            const v3s16 bp = it->first;
            const int current = it->second;
            ++it;
            // A retained entry that is not a far block is live, or was until
            // the prune that takes it out of both.
            if (lodTierFor(bp, around, !m_far_blocks.count(bp)) != current)
                changed.push_back(bp);
        }
        if (it == m_block_tier.end()) {
            m_lod_retier_pending = false;
            m_lod_retier_cursor = v3s16(-32768, -32768, -32768);
        } else {
            m_lod_retier_cursor = it->first;
        }
    }
    ema(m_ms_lod_tier_scan, ms_since(t_tier));
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    const auto t_summaries = clock_t_::now();
    lodTakeSummaries(around);
    fineUpdate();
    ema(m_ms_lod_summaries, ms_since(t_summaries));
    // Keep the summary requests in flight. lodUpdateFar only runs every two
    // seconds when the player stands still, and one request per run was the
    // whole rate of the far field once the server answered from its store:
    // a 1024 node grant is some six hundred areas, which is twenty minutes
    // at a request every two seconds. The scan is a few milliseconds, so it
    // runs a few times a second while there is room in flight.
    const auto t_requests = clock_t_::now();
    if (m_far_inflight < 12 && m_far_radius > 0 && ms_since(m_far_scan) > 250.0)
        lodRequestSummaries(m_far_centre, m_far_radius);
    ema(m_ms_lod_requests, ms_since(t_requests));
    for (const v3s16 &bp : changed) {
        if (m_far_blocks.count(bp)) {
            // No live block to requeue: apply the new tier here.
            const int tier = lodTierFor(bp, around, false);
            if (tier < 1) {
                // LOD was disabled. Retain every source's chain; changing
                // presentation must not delete knowledge.
                lodAssign(bp, 0);
                m_block_tier.erase(bp);
                m_far_blocks.erase(bp);
            } else {
                lodAssign(bp, tier);
                m_block_tier[bp] = tier;
            }
        } else {
            m_session->requeueBlock(bp);
        }
    }
    const auto t_far = clock_t_::now();
    lodUpdateFar(around);
    ema(m_ms_lod_far_scan, ms_since(t_far));
    ema(m_ms_lod_update, ms_since(t_update));
    return (int)changed.size();
}

} // namespace goanna
