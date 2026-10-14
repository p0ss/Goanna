// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// GoannaClient's near field, the blocks drawn from Luanti's own mesher.
// poll_blocks drains new and changed blocks nearest and most visible first,
// turns finished meshes into Godot arrays and keeps the frame's budget. The
// regional batches merge a region's blocks by material (nearAssign, nearDrop,
// nearMarkDirty, nearPublishBatch, nearBoxOccluder, nearClear). Also here:
// prune_blocks, the bevel setting, and node_tangents, the tangent basis every
// node surface upload builds. Handing blocks and batches to the mesh workers
// and collecting them is in goanna_client_jobs.cpp.
//
// Threads: Godot's main thread only. poll_blocks holds the session's map
// lock while it reads blocks; the ArrayMesh objects are made here, never on
// a worker.

#include "goanna_client_internal.h"

using namespace godot;

namespace goanna {

// Godot's NORMAL_MAP output is tangent-space. Luanti's node mesh carries
// positions, normals and UVs but no tangents, so merely binding a valid _n
// array cannot perturb the geometric normal. Build the missing basis once at
// upload time from the same indexed triangles and UVs the shader will sample.
PackedFloat32Array node_tangents(const PackedVector3Array &verts,
        const PackedVector3Array &norms, const PackedVector2Array &uvs,
        const PackedInt32Array &indices) {
    const int nv = verts.size();
    const int ni = indices.size();
    // Packed-array indexing crosses the extension boundary on each access.
    // Resolve immutable spans once; no input array is resized or written here.
    const Vector3 *positions = verts.ptr();
    const Vector3 *normals = norms.ptr();
    const Vector2 *texcoords = uvs.ptr();
    const int32_t *triangles = indices.ptr();
    std::vector<Vector3> tan((size_t)nv), bitan((size_t)nv);
    for (int i = 0; i + 2 < ni; i += 3) {
        const int ia = triangles[i], ib = triangles[i + 1], ic = triangles[i + 2];
        if (ia < 0 || ib < 0 || ic < 0 || ia >= nv || ib >= nv || ic >= nv)
            continue;
        const Vector3 e1 = positions[ib] - positions[ia];
        const Vector3 e2 = positions[ic] - positions[ia];
        const Vector2 d1 = texcoords[ib] - texcoords[ia];
        const Vector2 d2 = texcoords[ic] - texcoords[ia];
        const float det = d1.x * d2.y - d1.y * d2.x;
        if (Math::abs(det) < 1e-8f)
            continue;
        const float r = 1.0f / det;
        const Vector3 t = (e1 * d2.y - e2 * d1.y) * r;
        const Vector3 b = (e2 * d1.x - e1 * d2.x) * r;
        for (int v : {ia, ib, ic}) {
            tan[(size_t)v] += t;
            bitan[(size_t)v] += b;
        }
    }
    PackedFloat32Array out;
    out.resize(nv * 4);
    float *tangents = out.ptrw();
    for (int i = 0; i < nv; ++i) {
        const Vector3 n = normals[i].normalized();
        Vector3 t = tan[(size_t)i] - n * n.dot(tan[(size_t)i]);
        if (t.length_squared() < 1e-8f) {
            const Vector3 axis = Math::abs(n.y) < 0.9f ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
            t = axis.cross(n);
        }
        t.normalize();
        // Godot's binormal is cross(normal, tangent) times this sign and
        // points along minus V, the way its own SurfaceTool writes it;
        // the sign was the other way here, which turned every normal map
        // upside down along a tile's V axis in play (a bump lit from
        // below the sun) while the ramp, on SurfaceTool's tangents, showed
        // them right. The probe in material_ramp.gd (probe_bump) tells the
        // two apart.
        const float handedness = n.cross(t).dot(bitan[(size_t)i]) < 0.0f ? 1.0f : -1.0f;
        tangents[i * 4] = t.x;
        tangents[i * 4 + 1] = t.y;
        tangents[i * 4 + 2] = t.z;
        tangents[i * 4 + 3] = handedness;
    }
    return out;
}

void GoannaClient::set_bevel(float width) {
    if (width < 0.0f)
        width = 0.0f;
    if (width == g_goanna_bevel)
        return;
    g_goanna_bevel = width;
    // Bevelling changes geometry, so re-mesh every loaded block.
    if (m_session) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_near_blocks)
            m_session->invalidateBlock(kv.first);
    }
}

float GoannaClient::bevel() const { return g_goanna_bevel; }

