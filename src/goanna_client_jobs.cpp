// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The mesh jobs GoannaClient hands to its MeshPool, and taking them back.
// The three job types are defined here: NearBlockJob (one near block through
// Luanti's mesher and the occlusion trace), NearBatchJob (a near region's
// blocks merged by material) and LodRegionJob (one far region meshed from its
// chains). Beside them is what captures each job's input and submits it
// (nearSubmit and nearShareKey, nearRebuild, lodBuildRegion with
// lodCaptureRegion and lodRegionPriority), lodCollectMeshes, which takes
// every finished job off the pool and hands it to the near or far side, and
// set_mesh_threads, which restarts the pool.
//
// Threads: each job type's run() executes on a MeshPool worker and keeps to
// the rule in goanna_mesh_pool.h, working only on what was captured when the
// job was made. Everything else here runs on Godot's main thread; nearSubmit
// is called from poll_blocks with the session's map lock held.

#include "goanna_client_internal.h"

using namespace godot;

namespace {
// Two resolutions can contribute to one regional ArrayMesh. Append matching
// texture surfaces instead of leaving a cell-1 shell and cell-4 fallback as
// separate scene objects (and therefore separate draw calls).
void appendLodMesh(goanna::LodRegionMesh &dst, goanna::LodRegionMesh &&src) {
    dst.ground.insert(dst.ground.end(),src.ground.begin(),src.ground.end());
    dst.faces += src.faces;
    dst.quads += src.quads;
    dst.surface_cells += src.surface_cells;
    dst.skirts += src.skirts;
    dst.partial += src.partial;
    dst.max_span = std::max(dst.max_span, src.max_span);
    for (goanna::LodSurface &from : src.surfaces) {
        auto it = std::find_if(dst.surfaces.begin(), dst.surfaces.end(), [&](const goanna::LodSurface &to) {
            return to.texture_id == from.texture_id && to.liquid == from.liquid;
        });
        if (it == dst.surfaces.end()) {
            dst.surfaces.push_back(std::move(from));
            continue;
        }
        const u32 base = (u32)it->pos.size();
        it->pos.insert(it->pos.end(), from.pos.begin(), from.pos.end());
        it->nrm.insert(it->nrm.end(), from.nrm.begin(), from.nrm.end());
        it->uv.insert(it->uv.end(), from.uv.begin(), from.uv.end());
        it->uv2.insert(it->uv2.end(), from.uv2.begin(), from.uv2.end());
        it->col.insert(it->col.end(), from.col.begin(), from.col.end());
        it->custom0.insert(it->custom0.end(), from.custom0.begin(), from.custom0.end());
        it->idx.reserve(it->idx.size() + from.idx.size());
        for (u32 i : from.idx)
            it->idx.push_back(base + i);
    }
}
} // namespace

namespace goanna {

// The near batch job: concatenate one region's member surfaces into merged
// material groups, and in mesh-cut occluder mode filter the occluder
// triangles, all away from the main thread. The per-second trace of
// 2026-08-31 put 91 per cent of the flying hitch tail on exactly this work
// (10 to 29 ms single builds during arrival floods). Everything the job
// reads is copied at submit; the Packed arrays are copy-on-write, so the
// copies are reference bumps and stay immutable because a remesh replaces
// a block's arrays rather than mutating them.
struct NearBatchJob : goanna::MeshJob {
    struct Surface {
        goanna::MaterialKey key;
        PackedVector3Array verts, norms;
        PackedVector2Array uvs, uv2s;
        PackedColorArray cols;
        PackedByteArray custom0, custom2;
        PackedInt32Array idx;
        bool glow = false;
        // Occluder metadata resolved on the main thread at submit, so the
        // worker never touches the texture source: whether this material
        // may occlude at all, and for array textures which layers have
        // alpha (null means nothing to filter).
        bool can_occlude = false;
        std::shared_ptr<const std::vector<bool>> alpha_layers;
    };
    std::vector<Surface> surfaces;
    std::vector<v3s16> members;
    std::string share_key;
    bool build_occluder = false; // mesh-cut mode; boxes are built at publish
    // Outputs.
    std::vector<goanna::GoannaClient::NearBatchGroup> groups_out;
    PackedVector3Array occ_verts;
    PackedInt32Array occ_idx;