v3s16 GoannaClient::nearRegionFor(const v3s16 &bp) const {
    auto fdiv = [](int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    return v3s16(fdiv(bp.X, kNearRegionBlocks), fdiv(bp.Y, kNearRegionBlocks),
            fdiv(bp.Z, kNearRegionBlocks));
}

bool GoannaClient::nearCanBatch(const MaterialKey &key) const {
    // Lava carries its continuous flow field and a subdivided surface.
    if (m_lava_tex.count(key.texture_id))
        return false;
    // The dig crack is alpha blended over its block's own surface.
    if (key.crack_overlay)
        return false;
    // A flame is blended and sorts with its own small instance.
    if (flameSurface(key))
        return false;
    if (key.array_texture)
        return true;
    // Region-sized transparent objects sort as a unit, which is visibly
    // wrong when water, glass or another blended tile overlaps a nearer
    // block. Opaque and alpha-scissored materials retain depth correctness
    // when grouped, including waving leaves and plants.
    const MaterialType type = m_session->shsrc().materialType(key.shader_id);
    switch (type) {
    case TILE_MATERIAL_ALPHA:
    case TILE_MATERIAL_PLAIN_ALPHA:
    case TILE_MATERIAL_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_BASIC:
    case TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT:
        return false;
    default:
        return true;
    }
}

bool GoannaClient::nearCanOcclude(const MaterialKey &key) const {
    if (!key.backface_culling || !m_session)
        return false;
    const MaterialType type = m_session->shsrc().materialType(key.shader_id);
    switch (type) {
    case TILE_MATERIAL_BASIC:
    case TILE_MATERIAL_OPAQUE:
    case TILE_MATERIAL_PLAIN:
        break;
    default:
        // Alpha, foliage and every liquid are deliberately excluded. A leaf
        // texture may cover most of a quad, but its holes are still a view.
        return false;
    }
    GoannaTexture *texture = m_session->tsrc()->goannaTexture(key.texture_id);
    if (texture && !texture->isArray() && texture->hasAlpha())
        return false;
    const video::E_MATERIAL_TYPE base = m_session->shsrc().baseMaterial(key.shader_id);
    return base != video::EMT_TRANSPARENT_ALPHA_CHANNEL &&
            base != video::EMT_TRANSPARENT_ALPHA_CHANNEL_REF;
}

void GoannaClient::nearMarkDirty(NearRegion &region) {
    const auto now = clock_t_::now();
    // Preserve the first invalidation time. A busy streaming region must be
    // rebuilt after the debounce even if another block arrives every frame.
    if (!region.dirty)
        region.dirty_at = now;
    // And the latest, separately: the rebuild gate wants a gap in the
    // arrivals, not merely age. Rebuilding 100 ms after the FIRST arrival
    // meant a region streaming in over a couple of seconds was rebuilt
    // five and more times, each a full batch on the main thread, and the
    // cell 1 trace put 91 per cent of all flying hitches on exactly those
    // builds (10 to 29 ms singles during arrival floods).
    region.last_dirty_at = now;
    region.dirty = true;
}

void GoannaClient::nearAssign(const v3s16 &bp) {
    auto block = m_near_blocks.find(bp);
    const bool has_regional = block != m_near_blocks.end() && !block->second.surfaces.empty();
    auto old = m_near_member.find(bp);
    if (!has_regional) {
        if (old != m_near_member.end()) {
            NearRegion &region = m_near_regions[old->second];
            region.members.erase(bp);
            nearMarkDirty(region);
            m_near_member.erase(old);
        }
        return;
    }
    const v3s16 key = nearRegionFor(bp);
    if (old != m_near_member.end() && old->second != key) {
        NearRegion &region = m_near_regions[old->second];
        region.members.erase(bp);
        nearMarkDirty(region);
    }
    NearRegion &region = m_near_regions[key];
    region.members.insert(bp);
    nearMarkDirty(region);
    m_near_member[bp] = key;
}

void GoannaClient::nearDrop(const v3s16 &bp) {
    auto member = m_near_member.find(bp);
    if (member != m_near_member.end()) {
        NearRegion &region = m_near_regions[member->second];
        region.members.erase(bp);
        nearMarkDirty(region);
        m_near_member.erase(member);
    }
    auto block = m_near_blocks.find(bp);
    if (block != m_near_blocks.end()) {
        if (block->second.special_node)
            block->second.special_node->queue_free();
        m_near_blocks.erase(block);
    }
}

void GoannaClient::nearBoxOccluder(const v3s16 &key, PackedVector3Array &occ_verts,
        PackedInt32Array &occ_idx) {
    auto emit_box = [&](float x0, float y0, float z0g, float x1, float y1, float z1g) {
        const int base = occ_verts.size();
        occ_verts.push_back(Vector3(x0, y0, z0g));
        occ_verts.push_back(Vector3(x1, y0, z0g));
        occ_verts.push_back(Vector3(x1, y1, z0g));
        occ_verts.push_back(Vector3(x0, y1, z0g));
        occ_verts.push_back(Vector3(x0, y0, z1g));
        occ_verts.push_back(Vector3(x1, y0, z1g));
        occ_verts.push_back(Vector3(x1, y1, z1g));
        occ_verts.push_back(Vector3(x0, y1, z1g));
        static const int kBox[36] = {0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
                0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2,
                0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5};
        for (int i : kBox)
            occ_idx.push_back(base + i);
    };
    // All 512 bits of one 8 node sub-cell set: strictly conservative, and
    // achievable on real terrain, which a fully solid 16 node block is not.
    auto subcell_solid = [](const std::array<uint64_t, 64> &occ, int sx, int sy,
                                 int sz) -> bool {
        for (int z = 8 * sz; z < 8 * sz + 8; ++z)
            for (int y = 8 * sy; y < 8 * sy + 8; ++y) {
                const size_t base = ((size_t)z * 16 + y) * 16 + (size_t)(8 * sx);
                if (((occ[base >> 6] >> (base & 63)) & 0xFF) != 0xFF)
                    return false;
            }
        return true;
    };
    // The whole region cube, not the member list: membership requires
    // visible surfaces, and the fully solid blocks boxes are made of have
    // none.
    for (int bz = key.Z * kNearRegionBlocks; bz < (key.Z + 1) * kNearRegionBlocks; ++bz)
    for (int by = key.Y * kNearRegionBlocks; by < (key.Y + 1) * kNearRegionBlocks; ++by)
    for (int bx = key.X * kNearRegionBlocks; bx < (key.X + 1) * kNearRegionBlocks; ++bx) {
        const v3s16 bp((s16)bx, (s16)by, (s16)bz);
        auto cit = m_lod_chains.find(bp);
        if (cit == m_lod_chains.end() || !cit->second->fine_available)
            continue;
        const auto &occ = cit->second->fine_occludes;
        bool solid[2][2][2];
        int nsolid = 0;
        for (int sz = 0; sz < 2; ++sz)
            for (int sy = 0; sy < 2; ++sy)
                for (int sx = 0; sx < 2; ++sx) {
                    solid[sz][sy][sx] = subcell_solid(occ, sx, sy, sz);
                    nsolid += solid[sz][sy][sx] ? 1 : 0;
                }
        if (nsolid == 0)
            continue;
        if (nsolid == 8) {
            const float x0 = bp.X * 16.0f;
            const float y0 = bp.Y * 16.0f;
            const float z1 = -(bp.Z * 16.0f);
            emit_box(x0, y0, z1 - 15.0f, x0 + 15.0f, y0 + 15.0f, z1);
            continue;
        }
        for (int sz = 0; sz < 2; ++sz)
            for (int sy = 0; sy < 2; ++sy)
                for (int sx = 0; sx < 2; ++sx) {
                    if (!solid[sz][sy][sx])
                        continue;
                    const float x0 = bp.X * 16.0f + 8.0f * sx;
                    const float y0 = bp.Y * 16.0f + 8.0f * sy;
                    const float z1 = -(bp.Z * 16.0f + 8.0f * sz);
                    emit_box(x0, y0, z1 - 7.0f, x0 + 7.0f, y0 + 7.0f, z1);
                }
    }
}

void GoannaClient::nearPublishBatch(const v3s16 &key, NearRegion &region,
        std::vector<NearBatchGroup> &groups, PackedVector3Array &occ_verts,
        PackedInt32Array &occ_idx, const std::vector<v3s16> &members,
        const std::string &share_key) {
    auto t0 = clock_t_::now();
    ++m_surface_source_revision;
    region.published_members = std::set<v3s16>(members.begin(), members.end());
    auto build_mesh = [&](bool glow) -> Ref<ArrayMesh> {
        const bool share = !share_key.empty() && m_shared_meshes.use_count() > 1 &&
                !getenv("GOANNA_NO_SHARED_TERRAIN") && (glow || !procedural_grass());
        const std::string mesh_key = share_key + (glow ? "glow" : "normal");
        size_t bytes = 0;
        if (share) {
            // The worker's snapshot carries the identities of its immutable
            // block inputs. Hashing megabytes of finished arrays here made
            // the cache more expensive than an upload during streaming.
            auto cached = m_shared_meshes->find(mesh_key);
            if (cached) { ++m_shared_upload_hits; return *cached; }
            for (const auto &group : groups) {
                if (group.glow != glow) continue;
                bytes += group.verts.size() * sizeof(Vector3) + group.norms.size() * sizeof(Vector3) +
                        group.uvs.size() * sizeof(Vector2) + group.uv2s.size() * sizeof(Vector2) +
                        group.cols.size() * sizeof(Color) + group.custom0.size() + group.custom2.size() +
                        group.idx.size() * sizeof(int32_t);
            }
        }
        Ref<ArrayMesh> mesh;
        mesh.instantiate();
        int si = 0;
        for (NearBatchGroup &acc : groups) {
            if (acc.glow != glow || acc.verts.is_empty() || acc.idx.is_empty())
                continue;
            Array arrays;
            arrays.resize(Mesh::ARRAY_MAX);
            arrays[Mesh::ARRAY_VERTEX] = acc.verts;
            arrays[Mesh::ARRAY_NORMAL] = acc.norms;
			arrays[Mesh::ARRAY_TANGENT] = node_tangents(acc.verts, acc.norms, acc.uvs, acc.idx);
            arrays[Mesh::ARRAY_TEX_UV] = acc.uvs;
            arrays[Mesh::ARRAY_TEX_UV2] = acc.uv2s;
            arrays[Mesh::ARRAY_COLOR] = acc.cols;
            arrays[Mesh::ARRAY_CUSTOM0] = acc.custom0;
            arrays[Mesh::ARRAY_CUSTOM2] = acc.custom2;
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), kNodeSurfaceFlags);
            if (!share) mesh->surface_set_material(si, materialFor(acc.key));
            ++si;
        }
        if (!glow && !share) {
            // Nonempty batches publish worker output outside the map lock.
            // Empty inline retirements can already hold it and need no reads.
            std::unique_lock<std::mutex> map_lock;
            if (!groups.empty() && m_session && procedural_grass())
                map_lock = std::unique_lock<std::mutex>(m_session->mapLock());
            goanna::append_grass(mesh, false, this, [this](int x, float y, int z) {
                return grassSubmerged(x, y, z, true);
            });
        }
        // Empty glow batches have no GPU upload to save or count.
        if (share && si > 0) {
            mesh->set_meta("goanna_shared_terrain", true);
            m_shared_meshes->put(mesh_key, std::make_shared<Ref<ArrayMesh>>(mesh), bytes);
        }
        return mesh;
    };
    Ref<ArrayMesh> mesh = build_mesh(false);
    Ref<ArrayMesh> glow_mesh = build_mesh(true);
    if (m_occluder_boxes) {
        occ_verts.clear();
        occ_idx.clear();
        nearBoxOccluder(key, occ_verts, occ_idx);
    }
    const float region_edge = (float)(kNearRegionBlocks * MAP_BLOCKSIZE);
    const Vector3 region_min(key.X * region_edge - 1.0f, key.Y * region_edge - 1.0f,
            -(key.Z + 1) * region_edge - 1.0f);
    const AABB region_bounds(region_min,
            Vector3(region_edge + 2.0f, region_edge + 2.0f, region_edge + 2.0f));
    auto apply = [&](MeshInstance3D *&node, const Ref<ArrayMesh> &next, bool glow) {
        if (!glow) surfaceRetire(node);
        if (next->get_surface_count() == 0) {
            if (node) {
                node->queue_free();
                node = nullptr;
            }
            return;
        }
        if (!node) {
            node = memnew(MeshInstance3D);
            node->set_layer_mask(glow ? GLOW_LAYER : 1u | NODE_SURFACE_LAYER);
            add_child(node);
        }
        // A regional mesh is deliberately culled as a region. Use its full
        // ownership cube, with room for bevel and vegetation sway, rather
        // than trusting a temporarily sparse rebuild's geometry bounds. A
        // partial batch at the frustum edge must not make other member blocks
        // disappear as the camera turns.
        node->set_custom_aabb(region_bounds);
        node->set_mesh(next);
        for (int i = 0; i < next->get_surface_count(); ++i)
            node->set_surface_override_material(i, Ref<Material>());
        if (next->has_meta("goanna_shared_terrain")) {
            int surface = 0;
            for (const auto &group : groups)
                if (group.glow == glow && !group.verts.is_empty() && !group.idx.is_empty())
                    node->set_surface_override_material(surface++, materialFor(group.key));
        }
        if (!glow)
            irisShadowTwin(node);
    };
    apply(region.node, mesh, false);
    apply(region.glow_node, glow_mesh, true);
    // The swap is timed (occluder_swap_ms, occluder_swaps in render_stats)
    // and gated by set_occluder_distance so the engine's per-commit
    // occlusion consumption, measured at about 37 per cent of flying
    // hitches on its own, stays boundable.
    bool want_occluder = !occ_idx.is_empty();
    if (want_occluder && m_occluder_distance > 0) {
        const Vector3 rc = region_min + Vector3(region_edge, region_edge, region_edge) * 0.5f;
        want_occluder = Vector2(rc.x - m_lod_centre.x, rc.z - m_lod_centre.z).length()
                <= (float)m_occluder_distance + region_edge;
    }
    if (!want_occluder) {
        if (region.occluder_node) {
            region.occluder_node->queue_free();
            region.occluder_node = nullptr;
            region.occluder_triangles = 0;
            region.occluder_hash = 0;
        }
    } else {
        // A rebuild that changed only lighting produces byte-identical
        // occluder geometry; re-committing it re-built the BVH for nothing
        // (the census caught the mass re-emission tripling the hitch rate).
        // Hash the geometry and swap only when it actually changed.
        uint64_t h = 1469598103934665603ull;
        auto mix = [&h](const uint8_t *p, size_t n) {
            for (size_t i = 0; i < n; ++i) {
                h ^= p[i];
                h *= 1099511628211ull;
            }
        };
        mix((const uint8_t *)occ_verts.ptr(), (size_t)occ_verts.size() * sizeof(Vector3));
        mix((const uint8_t *)occ_idx.ptr(), (size_t)occ_idx.size() * sizeof(int32_t));
        if (h == 0)
            h = 1;
        if (region.occluder_node == nullptr || h != region.occluder_hash) {
            const auto t_occ = clock_t_::now();
            Ref<ArrayOccluder3D> shape;
            shape.instantiate();
            shape->set_arrays(occ_verts, occ_idx);
            if (!region.occluder_node) {
                region.occluder_node = memnew(OccluderInstance3D);
                add_child(region.occluder_node);
            }
            region.occluder_node->set_occluder(shape);
            region.occluder_hash = h;
            {
                const double occ_ms_now = ms_since(t_occ);
                ema(m_ms_occluder_swap, occ_ms_now);
                m_ms_occluder_worst = std::max(m_ms_occluder_worst, occ_ms_now);
            }
            ++m_occluder_swaps;
        }
    }
    region.surfaces = mesh->get_surface_count() + glow_mesh->get_surface_count();
    region.occluder_triangles = want_occluder ? occ_idx.size() / 3 : 0;
    // Only here are region-batched block surfaces actually visible. Retire
    // their retained far copies after set_mesh(), never when the CPU-side
    // arrays were merely captured for the job. Members that left the region
    // while the job ran belong to their new owners' next publish.
    for (const v3s16 &bp : members)
        if (region.members.count(bp))
            lodFinishNearHandoff(bp);
    {
        const double batch_ms_now = ms_since(t0);
        ema(m_ms_near_batch, batch_ms_now);
        m_ms_near_batch_worst = std::max(m_ms_near_batch_worst, batch_ms_now);
    }
    if (getenv("GOANNA_DEBUG_BLOCKS"))
        UtilityFunctions::print("near region ", key.X, ",", key.Y, ",", key.Z, " publish ",
                (int)region.members.size(), " blocks ", region.surfaces, " surfaces in ",
                String::num(ms_since(t0), 2), " ms");
}