    void run() override {
        using Group = goanna::GoannaClient::NearBatchGroup;
        std::map<uint64_t, Group> groups;
        // Count first, then fill, exactly as the main-thread version did:
        // single element appends across the GDExtension boundary were the
        // original largest cost in the frame.
        for (const Surface &surface : surfaces) {
            const uint64_t group_key = (surface.key.hash() << 1) | (surface.glow ? 1 : 0);
            Group &acc = groups[group_key];
            acc.key = surface.key;
            acc.glow = surface.glow;
            acc.n_verts += surface.verts.size();
            acc.n_idx += (int)surface.idx.size();
        }
        for (auto &kv : groups) {
            Group &a = kv.second;
            a.verts.resize(a.n_verts);
            a.norms.resize(a.n_verts);
            a.uvs.resize(a.n_verts);
            a.uv2s.resize(a.n_verts);
            a.cols.resize(a.n_verts);
            a.custom0.resize(a.n_verts * 4);
            a.custom2.resize(a.n_verts * 4);
            a.idx.resize(a.n_idx);
        }
        std::map<uint64_t, bool> occludable;
        for (const Surface &surface : surfaces) {
            const uint64_t group_key = (surface.key.hash() << 1) | (surface.glow ? 1 : 0);
            Group &acc = groups[group_key];
            occludable[group_key] = surface.can_occlude;
            const int n = surface.verts.size();
            const int base = acc.v_at;
            if (n > 0) {
                memcpy(acc.verts.ptrw() + base, surface.verts.ptr(), (size_t)n * sizeof(Vector3));
                memcpy(acc.norms.ptrw() + base, surface.norms.ptr(), (size_t)n * sizeof(Vector3));
                memcpy(acc.uvs.ptrw() + base, surface.uvs.ptr(), (size_t)n * sizeof(Vector2));
                memcpy(acc.uv2s.ptrw() + base, surface.uv2s.ptr(), (size_t)n * sizeof(Vector2));
                memcpy(acc.cols.ptrw() + base, surface.cols.ptr(), (size_t)n * sizeof(Color));
                memcpy(acc.custom0.ptrw() + (size_t)base * 4, surface.custom0.ptr(),
                        (size_t)n * 4);
                memcpy(acc.custom2.ptrw() + (size_t)base * 4, surface.custom2.ptr(),
                        (size_t)n * 4);
            }
            const int ni = (int)surface.idx.size();
            if (ni > 0) {
                int32_t *w = acc.idx.ptrw() + acc.i_at;
                const int32_t *r = surface.idx.ptr();
                for (int i = 0; i < ni; ++i)
                    w[i] = r[i] + base;
            }
            acc.v_at += n;
            acc.i_at += ni;
        }
        if (build_occluder) {
            // The per-triangle alpha filter, driven by the metadata the
            // submit captured rather than by texture source queries.
            std::map<uint64_t, std::shared_ptr<const std::vector<bool>>> alpha;
            for (const Surface &surface : surfaces) {
                const uint64_t group_key =
                        (surface.key.hash() << 1) | (surface.glow ? 1 : 0);
                if (surface.alpha_layers)
                    alpha[group_key] = surface.alpha_layers;
            }
            for (auto &kv : groups) {
                Group &acc = kv.second;
                if (!occludable[kv.first] || acc.verts.is_empty() || acc.idx.is_empty())
                    continue;
                const std::vector<bool> *has_alpha = nullptr;
                auto ai = alpha.find(kv.first);
                if (ai != alpha.end())
                    has_alpha = ai->second.get();
                PackedInt32Array visible_idx;
                for (int i = 0; i + 2 < acc.idx.size(); i += 3) {
                    const int vi = acc.idx[i];
                    if (vi < 0 || vi >= acc.uv2s.size())
                        continue;
                    const size_t layer = (size_t)std::max(0, (int)std::lround(acc.uv2s[vi].x));
                    if (has_alpha && layer < has_alpha->size() && (*has_alpha)[layer])
                        continue;
                    visible_idx.push_back(acc.idx[i]);
                    visible_idx.push_back(acc.idx[i + 1]);
                    visible_idx.push_back(acc.idx[i + 2]);
                }
                if (visible_idx.is_empty())
                    continue;
                const int base = occ_verts.size();
                occ_verts.append_array(acc.verts);
                for (int i = 0; i < visible_idx.size(); ++i)
                    occ_idx.push_back(visible_idx[i] + base);
            }
        }
        groups_out.reserve(groups.size());
        for (auto &kv : groups) {
            Group &group = kv.second;
            group.tangents = node_tangents(group.verts, group.norms, group.uvs, group.idx);
            groups_out.push_back(std::move(kv.second));
        }
    }
};

void GoannaClient::nearRebuild(double budget_ms) {
    m_near_regions_built_last = 0;
    auto t0 = clock_t_::now();
    std::vector<std::pair<clock_t_::time_point, v3s16>> dirty;
    for (const auto &kv : m_near_regions)
        if (kv.second.dirty && !kv.second.building)
            dirty.push_back({kv.second.dirty_at, kv.first});
    std::sort(dirty.begin(), dirty.end(),
            [](const auto &a, const auto &b) { return a.first < b.first; });
    // Alpha layer bitsets per array texture, captured once per call so the
    // worker never touches the texture source.
    std::map<u32, std::shared_ptr<const std::vector<bool>>> alpha_cache;
    auto alpha_for = [&](u32 texture_id) -> std::shared_ptr<const std::vector<bool>> {
        auto it = alpha_cache.find(texture_id);
        if (it != alpha_cache.end())
            return it->second;
        std::shared_ptr<const std::vector<bool>> out;
        GoannaTexture *texture = m_session ? m_session->tsrc()->goannaTexture(texture_id) : nullptr;
        if (texture && texture->isArray()) {
            auto bits = std::make_shared<std::vector<bool>>();
            const size_t layers = texture->layerNames().size();
            bits->resize(layers);
            for (size_t l = 0; l < layers; ++l)
                (*bits)[l] = texture->layerHasAlpha((u16)l);
            out = std::move(bits);
        }
        alpha_cache[texture_id] = out;
        return out;
    };
    for (const auto &entry : dirty) {
        if (m_near_regions_built_last > 0 && ms_since(t0) >= budget_ms)
            break;
        auto it = m_near_regions.find(entry.second);
        if (it == m_near_regions.end())
            continue;
        NearRegion &region = it->second;
        // Wait for a gap in the arrivals (or the staleness cap), not merely
        // for age: rebuilding on age alone rebuilt a still-streaming region
        // five and more times over. 150 ms of quiet is one to two rebuilds
        // per region per flood; the 700 ms cap keeps a region under constant
        // trickle from starving on screen.
        if ((region.node || region.glow_node) && !region.members.empty() &&
                ms_since(region.last_dirty_at) < 150.0 &&
                ms_since(region.dirty_at) < 700.0)
            continue;
        if (region.members.empty()) {
            // Nothing left to build: free the nodes inline and let go.
            std::vector<NearBatchGroup> none;
            PackedVector3Array ov;
            PackedInt32Array oi;
            nearPublishBatch(entry.second, region, none, ov, oi, {});
            region.dirty = false;
            m_near_regions.erase(it);
            ++m_near_regions_built_last;
            continue;
        }
        auto job = std::make_unique<NearBatchJob>();
        job->members.assign(region.members.begin(), region.members.end());
        job->build_occluder = !m_occluder_boxes;
        bool shareable = true;
        std::string input_keys;
        for (const v3s16 &bp : job->members) {
            auto block = m_near_blocks.find(bp);
            if (block == m_near_blocks.end())
                continue;
            if (block->second.share_key.empty()) shareable = false;
            else input_keys += block->second.share_key;
            for (const NearSurface &surface : block->second.surfaces) {
                NearBatchJob::Surface js;
                js.key = surface.key;
                js.verts = surface.verts;
                js.norms = surface.norms;
                js.uvs = surface.uvs;
                js.uv2s = surface.uv2s;
                js.cols = surface.cols;
                js.custom0 = surface.custom0;
                js.custom2 = surface.custom2;
                js.idx = surface.idx;
                js.glow = surface.glow;
                if (job->build_occluder) {
                    js.can_occlude = nearCanOcclude(surface.key);
                    if (js.can_occlude)
                        js.alpha_layers = alpha_for(surface.key.texture_id);
                }
                job->surfaces.push_back(std::move(js));
            }
        }
        if (shareable && !input_keys.empty()) job->share_key = hashing::sha256(input_keys);
        goanna::MeshJobKey jk;
        jk.kind = goanna::MeshJobKey::kNearBatch;
        jk.pos = entry.second;
        const uint64_t generation = region.generation + 1;
        const bool drawn = region.node != nullptr || region.glow_node != nullptr;
        const int priority = viewPriority().of(
                drawn ? goanna::ViewPriority::kMaintain : goanna::ViewPriority::kCoverage,
                goanna::godotCentreOfBlocks(
                        v3s16(entry.second.X * kNearRegionBlocks,
                                entry.second.Y * kNearRegionBlocks,
                                entry.second.Z * kNearRegionBlocks),
                        kNearRegionBlocks, MAP_BLOCKSIZE));
        if (!m_mesh_pool.submit(jk, generation, goanna::MeshWorkStage::kNear, priority,
                    std::move(job)))
            break; // admission bounded; the region stays dirty and retries
        region.generation = generation;
        region.building = true;
        region.dirty = false;
        ++m_near_regions_built_last;
    }
}

void GoannaClient::set_mesh_threads(int threads) {
    threads = std::clamp(threads, -1, 16);
    if (threads == m_mesh_threads)
        return;
    m_mesh_threads = threads;
    surfaceClear();
    if (!m_session)
        return; // applied on the next connect
    std::vector<v3s16> retry_near;
    retry_near.reserve(m_near_inflight.size());
    for (const auto &kv : m_near_inflight)
        retry_near.push_back(kv.first);
    m_mesh_pool.stop();
    // Whatever was queued died with the pool. Forget that those blocks were
    // in flight, or poll_blocks skips them for ever waiting on a result that
    // is never coming.
    m_near_inflight.clear();
    // Stopping the pool also discards regional batch jobs. A region left
    // marked building would wait forever for its cancelled result, leaving
    // holes when split-screen changes the worker allocation during loading.
    for (auto &entry : m_near_regions) {
        if (!entry.second.building) continue;
        entry.second.building = false;
        nearMarkDirty(entry.second);
    }
    if (m_mesh_threads >= 0)
        m_mesh_pool.start(m_mesh_threads);
    // takeNewBlocks already handed these positions to the old pool. Put them
    // back without changing their map revision; otherwise changing the
    // worker setting can permanently strand blocks at the far representation.
    {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (const v3s16 &bp : retry_near)
            m_session->requeueBlock(bp);
    }
    // Anything captured for the old pool went with it, and the regions that
    // were mid-build still believe they are building. Collect the keys first:
    // lodMarkDirty touches the same map.
    std::vector<LodRegionKey> keys;
    keys.reserve(m_lod_regions.size());
    for (auto &kv : m_lod_regions) {
        kv.second.building = false;
        keys.push_back(kv.first);
    }
    for (const LodRegionKey &k : keys)
        lodMarkDirty(k);
}

// One near block's meshing, run on a mesh worker.
//
// The map reads are already done: gatherMeshData copied the block and its
// 3x3x3 neighbourhood into `data`, and the light field copied the same
// neighbourhood's light and occupancy, both on the main thread under the map
// lock. What is left is the two expensive parts, Luanti's mesher and the
// occlusion trace, neither of which touches the map or Godot. The mesher
// does read the shader source, and the texture source for a stored carve's
// crack; both lock themselves (goanna_textures.h).
namespace {
struct NearBlockJob : goanna::MeshJob {
    goanna::GoannaSession *session = nullptr;
    v3s16 bp;
    std::unique_ptr<MeshMakeData> data;
    bool no_vertex_light = false;
    // Outputs, read by poll_blocks once this has come back.
    std::unique_ptr<MapBlockMesh> mesh;
    BlockLightField light;
    std::map<uint32_t, std::vector<VertexLight>> vertex_light;