void GoannaClient::nearClear() {
    // Batch jobs in flight belong to regions that are about to vanish;
    // cancel what has not started, and the generation test drops whatever
    // a worker still finishes.
    m_mesh_pool.cancelKind(goanna::MeshJobKey::kNearBatch);
    for (auto &kv : m_near_blocks)
        if (kv.second.special_node)
            kv.second.special_node->queue_free();
    for (auto &kv : m_near_regions) {
        if (kv.second.node)
            kv.second.node->queue_free();
        if (kv.second.glow_node)
            kv.second.glow_node->queue_free();
        if (kv.second.occluder_node)
            kv.second.occluder_node->queue_free();
    }
    m_near_blocks.clear();
    m_near_regions.clear();
    m_near_member.clear();
}

int GoannaClient::prune_blocks(int radius) {
    if (!m_session)
        return 0;
    int dropped = m_session->pruneDistantBlocks(radius);
    if (dropped > 0) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        const int grant_nodes = std::min(m_session->farRenderingGrant(), m_far_distance);
        const v3s16 centre((s16)std::floor(m_lod_centre.x / MAP_BLOCKSIZE),
                (s16)std::floor(m_lod_centre.y / MAP_BLOCKSIZE),
                (s16)std::floor(-m_lod_centre.z / MAP_BLOCKSIZE));
        const int grant_blocks = std::max(0, grant_nodes / MAP_BLOCKSIZE);
        // Hand a pruned live block directly to the far renderer. Its compact
        // exact source is already in BlockStore. Keep the near mesh visible
        // while its sparse hierarchy is derived asynchronously, then retire
        // it only after the grouped far replacement has been uploaded.
        std::set<LodRegionKey> handoff_regions;
        std::set<v3s16> handoff_nodes;
        for (auto it = m_block_tier.begin(); it != m_block_tier.end();) {
            if (!m_far_blocks.count(it->first) && !m_session->getBlock(it->first)) {
                const v3s16 bp = it->first;
                if (m_near_blocks.count(bp))
                    handoff_nodes.insert(bp);
                const int tier = lodTierFor(bp, m_lod_centre, false);
                if (tier >= 1) {
                    lodAssign(bp, tier);
                    handoff_regions.insert(m_lod_member[bp]);
                    it->second = tier;
                    m_far_blocks.insert(bp);
                    if (m_near_blocks.count(bp))
                        m_lod_handoff_near.insert(bp);
                    ++it;
                } else {
                    // LOD was disabled or has no usable tier. Keep the learned
                    // chain; changing presentation must not delete knowledge.
                    lodAssign(bp, 0);
                    it = m_block_tier.erase(it);
                }
            } else {
                ++it;
            }
        }
        // Drop orphan exact meshes outside the volumetric grant immediately.
        // In-range ones are repaired into grouped ownership by the chain
        // audit below and released after those regions build.
        for (auto it = m_near_blocks.begin(); it != m_near_blocks.end();) {
            const v3s16 bp = it->first;
            if (m_session->getBlock(bp)) {
                ++it;
                continue;
            }
            const v3s16 d = bp - centre;
            if (grant_blocks > 0 && std::abs(d.X) <= grant_blocks &&
                    std::abs(d.Y) <= grant_blocks && std::abs(d.Z) <= grant_blocks) {
                ++it;
                continue;
            }
            ++it;
            m_block_lights.erase(bp);
            m_block_tier.erase(bp);
            m_block_queued_at.erase(bp);
            lodForget(bp);
            nearDrop(bp);
        }
        // The chain database is authoritative. Repair ownership from it as
        // well as from presentation bookkeeping, so no future zero-mesh,
        // interrupted-upload or unusual-node path can strand learned voxels
        // merely because it failed to leave a tier entry. Keep the grant as
        // the memory/draw bound.
        for (const auto &kv : m_lod_chains) {
            const v3s16 bp = kv.first;
            if (m_session->getBlock(bp) || m_far_blocks.count(bp) || m_far_remote.count(bp))
                continue;
            const v3s16 d = bp - centre;
            if (grant_blocks <= 0 || std::abs(d.X) > grant_blocks ||
                    std::abs(d.Y) > grant_blocks || std::abs(d.Z) > grant_blocks)
                continue;
            const int tier = lodTierFor(bp, m_lod_centre, false);
            if (tier < 1)
                continue;
            lodAssign(bp, tier);
            handoff_regions.insert(m_lod_member[bp]);
            m_block_tier[bp] = tier;
            m_far_blocks.insert(bp);
            if (m_near_blocks.count(bp))
                m_lod_handoff_near.insert(bp);
        }
        // Bypass the normal 250 ms dirty-region debounce. A region with a
        // ready chain retires its exact mesh inside lodBuildRegion; otherwise
        // that mesh remains visible until the chain queue completes it.
        for (const LodRegionKey &key : handoff_regions) {
            auto rit = m_lod_regions.find(key);
            if (rit == m_lod_regions.end())
                continue;
            lodBuildRegion(key, rit->second);
        }
        for (const v3s16 &bp : handoff_nodes) {
            if (!m_near_blocks.count(bp))
                continue;
            if (m_lod_handoff_near.count(bp))
                continue;
            m_block_lights.erase(bp);
            nearDrop(bp);
        }
        m_far_dirty = true;
    }
    return dropped;
}