    void run() override {
        if (!session || !data)
            return;
        mesh = goanna::meshGathered(*session, *data);
        if (!mesh || no_vertex_light)
            return;
        // Sample every vertex of every buffer now, keyed the way the
        // publishing loop walks them, so that loop indexes a table instead
        // of tracing eight rays per vertex with the frame waiting on it.
        for (int layer = 0; layer < MAX_TILE_LAYERS; ++layer) {
            scene::IMesh *sm = mesh->getMesh(layer);
            if (!sm)
                continue;
            for (u32 b = 0; b < sm->getMeshBufferCount(); ++b) {
                scene::IMeshBuffer *buf = sm->getMeshBuffer(b);
                if (!buf || buf->getVertexCount() == 0 || buf->getIndexCount() == 0)
                    continue;
                if (buf->getVertexType() != video::EVT_STANDARD)
                    continue;
                const video::S3DVertex *v = (const video::S3DVertex *)buf->getVertices();
                const u32 nv = buf->getVertexCount();
                std::vector<VertexLight> &tab = vertex_light[((uint32_t)layer << 16) | b];
                tab.resize(nv);
                for (u32 i = 0; i < nv; ++i)
                    tab[i] = light.sample(
                            v3f(v[i].Pos.X / BS + bp.X * MAP_BLOCKSIZE,
                                    v[i].Pos.Y / BS + bp.Y * MAP_BLOCKSIZE,
                                    v[i].Pos.Z / BS + bp.Z * MAP_BLOCKSIZE),
                            v3f(v[i].Normal.X, v[i].Normal.Y, v[i].Normal.Z));
            }
        }
    }
};
} // namespace

// One far region's meshing, run on a mesh worker.
//
// Everything it reads was captured on the main thread: the snapshot holds the
// chains, membership and drawn cell sizes, and the three pointers below are
// owned by the session and outlive the job because the pool is stopped before
// the session goes. The tile cache is shared with the other workers and takes
// its own lock (goanna_lod.h, LodTileCache), and the texture source it asks
// takes another (goanna_textures.h).
namespace {
struct LodRegionJob : goanna::MeshJob {
    LodRegionSnapshot snap;
    LodRegionSpec exact;
    LodRegionSpec coarse;
    bool has_coarse = false;
    const NodeDefManager *ndef = nullptr;
    GoannaTextureSource *tsrc = nullptr;
    const MaterialTable *materials = nullptr;
    LodTileCache *tiles = nullptr;
    LodRegionMesh result;
    uint64_t state_revision = 0;

    void run() override {
        if (!ndef || !tiles)
            return;
        snap.bind(exact);
        result = meshLodRegion(exact, ndef, tsrc, materials, *tiles);
        if (has_coarse) {
            snap.bind(coarse);
            appendLodMesh(result, meshLodRegion(coarse, ndef, tsrc, materials, *tiles));
        }
    }
};
} // namespace

// What a region is worth building next: what is wrong with it, how far away
// it is, whether the player is looking at it, and how long it has waited.
int GoannaClient::lodRegionPriority(const LodRegionKey &key, const LodRegion &r) const {
    // A region gains a band for every four seconds it has waited. Ordering by
    // priority alone has no fairness, and the oldest-first sort this replaced
    // did: measured on the showcase fixture, sixty regions that had lost
    // blocks to the near field sat unbuilt for 43 seconds while the coverage
    // band ahead of them drained from 3210 to 79.
    constexpr double kAgeMs = 4000.0;
    goanna::ViewPriority vp = viewPriority();
    // Coverage only, and measure() applies it to nothing else: the far
    // frontier fills horizontally, but a stale slab overhead is urgent.
    vp.vertical = 2.0f;
    bool missing = !r.published || r.published_partial;
    if (!missing) {
        // Membership changes on invalidation/publication, not on every
        // scheduling poll. A wide loaded world otherwise repeats hundreds
        // of thousands of set lookups each frame while waiting on workers.
        if (!r.priority_members_valid) {
            r.priority_members_missing = false;
            for (const v3s16 &bp : r.members)
                if (!r.published_members.count(bp)) {
                    r.priority_members_missing = true;
                    break;
                }
            r.priority_members_valid = true;
        }
        missing = r.priority_members_missing;
    }
    const int wanted_exact = std::min(lodCellFor(key.tier), 1 << std::max(0, key.tier - 1));
    const int wanted_coarse = lodCellFor(key.tier);
    const bool refining = r.published && !missing &&
            (r.published_exact_cell != wanted_exact || r.published_coarse_cell != wanted_coarse);
    goanna::ViewPriority::Class cls = r.stale ? goanna::ViewPriority::kStale
            : missing                         ? goanna::ViewPriority::kCoverage
            : refining                        ? goanna::ViewPriority::kRefine
                                              : goanna::ViewPriority::kMaintain;
    cls = goanna::ViewPriority::aged(cls, ms_since(r.dirty_at), kAgeMs);
    const int rb = lodRegionBlocks(key.tier);
    return vp.of(cls, goanna::godotCentreOfBlocks(key.pos * rb, rb, MAP_BLOCKSIZE));
}

void GoannaClient::lodBuildRegion(const LodRegionKey &key, LodRegion &r) {
    r.dirty = false;
    if (r.members.empty() || !m_session) {
        if (r.node) {
            surfaceRetire(r.node);
            if (r.node) r.node->queue_free();
            r.node = nullptr;
        }
        r.faces = r.quads = r.surfaces = 0;
        r.published = false;
        r.published_members.clear();
        r.published_chains.clear();
        r.published_ground.clear();
        ++m_surface_source_revision;
        r.published_partial = false;
        r.published_exact_cell = 0;
        r.published_coarse_cell = 0;
        return;
    }
    // A region serving as the visible half of a cross-tier handoff must stay
    // byte-for-byte as last published. Rebuilding it against the new logical
    // ownership would remove the transitioning cells before the target mesh
    // exists. Once the target publishes, lodPublishRegion removes those
    // retained members, marks this region dirty, and normal rebuilding
    // resumes. But only for so long: a frozen region cannot publish, and
    // publishing is what releases freezes, so a mass retier formed cycles of
    // regions waiting on each other forever (the growing stale-drawn count
    // with oldest ages in the minutes). Past the timeout the region rebuilds
    // from current ownership, trading a one-frame flash for the cycle.
    constexpr double kLodFreezeMs = 8000.0;
    if (m_lod_handoff_old_counts.count(key)) {
        auto at = m_lod_frozen_at.find(key);
        if (at == m_lod_frozen_at.end()) {
            at = m_lod_frozen_at.emplace(key, clock_t_::now()).first;
        }
        if (ms_since(at->second) < kLodFreezeMs) {
            r.dirty = true;
            return;
        }
    }
    auto t0 = clock_t_::now();
    static const bool no_vertex_light = getenv("GOANNA_NO_VERTEX_LIGHT") != nullptr;
    const int rb = lodRegionBlocks(key.tier);
    auto region_member = [&](v3s16 bp) {
        auto it = m_lod_member.find(bp);
        return it != m_lod_member.end() && it->second == key;
    };
    auto chain = [&](v3s16 bp) -> const BlockLodChain * {
        auto it = m_lod_chains.find(bp);
        if (it != m_lod_chains.end())
            return it->second.get();
        // Near-owned neighbours also need an immutable chain for the seam.
        // This does not give them far membership or duplicate their mesh.
        // Not built yet: ask for it, and come back to this region when it is.
        const bool admitted = lodEnqueueChain(bp);
        if (m_lod_chain_queued.count(bp) || m_lod_loads.count(bp))
            m_lod_chain_waiters[bp].insert(key);
        if (!admitted) m_lod_chain_retry_regions.insert(key);
        return nullptr;
    };
    // Full and stored blocks retain an exact cell-1 occupancy level. Remote
    // summaries begin at cell 4. This is the actual resolution another pass
    // draws, which the mixed-resolution face test must use rather than the
    // block's distance tier.
    auto drawn_cell = [&](v3s16 bp) -> int {
        auto it = m_block_tier.find(bp);
        if (it == m_block_tier.end())
            return -1;
        if (it->second <= 0)
            return 0;
        auto ch = m_lod_chains.find(bp);
        if (ch == m_lod_chains.end() || !ch->second->hasCell(1))
            return lodCellFor(it->second);
        // Exact data follows a block-aligned 1,2,4 progression with distance.
        // The summary fallback begins at cell 4 and cannot join the first two
        // rungs except through the mixed-resolution boundary.
        return std::min(lodCellFor(it->second), 1 << std::max(0, it->second - 1));
    };
    auto make_spec = [&](int cell) {
        LodRegionSpec spec;
        spec.origin = key.pos * rb;
        spec.blocks = rb;
        spec.cell = cell;
        // The exact cell-1/2 geometry still traces at least an eight-node
        // neighbourhood. Only regions containing exact data pay for it.
        spec.ao_radius = no_vertex_light ? 0.0f : std::clamp(6.0f * cell, 8.0f, 64.0f);
        spec.member = [&, cell](v3s16 bp) { return region_member(bp) && drawn_cell(bp) == cell; };
        spec.chain = chain;
        spec.drawn_cell = drawn_cell;
        return spec;
    };

    // Exact boundaries and summary fallback are meshed separately because a
    // LodRegionSpec has one cell size. They are immediately folded into the
    // same texture surfaces and uploaded as one regional ArrayMesh.
    const int exact_cell = std::min(lodCellFor(key.tier), 1 << std::max(0, key.tier - 1));
    LodRegionSpec exact_spec = make_spec(exact_cell);
    LodRegionSpec coarse_spec = make_spec(lodCellFor(key.tier));

    if (m_mesh_pool.running()) {
        MeshJobKey jk;
        jk.kind = MeshJobKey::kLodRegion;
        jk.pos = key.pos;
        jk.tier = (int16_t)key.tier;
        const int priority = lodRegionPriority(key, r);
        const goanna::ViewPriority::Class priority_class =
                goanna::ViewPriority::classOf(priority);
        const MeshWorkStage stage = priority_class == goanna::ViewPriority::kBootstrap ||
                        priority_class == goanna::ViewPriority::kCoverage
                ? MeshWorkStage::kCoverage
                : priority_class == goanna::ViewPriority::kStale
                ? MeshWorkStage::kNear
                : priority_class == goanna::ViewPriority::kRefine
                ? MeshWorkStage::kStructure
                : MeshWorkStage::kDetail;
        if (!m_mesh_pool.canSubmit(jk, stage)) {
            r.dirty = true;
            r.building = false;
            {
        const double lod_ms_now = ms_since(t0);
        ema(m_ms_lod, lod_ms_now);
        m_ms_lod_worst = std::max(m_ms_lod_worst, lod_ms_now);
    }
            return;
        }
        auto job = std::make_unique<LodRegionJob>();
        // The specs' callbacks close over this frame's lambdas, which are
        // gone by the time a worker runs. Carry the scalars only; the
        // snapshot puts its own lookups back in their place inside run().
        job->exact = exact_spec;
        job->coarse = coarse_spec;
        job->exact.member = nullptr;
        job->exact.chain = nullptr;
        job->exact.drawn_cell = nullptr;
        job->coarse.member = nullptr;
        job->coarse.chain = nullptr;
        job->coarse.drawn_cell = nullptr;
        job->has_coarse = coarse_spec.cell != exact_spec.cell;
        job->ndef = m_session->nodeDefs();
        job->tsrc = m_session->tsrc();
        job->materials = &m_session->materialTable();
        job->tiles = &m_lod_tiles;
        job->state_revision = r.state_revision;
        lodCaptureRegion(key, exact_spec, coarse_spec, job->snap);
        // Nearer regions first, and what the player is looking at before what
        // is behind them (goanna_schedule.h).
        //
        // This used to build the region's position by hand and get the Z
        // mirror wrong, so it sorted against a point reflected through z = 0.
        // At the showcase spawn that is about 1150 nodes of error, more than
        // the whole far distance, and the effect was that the regions built
        // first were the ones behind the player: whole rectangular strips of
        // the visible world never arrived while the queue filled in the world
        // nobody could see. It also used the region's low corner rather than
        // its centre, which is another 64 nodes at tier 3.
        const uint64_t generation = r.generation + 1;
        if (!m_mesh_pool.submit(jk, generation, stage, priority, std::move(job))) {
            // Admission is deliberately bounded. Keep the last complete mesh
            // and leave this region dirty so it is retried after pressure
            // from already admitted work drains.
            r.dirty = true;
            r.building = false;
            {
        const double lod_ms_now = ms_since(t0);
        ema(m_ms_lod, lod_ms_now);
        m_ms_lod_worst = std::max(m_ms_lod_worst, lod_ms_now);
    }
            return;
        }
        r.generation = generation;
        r.building = true;
        // The region keeps drawing whatever it last published until the
        // result lands, which is what stops a hand-off showing a hole.
        {
        const double lod_ms_now = ms_since(t0);
        ema(m_ms_lod, lod_ms_now);
        m_ms_lod_worst = std::max(m_ms_lod_worst, lod_ms_now);
    }
        return;
    }

    LodRegionMesh lm = meshLodRegion(exact_spec, m_session->nodeDefs(), m_session->tsrc(),
            &m_session->materialTable(), m_lod_tiles);
    if (coarse_spec.cell != exact_spec.cell)
        appendLodMesh(lm, meshLodRegion(coarse_spec, m_session->nodeDefs(), m_session->tsrc(),
                                  &m_session->materialTable(), m_lod_tiles));
    lodPublishRegion(key, r, lm, t0, exact_spec.cell, coarse_spec.cell);
}

void GoannaClient::lodCaptureRegion(const LodRegionKey &key, const LodRegionSpec &exact,
        const LodRegionSpec &coarse, LodRegionSnapshot &out) {
    // One capture serves both passes, so it must cover the wider of the two
    // haloes. lodRegionMarginBlocks is the mesher's own rule.
    const int margin = std::max(lodRegionMarginBlocks(exact.cell, exact.ao_radius),
            lodRegionMarginBlocks(coarse.cell, coarse.ao_radius));
    out.reset(exact.origin, exact.blocks, margin);
    const v3s16 low = exact.origin - v3s16(margin, margin, margin);
    auto describe = [&](v3s16 bp, LodRegionSnapshot::Entry &en) {
        en.drawn_cell = exact.drawn_cell ? exact.drawn_cell(bp) : -1;
        auto mit = m_lod_member.find(bp);
        en.member = mit != m_lod_member.end() && mit->second == key;
    };
    // Most of a distant region's cube is air. Copy the retained immutable
    // chains by spatial rows, avoiding three map lookups for every absent
    // block. Empty entries retain the snapshot's explicit unknown default.
    visitLodBox(m_lod_chains, low, out.edge(),
            [&](v3s16 bp, const std::shared_ptr<const BlockLodChain> &chain) {
                LodRegionSnapshot::Entry *en = out.at(bp);
                en->chain = chain;
                describe(bp, *en);
            });
    // Known blocks whose chains are still loading must remain members and
    // register a waiter. Skip already copied chains. Blocks outside the
    // known layout are discovered by the bounded store/summary scans; their
    // arrival dirties neighbouring meshes, including their occlusion halo.
    visitLodBox(m_block_tier, low, out.edge(), [&](v3s16 bp, int) {
        LodRegionSnapshot::Entry *en = out.at(bp);
        if (en->chain)
            return;
        if (exact.chain)
            exact.chain(bp);
        describe(bp, *en);
    });
}

std::string GoannaClient::nearShareKey(v3s16 bp) {
    if (getenv("GOANNA_NO_SHARED_TERRAIN") || m_shared_near.use_count() < 2 ||
            !m_session->contentPrepared() ||
            g_goanna_carve_demo || !m_session->carves().empty()) return {};
    const auto &interaction = m_session->interactState();
    // A live carve can also change a neighbouring block's boundary faces.
    if (interaction.crack_level >= 0) return {};
    if (m_shared_identity.empty()) {
        const auto &table = m_session->materialTable();
        std::string identity = m_session->terrainPeer() + ":" +
                std::to_string(m_session->terrainDefinitions()) + ":" +
                m_session->terrainMediaIdentity() + m_session->tsrc()->geometryIdentity();
        identity.append((const char *)table.node_block.data(), table.node_block.size() * sizeof(uint16_t));
        m_shared_identity = hashing::sha256(identity);
    }
    std::string key = m_shared_identity + ":" + std::to_string(bp.X) + ":" +
            std::to_string(bp.Y) + ":" + std::to_string(bp.Z) + ":" +
            std::to_string(occlusionRays()) + ":" + std::to_string(occlusionSteps());
    const float shape[] = {bevel(), occlusionRadius()};
    key.append((const char *)shape, sizeof(shape));
    key.push_back(m_session->tsrc()->nodeAnimationEnabled() ? 1 : 0);
    // Missing neighbours have their own digest: a donor's extra knowledge
    // can never fill a receiving player's unknown boundary.
    for (int z = -1; z <= 1; ++z)
        for (int y = -1; y <= 1; ++y)
            for (int x = -1; x <= 1; ++x)
                key += m_session->blockContentDigest(bp + v3s16(x, y, z));
    return key;
}

// Gather one block's meshing input and queue it, main thread, map lock held.
bool GoannaClient::nearSubmit(v3s16 bp, MapBlock *block) {
    if (!m_session || !block)
        return false;
    uint64_t generation = m_session->blockRevision(bp);
    if (generation == 0)
        generation = 1;
    m_near_generation[bp] = generation;
    auto active = m_near_inflight.find(bp);
    if (active != m_near_inflight.end() && active->second >= generation)
        return true;
    MeshJobKey jk;
    jk.kind = MeshJobKey::kNearBlock;
    jk.pos = bp;
    jk.tier = 0;
    // A block with nothing drawn is missing coverage exactly as a far region
    // with no node is, and belongs in the same stage. It used to sit in
    // kNear, which the pool dispatches after every far region that has never
    // been meshed, so the geometry the player was standing in queued behind
    // thousands of distant regions and the bounded-admission cap on
    // non-coverage work refused it outright while they drained. A block that
    // already has a mesh is a refresh, and must not crowd coverage out.
    const bool drawn = m_near_blocks.count(bp) != 0;
    const MeshWorkStage stage = drawn ? MeshWorkStage::kNear : MeshWorkStage::kCoverage;
    if (!m_mesh_pool.canSubmit(jk, stage)) {
        m_session->requeueBlock(bp);
        return true;
    }
    auto job = std::make_unique<NearBlockJob>();
    MeshGrid grid{1};
    job->data = std::make_unique<MeshMakeData>(m_session->nodeDefs(), MAP_BLOCKSIZE, grid);
    bool has_crack = false;
    if (!goanna::gatherMeshData(*m_session, block, *job->data, has_crack))
        return false;
    // The block being dug re-meshes on every crack step and has its crack
    // level stamped from the interaction state (meshBlock), so it is meshed
    // inline. One block. A stored carve's crack meshes on a worker; the
    // texture source it asks locks itself.
    if (has_crack)
        return false;
    job->session = m_session.get();
    job->bp = bp;
    job->no_vertex_light = getenv("GOANNA_NO_VERTEX_LIGHT") != nullptr;
    if (!job->no_vertex_light)
        job->light.build(*m_session, bp);
    // One rule with the far field, so a near block and a far region at the
    // same distance are ordered against each other rather than each against
    // its own kind. The old constant -4096 was meant to say "near first" and
    // could not: the pool sorts by stage before priority, so it only ever
    // ordered near blocks among themselves.
    const int priority = viewPriority().of(drawn ? goanna::ViewPriority::kMaintain
                                                 : goanna::ViewPriority::kCoverage,
            goanna::godotCentreOfBlock(bp, MAP_BLOCKSIZE));
    if (!m_mesh_pool.submit(jk, generation, stage, priority, std::move(job))) {
        // A retry is not a map change, so preserve the generation. Returning
        // true tells poll_blocks not to fall back to synchronous meshing and
        // defeat the scheduler's bound.
        m_session->requeueBlock(bp);
        return true;
    }
    m_near_inflight[bp] = generation;
    return true;
}

// Publish whatever the mesh workers finished, main thread.
//
// A result is dropped when the region has gone, or when it was overtaken
// while it built: the region's generation moved on, so what came back
// describes terrain that has already changed. Dropping it leaves the last
// good mesh on screen and the newer capture is already queued behind it.
void GoannaClient::lodCollectMeshes() {
    const auto started = clock_t_::now();
    // Publication has its own soft slice so a busy capture queue cannot
    // starve finished geometry. A single upload is indivisible and may
    // exceed it; stop before starting another. Retain the count cap too.
    const double budget_ms = m_poll_budget_ms > 0 ? m_poll_budget_ms : 6.0;
    int published = 0;
    MeshPool::Done done;
    while (m_mesh_pool.next(done)) {
        if (published > 0 && ms_since(started) >= budget_ms) {
            m_mesh_pool.requeueReady(std::move(done));
            break;
        }
        if (done.key.kind == MeshJobKey::kNearBlock) {
            // Meshed, not yet drawn: poll_blocks turns it into Godot arrays
            // on its own budget, and the block stays in its far region until
            // it does.
            auto *nb = static_cast<NearBlockJob *>(done.job.get());
            auto active = m_near_inflight.find(done.key.pos);
            if (active != m_near_inflight.end() && active->second == done.generation)
                m_near_inflight.erase(active);
            auto wanted = m_near_generation.find(done.key.pos);
            if (wanted == m_near_generation.end() || wanted->second != done.generation)
                continue;
            if (nb && nb->mesh) {
                NearReady ready;
                ready.generation = done.generation;
                ready.mesh = std::move(nb->mesh);
                ready.light = std::move(nb->light);
                ready.vertex_light = std::move(nb->vertex_light);
                m_near_ready[done.key.pos] = std::move(ready);
            }
            continue;
        }
        if (done.key.kind == MeshJobKey::kNearBatch) {
            if (published >= m_lod_publish_budget) {
                // Same budget as far regions: a flood of finished batches
                // must land over several frames, not in one.
                m_mesh_pool.requeueReady(std::move(done));
                break;
            }
            auto *job = static_cast<NearBatchJob *>(done.job.get());
            auto it = m_near_regions.find(done.key.pos);
            if (!job || it == m_near_regions.end())
                continue;
            NearRegion &region = it->second;
            region.building = false;
            // Superseded: the region changed again after this snapshot was
            // captured and a fresh submit is queued or coming; publishing
            // this one would flash stale content over the newer state.
            if (done.generation != region.generation)
                continue;
            nearPublishBatch(done.key.pos, region, job->groups_out, job->occ_verts,
                    job->occ_idx, job->members, job->share_key);
            ++published;
            if (region.members.empty() && !region.dirty)
                m_near_regions.erase(it);
            continue;
        }
        if (done.key.kind == MeshJobKey::kSurface) {
            if (done.generation != m_surface_generation) continue;
            m_surface_ready.reset(static_cast<SurfaceJob *>(done.job.release()));
            m_surface_uploads.clear();
            for (const auto &kv : m_surface_ready->chunks) {
                const auto old = m_surface_regions.find(kv.first);
                if (old == m_surface_regions.end() || old->second.signature != kv.second.signature)
                    m_surface_uploads.push_back(kv.first);
            }
            continue;
        }
        if (done.key.kind != MeshJobKey::kLodRegion)
            continue;
        if (published >= m_lod_publish_budget) {
            // Over budget for regions this poll, but the queue must still be
            // drained of near results, so put this one back and stop.
            m_mesh_pool.requeueReady(std::move(done));
            break;
        }
        auto *job = static_cast<LodRegionJob *>(done.job.get());
        if (!job)
            continue;
        LodRegionKey key;
        key.pos = done.key.pos;
        key.tier = done.key.tier;
        auto it = m_lod_regions.find(key);
        if (it == m_lod_regions.end())
            continue; // the region went away while it was meshing
        LodRegion &r = it->second;
        if (job->state_revision != r.state_revision) {
            // Membership or source data changed after this snapshot. Keep the
            // last coherent node and let the current dirty state rebuild.
            r.building = false;
            continue;
        }
        if (done.generation != r.generation) {
            // Overtaken. The newer capture is queued or running; keep drawing
            // what is already there rather than showing an older shape.
            r.building = false;
            continue;
        }
        lodPublishRegion(key, r, job->result, clock_t_::now(), job->exact.cell, job->coarse.cell);
        ++published;
    }
}

} // namespace goanna