int GoannaClient::poll_blocks(int max_blocks) {
    struct LiveCarveScope {
        const FormDamage *previous = g_goanna_carve;
        ~LiveCarveScope() { g_goanna_carve = previous; }
    } live_carve;
    g_goanna_carve = m_carve_active ? &m_carve.damage : nullptr;
    if (!m_session)
        return 0;
    if (m_session->prepareContentIfReady())
        return 0;
    if (m_session->contentPrepared())
        m_session->loadPushedMedia();
    std::vector<v3s16> fresh_raw = m_session->takeNewBlocks();
    std::vector<v3s16> fresh;
    int done = 0;
    auto t_poll = clock_t_::now();
    // A time budget as well as a count: a full detail block costs about 5 ms
    // to mesh and upload, so 24 of them in one poll was a 120 ms frame, which
    // is what the arrival of a new area felt like. What does not fit is
    // requeued and comes next frame. GOANNA_POLL_MS overrides the budget.
    static const double default_poll_budget_ms = [] {
        const char *v = getenv("GOANNA_POLL_MS");
        return v ? std::max(1.0, atof(v)) : 6.0;
    }();
    const double poll_budget_ms = m_poll_budget_ms > 0 ? m_poll_budget_ms : default_poll_budget_ms;
    const auto t_lock = clock_t_::now();
    std::unique_lock<std::mutex> lk(m_session->mapLock());
    ema(m_ms_poll_lock, ms_since(t_lock));
    const auto t_queue = clock_t_::now();
    // Mesh nearest-first so a backlog does not leave the block right ahead of
    // the player unmeshed (visible pop-in) while distant ones mesh in arrival
    // order. A reduced view range is also cancellation: blocks left in the
    // old queue are already in the persistent store and do not need exact GPU
    // meshes before pruneDistantBlocks releases their full node data. Before
    // this filter, lowering 40 to 12 left 182,849 stale blocks being copied,
    // sorted and requeued every frame indefinitely.
    v3f pb;
    v3s16 player_block;
    bool have_player = false;
    if (LocalPlayer *pl = m_session->player()) {
        v3f pp = pl->getPosition() * (1.0f / BS);
        pb = v3f(pp.X / MAP_BLOCKSIZE, pp.Y / MAP_BLOCKSIZE, pp.Z / MAP_BLOCKSIZE);
        player_block = v3s16((s16)std::floor(pb.X), (s16)std::floor(pb.Y), (s16)std::floor(pb.Z));
        have_player = true;
    }
    const int keep = m_session->wantedRange.load(std::memory_order_relaxed) + 4;
    std::set<v3s16> seen;
    // A notification means either this block changed, one of the boundary
    // neighbours copied into its MeshMakeData changed, or this is a retry.
    // The session revision distinguishes changes from retries, so repeatedly
    // deferring work under the frame budget cannot invalidate a running job.
    std::set<v3s16> notified(fresh_raw.begin(), fresh_raw.end());
    for (const v3s16 &bp : notified) {
        uint64_t generation = m_session->blockRevision(bp);
        if (generation == 0)
            generation = 1;
        m_near_generation[bp] = generation;
        auto ready = m_near_ready.find(bp);
        if (ready != m_near_ready.end() && ready->second.generation != generation)
            m_near_ready.erase(ready);
    }
    fresh.reserve(fresh_raw.size() + m_near_ready.size());
    // takeNewBlocks drains the session's queue, so a block is offered once.
    // A block handed to a worker was passed over on an earlier poll and is
    // not in fresh_raw any more, so put the finished ones back at the front:
    // they are the nearest work there is and their mesh is already built.
    for (const auto &kv : m_near_ready)
        if (seen.insert(kv.first).second)
            fresh.push_back(kv.first);
    for (const v3s16 &bp : fresh_raw) {
        const v3s16 d = bp - player_block;
        if (have_player && (std::abs(d.X) > keep || std::abs(d.Y) > keep || std::abs(d.Z) > keep))
            continue;
        if (seen.insert(bp).second)
            fresh.push_back(bp);
    }
    // First sight of a pending block, kept until it is actually serviced
    // below (or it leaves tracking elsewhere). The wanted() sort ages a
    // candidate off this, not off how many times it has been requeued, so a
    // block that keeps losing the camera-direction race still promotes.
    {
        const auto now_tp = clock_t_::now();
        for (const v3s16 &bp : fresh)
            m_block_queued_at.try_emplace(bp, now_tp);
    }
    auto nearer = [&](const v3s16 &a, const v3s16 &b) {
        return v3f::from(a).getDistanceFromSQ(pb) < v3f::from(b).getDistanceFromSQ(pb);
    };
    // Only the first max_blocks can possibly be consumed this frame. A full
    // sort of a six-figure backlog cost tens of milliseconds and was thrown
    // away when all but a handful were requeued. So partition in linear time
    // on plain distance, then order the band that could plausibly be reached
    // by the rule every other queue uses (goanna_schedule.h). The band is
    // wider than the frame's own count so the cone has something to choose
    // between, and small enough that its normalise per comparison does not
    // come near the cost the old full sort had.
    const size_t visit = (size_t)std::max(0, max_blocks);
    const size_t band = std::min(fresh.size(), visit * 8);
    if (band < fresh.size())
        std::nth_element(fresh.begin(), fresh.begin() + band, fresh.end(), nearer);
    if (band > 1) {
        const goanna::ViewPriority vp = viewPriority();
        // Every other scheduler in this file ages its priority (MeshPool::
        // effectivePriorityLocked, lodRegionPriority) so a candidate that
        // keeps losing on distance or camera direction still drains
        // eventually. This one did not: a block behind the player, or simply
        // outranked by a steady stream of fresh coverage ahead of it, could
        // requeue forever under the exact same weighting every frame. That is
        // how a torch placed anywhere but dead ahead could stay unlit until
        // something else forced the block to remesh, or the session
        // reconnected and rebuilt everything from scratch.
        constexpr double kAgeMs = 4000.0;
        // Score once per element, then sort on the stored score. The first
        // version of this evaluated the score inside the comparator, and
        // ms_since calls now() every time, so the same element scored
        // differently as the sort progressed: not a strict weak ordering,
        // which is undefined behaviour, and std::sort walked off the end of
        // the buffer (three SIGSEGVs on 2026-08-31, all in
        // __unguarded_insertion_sort under this frame, each after about
        // eleven minutes of flight when the band was largest). Decorating
        // also drops a map find per comparison.
        std::vector<std::pair<int, v3s16>> scored;
        scored.reserve(band);
        for (size_t i = 0; i < band; ++i) {
            const v3s16 b = fresh[i];
            double waited = 0.0;
            auto it = m_block_queued_at.find(b);
            if (it != m_block_queued_at.end())
                waited = ms_since(it->second);
            const goanna::ViewPriority::Class cls = goanna::ViewPriority::aged(
                    goanna::ViewPriority::kCoverage, waited, kAgeMs);
            scored.emplace_back(vp.of(cls, goanna::godotCentreOfBlock(b, MAP_BLOCKSIZE)), b);
        }
        std::sort(scored.begin(), scored.end(),
                [](const auto &a, const auto &b) { return a.first < b.first; });
        for (size_t i = 0; i < band; ++i)
            fresh[i] = scored[i].second;
    }
    ema(m_ms_poll_queue, ms_since(t_queue));
    const auto t_blocks = clock_t_::now();
    if (fresh_raw.size() > fresh.size() && getenv("GOANNA_DEBUG_BLOCKS")) {
        UtilityFunctions::print("block queue: cancelled ", (int64_t)(fresh_raw.size() - fresh.size()),
                " outside current range, retained ", (int64_t)fresh.size());
    }
    int visited = 0;
    for (const v3s16 &bp : fresh) {
        // Capturing and submitting worker input is main-thread work too.
        // Counting only published meshes let an arrival flood submit every
        // block before the first result, bypassing both limits entirely.
        if (visited >= max_blocks || (visited > 0 && ms_since(t_poll) > poll_budget_ms)) {
            m_session->requeueBlock(bp);
            continue;
        }
        ++visited;
        MapBlock *block = m_session->getBlock(bp);
        if (!block) {
            m_near_ready.erase(bp); // a finished job can outlive residency
            continue;
        }
        if (std::getenv("GOANNA_DEBUG_CONTENT") && !m_session->contentPrepared()) {
            static int early = 0;
            if (++early % 25 == 1)
                fprintf(stderr, "goanna content: meshing block %d before content prepared\n", early);
        }
        // Far blocks are drawn by their region's mesh at their tier, never one
        // by one: see lodBuildRegion and docs/systems/far-rendering.md.
        int tier = lodTierFor(bp, m_lod_centre, true);
        // The network handler has already persisted the compact serialised
        // block. Do not synchronously derive a second exact hierarchy for a
        // block about to receive an exact near mesh: cell-1 made this poll
        // take 90 to 127 ms while streaming. If it later leaves the live set,
        // the storage worker derives or reloads its hierarchy when needed.
        m_lod_loads.erase(bp); // invalidate any older asynchronous result
        m_lod_chains.erase(bp); // discard an older summary/store view
        m_lod_chain_queued.erase(bp); // stale deque entries are harmless
        m_lod_chain_waiters.erase(bp);
        m_lod_handoff_near.erase(bp);
        m_lod_chain_missing.erase(bp);
        m_far_blocks.erase(bp); // live now, whatever the store said
        m_far_remote.erase(bp);
        m_block_queued_at.erase(bp); // reached the front: aging starts over
        if (tier >= 1) {
            // A near worker may finish after this block has moved into LOD
            // range. Consume its ready result here too: otherwise it is put
            // back into `fresh` every frame, repeatedly discarding and
            // rebuilding the same unchanged LOD chain even while stationary.
            m_near_ready.erase(bp);
            // A live block moving out of the near radius used to disappear
            // before its asynchronous chain and far mesh were ready. Keep
            // the published near mesh until lodPublishRegion installs its
            // replacement, as the stored-block handoff already does.
            if (m_near_blocks.count(bp))
                m_lod_handoff_near.insert(bp);
            lodAssign(bp, tier);
            m_block_tier[bp] = tier;
            ++done;
            continue;
        }
        const std::string share_key = nearShareKey(bp);
        const auto shared_geometry = share_key.empty() ? nullptr : m_shared_near->find(share_key);
        if (shared_geometry) ++m_shared_near_hits;
        auto t_mesh = clock_t_::now();
        // Luanti's own light never reaches the vertices (g_goanna_no_light,
        // see goanna_mesh_flags.h), so it is read here instead, from the same
        // nodes, along with the occlusion trace. docs/systems/mesh-attributes.md.
        std::unique_ptr<MapBlockMesh> bm;
        BlockLightField lightfield;
        std::map<uint32_t, std::vector<VertexLight>> vertex_light;
        auto ready = m_near_ready.find(bp);
        if (!shared_geometry && ready != m_near_ready.end()) {
            auto wanted = m_near_generation.find(bp);
            if (wanted == m_near_generation.end() || ready->second.generation != wanted->second ||
                    ready->second.generation != m_session->blockRevision(bp)) {
                m_near_ready.erase(ready);
                if (m_mesh_pool.running() && nearSubmit(bp, block))
                    continue;
                ready = m_near_ready.end();
            }
        }
        if (shared_geometry) {
            m_near_ready.erase(bp);
            m_near_generation.erase(bp);
            m_near_inflight.erase(bp);
        } else if (ready != m_near_ready.end()) {
            bm = std::move(ready->second.mesh);
            lightfield = std::move(ready->second.light);
            vertex_light = std::move(ready->second.vertex_light);
            m_near_ready.erase(ready);
        } else if (m_mesh_pool.running() && nearSubmit(bp, block)) {
            // With a worker. Leave the block in whatever far region draws it
            // and come back when the mesh is here: that is what makes the far
            // to near hand-off atomic, and it is the hand-off that used to
            // mesh a region's worth of blocks inside one frame.
            continue;
        } else {
            bm = meshBlock(*m_session, block);
            lightfield.build(*m_session, bp);
        }
        // GOANNA_DEBUG_LIGHT=1: what the light and occlusion channels actually
        // came out as, per block. The lesson recorded against GOANNA_DEBUG_VCOL
        // applies here too: a channel that is silently constant looks exactly
        // like one that is working, in every screenshot.
        static const bool debug_light = getenv("GOANNA_DEBUG_LIGHT") != nullptr;
        static const bool no_vertex_light = getenv("GOANNA_NO_VERTEX_LIGHT") != nullptr;
        long dl_n = 0, dl_block = 0, dl_sky = 0, dl_ao = 0;
        int dl_ao_min = 255, dl_ao_max = 0, dl_sky_min = 255, dl_sky_max = 0;
        long dl_sky_bright = 0, dl_sky_dark = 0;
        ema(m_ms_mesh, ms_since(t_mesh));
        auto t_upload = clock_t_::now();
        harvestLights(bp, block);
        harvestMotes(bp, block);
        NearBlock near_block;
        if (!share_key.empty()) near_block.share_key = hashing::sha256(share_key);
        Ref<ArrayMesh> mesh;
        mesh.instantiate();
        int si = 0;
        // Accumulate by material: a block emits one buffer per tile layer, and
        // each surface is its own draw call, so buffers that resolve to the
        // same material (which array textures make common) are concatenated
        // into a single surface. This is where the draw-call saving is: the
        // array texture only makes the materials equal, merging is what turns
        // that into fewer draws.
        using SurfAccum = NearSurface;
        std::map<uint64_t, SurfAccum> groups;
        // Faces belonging to a light emitting node are collected separately and
        // drawn from a second mesh on its own render layer, which node lights
        // are told not to take shadow casters from.
        //
        // A lantern is a solid node with a light inside it, so its own cube
        // occludes its own light: the eave directly above it went dark, and a
        // wall of glowstone cast slabs of shadow across itself from whichever
        // block happened to hold the light. Both are wrong. A block that glows
        // on every face does not shadow anything with its own light.
        //
        // Only node lights ignore this layer. The sun still casts shadows from
        // glowing blocks, which is what you want: a glowstone wall should still
        // have a shadow side in daylight.
        std::map<uint64_t, SurfAccum> glow_groups;
        // The dig crack's second pass, by crack stage (crack_overlay.gdshader).
        // Only ever the one block being dug, or one holding a stored carve.
        std::map<uint64_t, SurfAccum> crack_groups;
        if (shared_geometry) {
            groups = shared_geometry->groups;
            glow_groups = shared_geometry->glow_groups;
        }
        static const bool glow_casts = getenv("GOANNA_GLOW_CASTS_SHADOW") != nullptr;
        const NodeDefManager *gnd = m_session->nodeDefs();
        for (int layer = 0; layer < MAX_TILE_LAYERS && bm; ++layer) {
            scene::IMesh *sm = bm->getMesh(layer);
            if (!sm)
                continue;
            for (u32 b = 0; b < sm->getMeshBufferCount(); ++b) {
                scene::IMeshBuffer *buf = sm->getMeshBuffer(b);
                if (!buf || buf->getVertexCount() == 0 || buf->getIndexCount() == 0)
                    continue;
                if (buf->getVertexType() != video::EVT_STANDARD)
                    continue;
                const video::S3DVertex *v = (const video::S3DVertex *)buf->getVertices();
                const u16 *idx16 = (const u16 *)buf->getIndices();
                const u32 nv = buf->getVertexCount(), ni = buf->getIndexCount();
                // What a worker already traced for this buffer, if one did.
                const std::vector<VertexLight> *vl_tab = nullptr;
                if (!vertex_light.empty()) {
                    auto vlit = vertex_light.find(((uint32_t)layer << 16) | b);
                    if (vlit != vertex_light.end() && vlit->second.size() == nv)
                        vl_tab = &vlit->second;
                }
                u16 layer_base = 0;
                MaterialKey crack_key;
                MaterialKey key = keyForIrr(buf->getMaterial(),
                        v[0].Aux & GOANNA_VERTEX_TEXTURE_MASK, &layer_base, &crack_key);
                // Approximate ownership for the semantic ID in UV2.y. Light
                // source ownership is explicit mesh metadata instead: this
                // half-node step can leave a thin torch/lantern's own cell.
                auto owner_content = [&](const u16 *tri) -> content_t {
                    if (!gnd)
                        return CONTENT_IGNORE;
                    float cx = (v[tri[0]].Pos.X + v[tri[1]].Pos.X + v[tri[2]].Pos.X) / (3.0f * BS);
                    float cy = (v[tri[0]].Pos.Y + v[tri[1]].Pos.Y + v[tri[2]].Pos.Y) / (3.0f * BS);
                    float cz = (v[tri[0]].Pos.Z + v[tri[1]].Pos.Z + v[tri[2]].Pos.Z) / (3.0f * BS);
                    float nx = v[tri[0]].Normal.X, ny = v[tri[0]].Normal.Y, nz = v[tri[0]].Normal.Z;
                    // Plantlike and similar can carry a degenerate normal; then
                    // the face centre is as good a guess as any.
                    if (nx * nx + ny * ny + nz * nz < 0.25f)
                        nx = ny = nz = 0.0f;
                    int ix = (int)floorf(cx - nx * 0.5f + 0.5f);
                    int iy = (int)floorf(cy - ny * 0.5f + 0.5f);
                    int iz = (int)floorf(cz - nz * 0.5f + 0.5f);
                    if (ix < 0 || ix >= MAP_BLOCKSIZE || iy < 0 || iy >= MAP_BLOCKSIZE ||
                            iz < 0 || iz >= MAP_BLOCKSIZE)
                        return CONTENT_IGNORE;
                    return block->getNodeNoCheck(ix, iy, iz).getContent();
                };
                const MaterialTable &mtable = m_session->materialTable();
                // One buffer is one upstream material, a whole array, but its
                // faces pick their shader by their own layer (arrayTileKey):
                // an array holding any cut-out would otherwise draw all its
                // opaque tiles through the scissor shader, which has no
                // parallax. Portal faces also leave an otherwise opaque array.
                GoannaTexture *key_tex = key.array_texture
                        ? m_session->tsrc()->goannaTexture(key.texture_id) : nullptr;
                const bool split_tiles = key_tex && (key_tex->hasAlpha() || m_portal_arrays.count(key.texture_id));
                // A buffer that left its array (a double sided tile, or a
                // special shader's) is still every face upstream merged
                // under that array, since TileLayer equality ignores the
                // layer, and keyForIrr could only name its first vertex's
                // image. Each face takes its own layer's image instead; a
                // cracked buffer keeps the composited crack image it has.
                const video::SMaterial &bmat = buf->getMaterial();
                GoannaTexture *off_array = !key.array_texture && !key.crack_overlay &&
                        !bmat.getTexture(MapBlockMesh::TEXTURE_LAYER_CRACK)
                        ? dynamic_cast<GoannaTexture *>(bmat.getTexture(0)) : nullptr;
                if (off_array && (!off_array->isArray() || off_array->layerNames().size() < 2))
                    off_array = nullptr;
                // Glass and portal faces leave the array for their own shader,
                // on their layer's image; see buildFakeLiquidTextures.
                std::map<u16, u32> layer_images;
                auto tile_key = [&](const u16 *tri) -> MaterialKey {
                    const u16 tl = (u16)((v[tri[0]].Aux & GOANNA_VERTEX_TEXTURE_MASK) + layer_base);
                    if (off_array) {
                        auto im = layer_images.find(tl);
                        if (im == layer_images.end()) {
                            const auto &names = off_array->layerNames();
                            im = layer_images.emplace(tl, tl < names.size()
                                    ? m_session->tsrc()->getTextureId(names[tl]) : 0).first;
                        }
                        MaterialKey own = key;
                        if (im->second)
                            own.texture_id = im->second;
                        return own;
                    }
                    if (!split_tiles)
                        return key;
                    auto gl = layer_images.find(tl);
                    if (gl == layer_images.end())
                        gl = layer_images.emplace(tl, specialLayer(key_tex, tl)).first;
                    if (gl->second) {
                        MaterialKey special = key;
                        special.array_texture = false;
                        special.texture_id = gl->second;
                        return special;
                    }
                    return arrayTileKey(key, key_tex, tl);
                };
                // Vertices are shared within a buffer, so each destination
                // keeps its own remap rather than duplicating every
                // triangle's three. A destination is glowing or not, by
                // material: the opaque and cut-out halves of an array, clear
                // glass, or each layer's own image off the array.
                std::map<std::pair<int, uint64_t>, std::map<u32, int>> remap;
                auto slot_of = [](int g, const MaterialKey &k) {
                    return std::make_pair(g, k.hash());
                };
                for (u32 t = 0; t + 2 < ni; t += 3) {
                    const u16 tri[3] = { idx16[t], idx16[t + 1], idx16[t + 2] };
                    const content_t owner = owner_content(tri);
                    const bool glows = !glow_casts && (v[tri[0]].Aux & GOANNA_VERTEX_GLOWS);
                    const MaterialKey tkey = tile_key(tri);
                    // Nether frame contacts, using the occlusion grid's
                    // full-cube rule. Carry four edge bits in the unused
                    // single-image UV2.x so the rim also works with lamp
                    // occlusion disabled or outside its camera-local grid.
                    int portal_edges = 0;
                    const auto portal = m_portal_tex.find(tkey.texture_id);
                    if (portal != m_portal_tex.end() && portal->second == 1 && gnd) {
                        const v3f centre = (v[tri[0]].Pos + v[tri[1]].Pos + v[tri[2]].Pos)
                                / (3.0f * BS) - v[tri[0]].Normal * 0.001f;
                        const v3s16 cell((s16)floorf(centre.X + 0.5f),
                                (s16)floorf(centre.Y + 0.5f), (s16)floorf(centre.Z + 0.5f));
                        const v3f normal = v[tri[0]].Normal;
                        // Shader axes are in Godot space, hence Luanti -Z.
                        const v3s16 u = fabsf(normal.X) > fabsf(normal.Z)
                                ? v3s16(0, 0, -1) : v3s16(1, 0, 0);
                        const v3s16 directions[] = {u, -u, v3s16(0, 1, 0), v3s16(0, -1, 0)};
                        for (int edge = 0; edge < 4; ++edge) {
                            const MapNode neighbour = m_session->map().getNode(
                                    bp * MAP_BLOCKSIZE + cell + directions[edge]);
                            const ContentFeatures &nf = gnd->get(neighbour);
                            if (neighbour.getContent() != CONTENT_IGNORE && nf.drawtype == NDT_NORMAL
                                    && !nf.light_propagates && nf.light_source == 0)
                                portal_edges |= 1 << edge;
                        }
                    }
                    const int g = glows ? 1 : 0;
                    const auto slot = slot_of(g, tkey);
                    const float block_id = owner == CONTENT_IGNORE ? 0.0f : (float)mtable.blockOf(owner);
                    SurfAccum &tacc = g ? glow_groups[tkey.hash()] : groups[tkey.hash()];
                    tacc.key = tkey;
                    tacc.is_array = tkey.array_texture;
                    for (int k = 0; k < 3; ++k) {
                        const u32 sv = tri[k];
                        std::map<u32, int> &into = remap[slot];
                        auto found = into.find(sv);
                        if (found != into.end()) {
                            tacc.idx.push_back(found->second);
                            continue;
                        }
                        const int di = tacc.verts.size();
                        tacc.verts.push_back(Vector3(v[sv].Pos.X / BS + bp.X * MAP_BLOCKSIZE,
                                v[sv].Pos.Y / BS + bp.Y * MAP_BLOCKSIZE,
                                -(v[sv].Pos.Z / BS + bp.Z * MAP_BLOCKSIZE)));
                        tacc.norms.push_back(Vector3(v[sv].Normal.X, v[sv].Normal.Y, -v[sv].Normal.Z));
                        tacc.uvs.push_back(Vector2(v[sv].TCoords.X, v[sv].TCoords.Y));
                        tacc.cols.push_back(Color(v[sv].Color.getRed() / 255.0f,
                                v[sv].Color.getGreen() / 255.0f, v[sv].Color.getBlue() / 255.0f,
                                v[sv].Color.getAlpha() / 255.0f));
                        // UV2 always, per docs/systems/mesh-attributes.md: x is the
                        // array layer, y the block semantic ID that an Iris
                        // pack reads as mc_Entity.x, from the classifier's
                        // block column for the owning node. 0 is the correct
                        // failure: unremarkable, not wrong. An animated
                        // tile's layer is its first frame in the animation
                        // array; the shader adds the frame.
                        tacc.uv2s.push_back(Vector2(tacc.is_array ?
                                (float)((v[sv].Aux & GOANNA_VERTEX_TEXTURE_MASK) + layer_base)
                                : (float)portal_edges, block_id));
                        // Luanti node coordinates, which is what the field
                        // wants: the mirrored z above is Godot's convention.
                        // GOANNA_NO_VERTEX_LIGHT=1 skips the sample and writes
                        // the neutral values, both as a kill switch and to
                        // measure what the trace costs at mesh time.
                        const VertexLight vl = no_vertex_light ? VertexLight()
                                : (vl_tab ? (*vl_tab)[sv] : lightfield.sample(
                                        v3f(v[sv].Pos.X / BS + bp.X * MAP_BLOCKSIZE,
                                                v[sv].Pos.Y / BS + bp.Y * MAP_BLOCKSIZE,
                                                v[sv].Pos.Z / BS + bp.Z * MAP_BLOCKSIZE),
                                        v3f(v[sv].Normal.X, v[sv].Normal.Y,
                                                v[sv].Normal.Z)));
                        tacc.custom0.push_back(vl.block);
                        tacc.custom0.push_back(vl.sky);
                        tacc.custom0.push_back(vl.ao);
                        tacc.custom0.push_back(255);
                        tacc.custom2.push_back(vl.corner);
                        tacc.custom2.push_back(vl.pack_block);
                        tacc.custom2.push_back(vl.pack_sky);
                        tacc.custom2.push_back(255);
                        if (debug_light) {
                            ++dl_n;
                            dl_block += vl.block;
                            dl_sky += vl.sky;
                            dl_ao += vl.ao;
                            dl_ao_min = std::min(dl_ao_min, (int)vl.ao);
                            dl_ao_max = std::max(dl_ao_max, (int)vl.ao);
                            dl_sky_min = std::min(dl_sky_min, (int)vl.sky);
                            dl_sky_max = std::max(dl_sky_max, (int)vl.sky);
                            if (vl.sky >= 200)
                                ++dl_sky_bright;
                            else if (vl.sky == 0)
                                ++dl_sky_dark;
                        }
                        into[sv] = di;
                        tacc.idx.push_back(di);
                    }
                }
                // A tile being dug: the same triangles again, for the crack
                // pass over them. Copied from what was just accumulated, so
                // the crack has exactly the positions, layer, tint and node
                // light of the surface it sits on.
                if (crack_key.crack_overlay) {
                    SurfAccum &cacc = crack_groups[crack_key.hash()];
                    cacc.key = crack_key;
                    cacc.is_array = true;
                    std::map<u32, int> crack_remap;
                    for (u32 t = 0; t + 2 < ni; t += 3) {
                        const u16 tri[3] = { idx16[t], idx16[t + 1], idx16[t + 2] };
                        const int g = !glow_casts && (v[tri[0]].Aux & GOANNA_VERTEX_GLOWS) ? 1 : 0;
                        const MaterialKey tkey = tile_key(tri);
                        const auto slot = slot_of(g, tkey);
                        const SurfAccum &src = g ? glow_groups[tkey.hash()] : groups[tkey.hash()];
                        for (int k = 0; k < 3; ++k) {
                            auto found = crack_remap.find(tri[k]);
                            if (found != crack_remap.end()) {
                                cacc.idx.push_back(found->second);
                                continue;
                            }
                            const int from = remap[slot].at(tri[k]);
                            const int di = cacc.verts.size();
                            cacc.verts.push_back(src.verts[from]);
                            cacc.norms.push_back(src.norms[from]);
                            cacc.uvs.push_back(src.uvs[from]);
                            cacc.uv2s.push_back(src.uv2s[from]);
                            cacc.cols.push_back(src.cols[from]);
                            for (int c = 0; c < 4; ++c) {
                                cacc.custom0.push_back(src.custom0[from * 4 + c]);
                                cacc.custom2.push_back(src.custom2[from * 4 + c]);
                            }
                            crack_remap[tri[k]] = di;
                            cacc.idx.push_back(di);
                        }
                    }
                }
                // GOANNA_DEBUG_VCOL=1: the spread of per vertex colour inside
                // one mesh buffer, which is the only place Luanti's baked light
                // could reach us. It exists because turning on
                // MeshMakeData::m_smooth_lighting looked like it worked and did
                // nothing at all: encode_light() returns white while
                // g_goanna_no_light is set, so every corner light collapses to
                // the same value and no screenshot can tell you so. One
                // distinct value per buffer means no light variation carried.
                if (getenv("GOANNA_DEBUG_VCOL")) {
                    int lo = 255, hi = 0;
                    std::set<int> seen;
                    for (u32 i = 0; i < nv; ++i) {
                        int g = v[i].Color.getGreen();
                        lo = std::min(lo, g);
                        hi = std::max(hi, g);
                        seen.insert(g);
                    }
                    UtilityFunctions::print("VCOL buf nv=", (int)nv, " green ", lo, "..", hi,
                            " distinct=", (int)seen.size());
                }
                // Irrlicht (left-handed) front faces are counter-clockwise as
                // stored; mirroring z makes them clockwise, which is Godot's
                // front-face winding, so the index order is kept as is.
                // indices were emitted per triangle above
            }
        }
        if (!shared_geometry && bm && !share_key.empty() && crack_groups.empty()) {
            auto geometry = std::make_shared<SharedNearGeometry>();
            geometry->groups = groups;
            geometry->glow_groups = glow_groups;
            size_t bytes = sizeof(SharedNearGeometry);
            for (const auto *surfaces : {&groups, &glow_groups})
                for (const auto &entry : *surfaces) {
                    const auto &surface = entry.second;
                    bytes += sizeof(NearSurface) + surface.verts.size() * sizeof(Vector3) +
                            surface.norms.size() * sizeof(Vector3) + surface.uvs.size() * sizeof(Vector2) +
                            surface.uv2s.size() * sizeof(Vector2) + surface.cols.size() * sizeof(Color) +
                            surface.custom0.size() + surface.custom2.size() + surface.idx.size() * sizeof(int32_t);
                }
            m_shared_near->put(share_key, geometry, bytes);
            ++m_shared_near_misses;
        }
        Ref<ArrayMesh> ice_mesh;
        ice_mesh.instantiate();
        int ice_si = 0;
        buildFakeLiquidTextures();
        // Flames, blended, on an instance of their own: it sorts by the
        // flames' own bounds rather than the whole block's water and glass,
        // and casts no shadow (docs/systems/fire-material.md).
        Ref<ArrayMesh> fmesh;
        fmesh.instantiate();
        int fsi = 0;
        auto add_flame = [&](SurfAccum &acc) {
            Array arrays;
            arrays.resize(Mesh::ARRAY_MAX);
            arrays[Mesh::ARRAY_VERTEX] = acc.verts;
            arrays[Mesh::ARRAY_NORMAL] = acc.norms;
            arrays[Mesh::ARRAY_TEX_UV] = acc.uvs;
            arrays[Mesh::ARRAY_COLOR] = acc.cols;
            arrays[Mesh::ARRAY_TEX_UV2] = acc.uv2s;
            arrays[Mesh::ARRAY_CUSTOM0] = acc.custom0;
            arrays[Mesh::ARRAY_CUSTOM2] = acc.custom2;
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            fmesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), kNodeSurfaceFlags);
            fmesh->surface_set_material(fsi++, materialFor(acc.key));
        };
        auto keep_regional = [&](SurfAccum &acc, bool glow) {
            NearSurface surface;
            surface.key = acc.key;
            surface.verts = acc.verts;
            surface.norms = acc.norms;
            surface.uvs = acc.uvs;
            surface.uv2s = acc.uv2s;
            surface.cols = acc.cols;
            surface.custom0 = acc.custom0;
            surface.custom2 = acc.custom2;
            surface.idx = acc.idx;
            surface.glow = glow;
            near_block.surfaces.push_back(std::move(surface));
        };
        for (auto &kv : groups) {
            SurfAccum &acc = kv.second;
            if (acc.verts.is_empty() || acc.idx.is_empty())
                continue;
            ++near_block.source_surfaces;
            if (flameSurface(acc.key)) {
                add_flame(acc);
                continue;
            }
            // Group every depth-writing material by its exact key. Water,
            // glass and other alpha-blended surfaces stay per block because
            // Godot sorts transparent MeshInstance3Ds as whole objects.
            if (nearCanBatch(acc.key)) {
                keep_regional(acc, false);
                continue;
            }
            Array arrays;
            arrays.resize(Mesh::ARRAY_MAX);
            arrays[Mesh::ARRAY_VERTEX] = acc.verts;
            arrays[Mesh::ARRAY_NORMAL] = acc.norms;
			arrays[Mesh::ARRAY_TANGENT] = node_tangents(acc.verts, acc.norms, acc.uvs, acc.idx);
            arrays[Mesh::ARRAY_TEX_UV] = acc.uvs;
            arrays[Mesh::ARRAY_COLOR] = acc.cols;
            arrays[Mesh::ARRAY_TEX_UV2] = acc.uv2s;
            arrays[Mesh::ARRAY_CUSTOM0] = acc.custom0;
            arrays[Mesh::ARRAY_CUSTOM2] = acc.custom2;
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            uint64_t surface_flags = kNodeSurfaceFlags;
            if (m_lava_tex.count(acc.key.texture_id)) {
                prepareLavaSurface(arrays, *m_session);
                surface_flags |= uint64_t(Mesh::ARRAY_CUSTOM_RGB_FLOAT) << Mesh::ARRAY_FORMAT_CUSTOM1_SHIFT;
            }
            // The transmission camera excludes only translucent ice. Keep
            // it separate from water and plants sharing this mapblock.
            if (m_ice_tex.count(acc.key.texture_id)) {
                ice_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays,
                        TypedArray<Array>(), Dictionary(), surface_flags);
                ice_mesh->surface_set_material(ice_si++, materialFor(acc.key));
                continue;
            }
            mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), surface_flags);
            if (si == 0 && getenv("GOANNA_DEBUG_PBR"))
                UtilityFunctions::print("surface format: tangent=",
                        (bool)(mesh->surface_get_format(0) & Mesh::ARRAY_FORMAT_TANGENT),
                        " uv2=", (bool)(mesh->surface_get_format(0) & Mesh::ARRAY_FORMAT_TEX_UV2));
            mesh->surface_set_material(si++, materialFor(acc.key));
        }
        Ref<ArrayMesh> gmesh;
        gmesh.instantiate();
        int gsi = 0;
        for (auto &kv : glow_groups) {
            SurfAccum &acc = kv.second;
            if (acc.verts.is_empty() || acc.idx.is_empty())
                continue;
            ++near_block.source_surfaces;
            if (flameSurface(acc.key)) {
                add_flame(acc);
                continue;
            }
            if (nearCanBatch(acc.key)) {
                keep_regional(acc, true);
                continue;
            }
            Array arrays;
            arrays.resize(Mesh::ARRAY_MAX);
            arrays[Mesh::ARRAY_VERTEX] = acc.verts;
            arrays[Mesh::ARRAY_NORMAL] = acc.norms;
			arrays[Mesh::ARRAY_TANGENT] = node_tangents(acc.verts, acc.norms, acc.uvs, acc.idx);
            arrays[Mesh::ARRAY_TEX_UV] = acc.uvs;
            arrays[Mesh::ARRAY_COLOR] = acc.cols;
            arrays[Mesh::ARRAY_TEX_UV2] = acc.uv2s;
            arrays[Mesh::ARRAY_CUSTOM0] = acc.custom0;
            arrays[Mesh::ARRAY_CUSTOM2] = acc.custom2;
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            uint64_t surface_flags = kNodeSurfaceFlags;
            if (m_lava_tex.count(acc.key.texture_id)) {
                prepareLavaSurface(arrays, *m_session);
                surface_flags |= uint64_t(Mesh::ARRAY_CUSTOM_RGB_FLOAT) << Mesh::ARRAY_FORMAT_CUSTOM1_SHIFT;
            }
            gmesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), surface_flags);
            gmesh->surface_set_material(gsi++, materialFor(acc.key));
        }
        // The crack pass. Drawn per block, never region batched, because it
        // is alpha blended and changes with every crack stage; the tile
        // under it stays in its regional batch with its neighbours. No
        // tangents: the crack takes the face's own normal, not the relief
        // under it.
        Ref<ArrayMesh> cmesh;
        cmesh.instantiate();
        int csi = 0;
        for (auto &kv : crack_groups) {
            SurfAccum &acc = kv.second;
            if (acc.verts.is_empty() || acc.idx.is_empty())
                continue;
            Array arrays;
            arrays.resize(Mesh::ARRAY_MAX);
            arrays[Mesh::ARRAY_VERTEX] = acc.verts;
            arrays[Mesh::ARRAY_NORMAL] = acc.norms;
            arrays[Mesh::ARRAY_TEX_UV] = acc.uvs;
            arrays[Mesh::ARRAY_COLOR] = acc.cols;
            arrays[Mesh::ARRAY_TEX_UV2] = acc.uv2s;
            arrays[Mesh::ARRAY_CUSTOM0] = acc.custom0;
            arrays[Mesh::ARRAY_CUSTOM2] = acc.custom2;
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            cmesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), kNodeSurfaceFlags);
            cmesh->surface_set_material(csi++, materialFor(acc.key));
        }
        // A block of nothing but region-batched or glowing surfaces still
        // has geometry, so all destinations have to be empty before it
        // is thrown away.
        if (near_block.surfaces.empty() && si == 0 && gsi == 0 && ice_si == 0 && csi == 0 &&
                fsi == 0) {
            if (getenv("GOANNA_DEBUG_BLOCKS") && m_near_blocks.count(bp))
                UtilityFunctions::print("block FREED (empty mesh): ", bp.X, ",", bp.Y, ",", bp.Z);
            nearDrop(bp);
            // Known enclosed air/solid has no replacement surface to wait
            // for; logical near ownership can complete immediately.
            lodAssign(bp, 0);
            // Zero triangles does not mean zero terrain. A completely
            // enclosed solid mapblock has no near faces, yet its retained
            // occupancy is essential when the live set is pruned and the
            // far volume is rebuilt. Track every processed live block so
            // prune_blocks transfers its chain; previously only blocks with
            // a MeshInstance entered m_block_tier, punching holes through
            // already visited mountains.
            m_block_tier[bp] = 0;
            if (m_occluder_boxes)
                lodEnqueueChain(bp); // buried solids are what boxes are made of
            ++done;
            continue;
        }
        nearDrop(bp);
        MeshInstance3D *mi = nullptr;
        if (si > 0 || gsi > 0 || ice_si > 0 || csi > 0 || fsi > 0) {
            mi = memnew(MeshInstance3D);
            mi->set_extra_cull_margin(0.2f);
            mi->set_layer_mask(1u | NODE_SURFACE_LAYER);
            add_child(mi);
            near_block.special_node = mi;
        }
        if (si > 0) {
            mi->set_mesh(mesh);
            irisShadowTwin(mi);
        }
        if (ice_si > 0) {
            MeshInstance3D *ice = memnew(MeshInstance3D);
            ice->set_layer_mask(ICE_LAYER);
            mi->add_child(ice);
            ice->set_mesh(ice_mesh);
            ice->add_to_group("goanna_ice");
        }
        // The glow mesh hangs off the block mesh rather than being tracked
        // beside it, so every place that frees a block frees this too and none
        // of them had to learn about it.
        MeshInstance3D *gmi = nullptr;
        if (gsi > 0) {
            gmi = memnew(MeshInstance3D);
            gmi->set_extra_cull_margin(0.2f);
            gmi->set_layer_mask(GLOW_LAYER);
            mi->add_child(gmi);
            gmi->set_mesh(gmesh);
        }
        // Hung off the block mesh like the glow mesh. The glow layer keeps
        // node lamps off it, as off every glowing surface; the margin covers
        // the shimmer pass raising a firelike quad's top edge.
        if (fsi > 0) {
            MeshInstance3D *fmi = memnew(MeshInstance3D);
            fmi->set_name("flames");
            fmi->set_extra_cull_margin(1.0f);
            fmi->set_layer_mask(GLOW_LAYER);
            fmi->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
            mi->add_child(fmi);
            fmi->set_mesh(fmesh);
        }
        // Hung off the block mesh like the glow mesh, for the same reason.
        // It casts no shadow: it is a mark on a surface that already does.
        if (csi > 0) {
            MeshInstance3D *cmi = memnew(MeshInstance3D);
            cmi->set_name("crack");
            cmi->set_extra_cull_margin(0.2f);
            cmi->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
            mi->add_child(cmi);
            cmi->set_mesh(cmesh);
        }
        m_near_blocks[bp] = std::move(near_block);
        nearAssign(bp);
        if (m_occluder_boxes)
            lodEnqueueChain(bp); // box occluders read the fine bits

        if (!m_near_blocks[bp].surfaces.empty())
            lodBeginNearHandoff(bp);
        else
            // Only unbatched special geometry: set_mesh() above already made
            // it visible, so no regional publication barrier is required.
            lodAssign(bp, 0);
        if (getenv("GOANNA_DEBUG_BLOCKS"))
            UtilityFunctions::print("block re-meshed: ", bp.X, ",", bp.Y, ",", bp.Z,
                    " source surfaces ", m_near_blocks[bp].source_surfaces, " regional ",
                    (int)m_near_blocks[bp].surfaces.size(), " special ", si + gsi);
        if (debug_light && dl_n > 0)
            UtilityFunctions::print("LIGHT block ", bp.X, ",", bp.Y, ",", bp.Z, " verts ", (int)dl_n,
                    " block ", (int)(dl_block / dl_n), " sky ", (int)(dl_sky / dl_n),
                    " (", dl_sky_min, "..", dl_sky_max, ")",
                    " ao ", (int)(dl_ao / dl_n), " (", dl_ao_min, "..", dl_ao_max, ")",
                    " skybright ", (int)(100 * dl_sky_bright / dl_n), "% skydark ",
                    (int)(100 * dl_sky_dark / dl_n), "%");
        m_block_tier[bp] = 0;
        // lodAssign(bp, 0) already dirtied the old far region. Let the normal
        // debounce coalesce all live blocks arriving in that region. Rebuilding
        // its 64-cubed cell field here for every individual block made one
        // nominally six-millisecond poll take 130 to 158 ms.
        ema(m_ms_upload, ms_since(t_upload));
        ++done;
    }
    ema(m_ms_poll_blocks, ms_since(t_blocks));
    m_last_meshed = done;
    m_last_queue = (int)fresh.size() - done;
    // Exact regional batches are the visible foreground and go first. Far
    // regions then use what remains, with a small floor so a quiet frame
    // advances both queues.
    const auto t_near = clock_t_::now();
    nearRebuild(std::max(m_poll_budget_ms > 0 ? 0.25 : 2.0, poll_budget_ms - ms_since(t_poll)));
    ema(m_ms_poll_near, ms_since(t_near));
    const auto t_lod = clock_t_::now();
    lodRebuild(std::max(m_poll_budget_ms > 0 ? 0.25 : 2.0, poll_budget_ms - ms_since(t_poll)));
    ema(m_ms_poll_lod, ms_since(t_lod));
    // The worst poll in the last second, which is the frame stall figure.
    const double took = ms_since(t_poll);
    if (ms_since(m_poll_window) > 1000.0) {
        m_ms_poll_max_last = m_ms_poll_max;
        m_ms_poll_max = 0.0;
        m_poll_window = clock_t_::now();
    }
    m_ms_poll_max = std::max(m_ms_poll_max, took);
    return done;
}

} // namespace goanna
