// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_client.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/array_occluder3d.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/occluder_instance3d.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "goanna_mesher.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include "goanna_sky.h"
#include "itemdef.h"
#include "inventory.h"
#include "util/string.h"
#include "translation.h"
#include "transplant/localplayer.h"
#include "client/mapblock_mesh.h"
#include "client/tile.h"
#include "client/node_visuals.h"
#include "goanna_light.h"
#include "goanna_store.h"
#include "util/base64.h"
#include "light.h"
#include "client/texturepaths.h"
#include "nodedef.h"
#include "settings.h"
#include <SMesh.h>
#include <CMeshBuffer.h>
#include <SMaterial.h>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <map>
#include <set>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include "mapblock.h"
#include "version.h"
#include <chrono>
#include <godot_cpp/classes/rendering_server.hpp>
#include "goanna_mesh_flags.h"
#include "itemgroup.h"
#include <godot_cpp/classes/quad_mesh.hpp>

using namespace godot;

namespace {
using clock_t_ = std::chrono::steady_clock;
inline double ms_since(const clock_t_::time_point &t0) {
    return std::chrono::duration<double, std::milli>(clock_t_::now() - t0).count();
}
// Exponential moving average: one bad frame should show, but the number
// should still be readable.
inline void ema(double &acc, double sample) { acc = acc * 0.9 + sample * 0.1; }
// Every node surface declares CUSTOM0 as four unsigned bytes: block light,
// sky light, ambient occlusion, spare. RGBA8_UNORM happens to be format 0,
// so this constant is zero today; it is named rather than assumed.
const uint64_t kNodeSurfaceFlags =
        (uint64_t)Mesh::ARRAY_CUSTOM_RGBA8_UNORM << Mesh::ARRAY_FORMAT_CUSTOM0_SHIFT;

// Godot's NORMAL_MAP output is tangent-space. Luanti's node mesh carries
// positions, normals and UVs but no tangents, so merely binding a valid _n
// array cannot perturb the geometric normal. Build the missing basis once at
// upload time from the same indexed triangles and UVs the shader will sample.
PackedFloat32Array node_tangents(const PackedVector3Array &verts,
        const PackedVector3Array &norms, const PackedVector2Array &uvs,
        const PackedInt32Array &indices) {
    const int nv = verts.size();
    std::vector<Vector3> tan((size_t)nv), bitan((size_t)nv);
    for (int i = 0; i + 2 < indices.size(); i += 3) {
        const int ia = indices[i], ib = indices[i + 1], ic = indices[i + 2];
        if (ia < 0 || ib < 0 || ic < 0 || ia >= nv || ib >= nv || ic >= nv)
            continue;
        const Vector3 e1 = verts[ib] - verts[ia];
        const Vector3 e2 = verts[ic] - verts[ia];
        const Vector2 d1 = uvs[ib] - uvs[ia];
        const Vector2 d2 = uvs[ic] - uvs[ia];
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
    for (int i = 0; i < nv; ++i) {
        const Vector3 n = norms[i].normalized();
        Vector3 t = tan[(size_t)i] - n * n.dot(tan[(size_t)i]);
        if (t.length_squared() < 1e-8f) {
            const Vector3 axis = Math::abs(n.y) < 0.9f ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
            t = axis.cross(n);
        }
        t.normalize();
        const float handedness = n.cross(t).dot(bitan[(size_t)i]) < 0.0f ? -1.0f : 1.0f;
        out[i * 4] = t.x;
        out[i * 4 + 1] = t.y;
        out[i * 4 + 2] = t.z;
        out[i * 4 + 3] = handedness;
    }
    return out;
}
// Light-emitting faces sit outside node lights' shadow caster mask. The sun
// still sees this layer.
const uint32_t GLOW_LAYER = 1u << 1;

// Two resolutions can contribute to one regional ArrayMesh. Append matching
// texture surfaces instead of leaving a cell-1 shell and cell-4 fallback as
// separate scene objects (and therefore separate draw calls).
void appendLodMesh(goanna::LodRegionMesh &dst, goanna::LodRegionMesh &&src) {
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

GoannaClient::GoannaClient() {
    const char *ab = std::getenv("GOANNA_AUTO_BUMP");
    if (ab)
        m_auto_bump = (float)atof(ab);
    const char *bv = std::getenv("GOANNA_BEVEL");
    if (bv)
        g_goanna_bevel = (float)atof(bv);
    const char *mt = std::getenv("GOANNA_MANTLE");
    if (mt)
        m_mantle = atoi(mt) != 0;
    const char *mo = std::getenv("GOANNA_MOTES");
    if (mo)
        m_motes = (float)atof(mo);
    const char *bd = std::getenv("GOANNA_BODY");
    if (bd)
        m_show_body = atoi(bd) != 0;
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
        PackedByteArray custom0;
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
        for (auto &kv : groups)
            groups_out.push_back(std::move(kv.second));
    }
};

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
        PackedInt32Array &occ_idx, const std::vector<v3s16> &members) {
    auto t0 = clock_t_::now();
    auto build_mesh = [&](bool glow) -> Ref<ArrayMesh> {
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
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), kNodeSurfaceFlags);
            mesh->surface_set_material(si++, materialFor(acc.key));
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
        if (next->get_surface_count() == 0) {
            if (node) {
                node->queue_free();
                node = nullptr;
            }
            return;
        }
        if (!node) {
            node = memnew(MeshInstance3D);
            if (glow)
                node->set_layer_mask(GLOW_LAYER);
            add_child(node);
        }
        // A regional mesh is deliberately culled as a region. Use its full
        // ownership cube, with room for bevel and vegetation sway, rather
        // than trusting a temporarily sparse rebuild's geometry bounds. A
        // partial batch at the frustum edge must not make other member blocks
        // disappear as the camera turns.
        node->set_custom_aabb(region_bounds);
        node->set_mesh(next);
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
        for (const v3s16 &bp : job->members) {
            auto block = m_near_blocks.find(bp);
            if (block == m_near_blocks.end())
                continue;
            for (const NearSurface &surface : block->second.surfaces) {
                NearBatchJob::Surface js;
                js.key = surface.key;
                js.verts = surface.verts;
                js.norms = surface.norms;
                js.uvs = surface.uvs;
                js.uv2s = surface.uv2s;
                js.cols = surface.cols;
                js.custom0 = surface.custom0;
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
                handoff_nodes.insert(bp);
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

int GoannaClient::resident_blocks() { return m_session ? (int)m_session->residentBlocks() : 0; }

void GoannaClient::set_view_range(int blocks) {
    if (m_session)
        m_session->wantedRange = blocks < 1 ? 1 : (blocks > 60 ? 60 : blocks);
}
int GoannaClient::view_range() const { return m_session ? m_session->wantedRange : 12; }
// The camera's enclosing circular field of view, in degrees. Not the vertical
// angle Godot's Camera3D carries: the server culls against a circular cone, so
// it has to reach the window corners. main.gd works it out because the
// viewport's shape is not visible here. See writePlayerPosTo for the wire.
void GoannaClient::set_view_fov(float degrees) {
    m_view_fov = std::clamp(degrees, 1.0f, 179.0f);
    if (m_session)
        m_session->cameraFov = m_view_fov;
}

void GoannaClient::set_safe_dig(bool on) { if (m_session) m_session->safeDig = on; }
bool GoannaClient::safe_dig() const { return m_session ? m_session->safeDig : false; }
void GoannaClient::set_repeat_dig_interval(float s) { if (m_session) m_session->repeatDigInterval = s < 0 ? 0 : s; }
float GoannaClient::repeat_dig_interval() const { return m_session ? m_session->repeatDigInterval : 0.0f; }
void GoannaClient::set_repeat_place_interval(float s) { if (m_session) m_session->repeatPlaceInterval = s < 0 ? 0 : s; }
float GoannaClient::repeat_place_interval() const { return m_session ? m_session->repeatPlaceInterval : 0.25f; }

void GoannaClient::set_auto_bump(float strength) {
    if (strength < 0.0f)
        strength = 0.0f;
    if (strength == m_auto_bump)
        return;
    m_auto_bump = strength;
    m_materials.clear();
    // The array path infers the same relief for layers with no authored _n
    // (docs/pbr-plan.md step 2), and its companions are cached per texture.
    if (m_session && m_session->tsrc())
        m_session->tsrc()->setInferredReliefStrength(strength);
    // Re-request the loaded blocks so their meshes pick up the new materials.
    if (m_session) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_near_blocks)
            m_session->invalidateBlock(kv.first);
    }
}
// Ice and its like are translucent because their texture says so, which puts
// them in the transparent pass, where Godot sorts whole objects by centre
// distance. A mapblock sized sheet of ice can therefore sort in front of a
// waterfall it is behind, and flip as the camera moves. Opaque puts them in
// the opaque pass, where depth decides per pixel and there is no order to get
// wrong. It is a trade rather than a fix, so it is a setting: you stop seeing
// the water under the ice. Rebuilds materials immediately, like auto bump, so
// it can be judged by dragging the toggle rather than by restarting.
void GoannaClient::set_shadow_lamps(int n) {
    m_shadow_lamps = std::max(0, std::min(64, n));
}

void GoannaClient::set_solid_ice(bool on) {
    if (on == m_solid_ice)
        return;
    m_solid_ice = on;
    m_materials.clear();
    if (m_session) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_near_blocks)
            m_session->invalidateBlock(kv.first);
    }
}
bool GoannaClient::solid_ice() const { return m_solid_ice; }

GoannaClient::~GoannaClient() {
    // Before the session and the tile cache go.
    m_mesh_pool.stop();
    if (m_horizon_thread.joinable())
        m_horizon_thread.join();
}

String GoannaClient::hello() const {
    return "goanna: extension loaded";
}

String GoannaClient::luanti_version() const {
    return String("luanti core ") + g_version_hash;
}

// The shader uniform names are the channel names; the defaults here must match
// the shaders' own, because a material built before any slider moves gets
// whatever the shader declares.
static const std::map<std::string, float> kMatStrengthDefaults = {
    {"normal", 1.0f}, {"ao", 1.0f}, {"roughness", 1.0f},
    {"specular", 1.0f}, {"emission", 4.0f}, {"sss", 1.0f},
    // Per vertex node light and occlusion, docs/mesh-attributes.md. Here
    // rather than as fixed uniforms so they can be swept at runtime, which is
    // the only way to A/B them without the world streaming differently between
    // two runs and swamping the difference being measured.
    {"sky_light", 1.0f}, {"vertex_ao", 1.0f}, {"vertex_ao_light", 0.0f},
    // stale is 0: pulling remembered terrain toward grey is a per tier
    // signal painted into the frame, and the far field is judged by there
    // being none (docs/launch-target.md, "one light, one air"). The channel
    // stays so the signal can be turned on to see what is remembered.
    {"sky_fill", 1.0f}, {"stale", 0.0f}, {"debug_nodelight", 0.0f},
    // Per class surface treatment, the stochastic tiling in
    // nodes_array_common.gdshaderinc. It is the one channel here that costs
    // frames rather than only changing a look, which is why it is a slider
    // and not a constant: 0 is the plain single sample.
    {"detail", 1.0f},
};

float GoannaClient::material_strength(const String &channel) const {
    std::string k(channel.utf8().get_data());
    auto it = m_mat_strength.find(k);
    if (it != m_mat_strength.end())
        return it->second;
    auto d = kMatStrengthDefaults.find(k);
    return d == kMatStrengthDefaults.end() ? 1.0f : d->second;
}

void GoannaClient::set_material_strength(const String &channel, float value) {
    std::string k(channel.utf8().get_data());
    if (kMatStrengthDefaults.find(k) == kMatStrengthDefaults.end()) {
        UtilityFunctions::push_warning("unknown material strength channel: ", channel);
        return;
    }
    m_mat_strength[k] = value;
    // Every material already built, not just the ones made from now on: these
    // are sliders, and a strength that only takes effect on newly meshed
    // blocks is unusable for judging a pack.
    String uniform = channel + String("_strength");
    for (auto &kv : m_materials) {
        Ref<ShaderMaterial> sm = kv.second;
        if (sm.is_valid())
            sm->set_shader_parameter(uniform, value);
    }
}

Dictionary GoannaClient::server_options() const {
    Dictionary d;
    if (!m_session)
        return d;
    for (const auto &kv : m_session->serverOptions())
        d[String(kv.first.c_str())] = String(kv.second.c_str());
    return d;
}

void GoannaClient::set_texture_map(const String &csv) {
    m_texture_map = csv;
    if (m_session)
        m_session->setTextureMap(std::string(csv.utf8().get_data()));
}

void GoannaClient::set_texture_path(const String &path) {
    // g_settings only exists once a GoannaSession has been constructed (its
    // constructor creates the SL_GLOBAL layer), which the documented calling
    // convention, before connect_to, means it usually does not yet. Remember
    // it either way; connect_to applies whatever is remembered right after
    // building the session and before start() begins requesting textures.
    // If a session already exists (called again mid-connection, to swap
    // packs), apply immediately instead of waiting for a connect_to that
    // will not come.
    m_texture_path = path;
    if (g_settings) {
        g_settings->set("texture_path", std::string(path.utf8().get_data()));
        clearTextureNameCache();
    }
}

String GoannaClient::texture_path() const {
    return m_texture_path;
}

Dictionary GoannaClient::material_diagnostics(const String &texture_name) const {
    Dictionary out;
    out["texture_path"] = m_texture_path;
    const char *disabled = getenv("GOANNA_NO_PBR");
    out["pbr_disabled"] = disabled && *disabled;
    out["materials"] = (int)m_materials.size();

    int shader_materials = 0, array_materials = 0, normals_bound = 0, specs_bound = 0;
    for (const auto &entry : m_materials) {
        Ref<ShaderMaterial> sm = entry.second;
        if (sm.is_null())
            continue;
        ++shader_materials;
        Variant has_normal = sm->get_shader_parameter("has_normal");
        Variant has_spec = sm->get_shader_parameter("has_spec");
        if (has_normal.get_type() == Variant::BOOL || has_spec.get_type() == Variant::BOOL) {
            ++array_materials;
            if (has_normal.get_type() == Variant::BOOL && (bool)has_normal)
                ++normals_bound;
            if (has_spec.get_type() == Variant::BOOL && (bool)has_spec)
                ++specs_bound;
        }
    }
    Dictionary built;
    built["shader_materials"] = shader_materials;
    built["array_materials"] = array_materials;
    built["normal_arrays_bound"] = normals_bound;
    built["spec_arrays_bound"] = specs_bound;
    out["built"] = built;

    if (!texture_name.is_empty() && m_session && m_session->tsrc()) {
        std::string base(texture_name.utf8().get_data());
        const size_t dot = base.rfind('.');
        auto companion = [&](const char *suffix) {
            return (dot == std::string::npos ? base : base.substr(0, dot)) + suffix +
                    (dot == std::string::npos ? std::string() : base.substr(dot));
        };
        Dictionary files;
        for (const char *suffix : {"", "_n", "_s"}) {
            std::string name = *suffix ? companion(suffix) : base;
            const bool found = m_session->tsrc()->isKnownSourceImage(name);
            Dictionary file;
            file["name"] = String(name.c_str());
            file["found"] = found;
            if (found) {
                core::dimension2du size = m_session->tsrc()->getTextureDimensions(name);
                file["width"] = (int)size.Width;
                file["height"] = (int)size.Height;
            }
            files[String(*suffix ? suffix + 1 : "albedo")] = file;
        }
        out["texture"] = texture_name;
        out["resolved"] = files;
    }
    return out;
}

void GoannaClient::connect_to(const String &host, int port, const String &player_name,
        const String &password) {
    // Luanti's base texture pack lives in the luanti/ checkout next to project/.
    String share = ProjectSettings::get_singleton()->globalize_path("res://../luanti");
    GoannaSession::setSharePath(share.utf8().get_data());
    nearClear();
    // Materials retain the outgoing session's texture objects. Texture ids
    // start over for each connection, so keeping this cache makes a later
    // pack reuse shader materials still bound to the first pack's arrays.
    m_materials.clear();
    m_fake_liquid_tex.clear();
    m_fake_liquid_built = false;
    m_session = std::make_unique<GoannaSession>();
    // The camera is created before connect_to(), so _report_fov() normally
    // arrives before the session. Apply the retained cone before the first
    // player-position packet or the server streams only its 70 degree
    // default and cuts vertical wedges from a wide viewport.
    m_session->cameraFov = m_view_fov;
    if (m_session->tsrc())
        m_session->tsrc()->setInferredReliefStrength(m_auto_bump);
    if (!m_store_root.is_empty())
        m_session->setStoreRoot(std::string(m_store_root.utf8().get_data()));
    m_mesh_pool.stop(); // the outgoing session owns what any job is reading
    // Meshes built against the outgoing session reference its tiles.
    m_near_ready.clear();
    m_near_inflight.clear();
    m_near_generation.clear();
    m_block_queued_at.clear();
    m_far_blocks.clear();
    m_lod_handoff_far.clear();
    m_lod_handoff_to_near.clear();
    m_lod_handoff_old_counts.clear();
    m_lod_frozen_at.clear();
    m_far_dirty = true;
    // Content ids and texture ids are per session, and so is everything the
    // far tiers cached from them.
    for (auto &kv : m_lod_regions)
        if (kv.second.node)
            kv.second.node->queue_free();
    m_lod_regions.clear();
    m_lod_member.clear();
    m_lod_chains.clear();
    m_lod_chain_queue.clear();
    m_lod_chain_queued.clear();
    m_lod_chain_waiters.clear();
    m_lod_handoff_near.clear();
    m_lod_handoff_far.clear();
    m_lod_handoff_to_near.clear();
    m_lod_handoff_old_counts.clear();
    m_lod_frozen_at.clear();
    m_lod_chain_missing.clear();
    {
        // Workers resolve tiles through this cache; take their lock.
        std::lock_guard<std::mutex> tile_lock(m_lod_tiles.mutex);
        m_lod_tiles.entries.clear();
    }
    m_lod_water.clear();
    if (!m_texture_map.is_empty())
        m_session->setTextureMap(std::string(m_texture_map.utf8().get_data()));
    // GoannaSession's constructor is what creates g_settings; set_texture_path
    // could only remember the value, not apply it, if called first as
    // documented. Apply it now, before start() begins requesting textures.
    if (!m_texture_path.is_empty() && g_settings) {
        g_settings->set("texture_path", std::string(m_texture_path.utf8().get_data()));
        // A session constructs the Luanti globals before this retained path can
        // be applied. Texture lookup is process-global and may already contain
        // misses (or directories from the preceding session), so without the
        // same invalidation set_texture_path performs, local-only _n/_s files
        // remain invisible for the lifetime of the process.
        clearTextureNameCache();
    }
    m_session->start(host.utf8().get_data(), (uint16_t)port, player_name.utf8().get_data(),
            password.utf8().get_data());
    // GOANNA_MESH_THREADS seeds the setting for a scripted run: -1 keeps
    // every mesh on the main thread, which is the comparison to make when a
    // far field fault looks like a threading one, and 0 lets the pool choose.
    // The video settings panel moves the same value.
    if (const char *env = getenv("GOANNA_MESH_THREADS"))
        m_mesh_threads = std::clamp(atoi(env), -1, 16);
    if (m_mesh_threads >= 0)
        m_mesh_pool.start(m_mesh_threads);
}

void GoannaClient::disconnect_from_server() {
    // Jobs hold the session's node definitions, texture source and material
    // table by raw pointer, so no worker may be running when it goes.
    m_mesh_pool.stop();
    m_near_ready.clear();
    m_near_inflight.clear();
    m_near_generation.clear();
    m_block_queued_at.clear();
    nearClear();
    m_session.reset();
}

Dictionary GoannaClient::status() const {
    Dictionary d;
    if (!m_session) {
        d["state"] = "none";
        return d;
    }
    SessionStats s = m_session->stats();
    d["state"] = session_state_name(s.state);
    d["message"] = String(s.message.c_str());
    d["proto_ver"] = (int)s.proto_ver;
    d["ser_ver"] = (int)s.ser_ver;
    d["node_defs"] = (int)s.node_defs;
    d["item_defs"] = (int)s.item_defs;
    d["media_announced"] = (int)s.media_announced;
    d["blocks_received"] = (int)s.blocks_received;
    d["blocks_meshed"] = (int)m_near_blocks.size();
    d["resident_blocks"] = m_session ? (int)m_session->residentBlocks() : 0;
    d["entities"] = m_entities ? m_entities->count() : 0;
    d["media_received"] = (int)s.media_received;
    d["materials"] = m_materials.size();
    d["camera_fov"] = m_session->cameraFov;
    int n_lights = 0;
    for (auto &kv : m_block_lights)
        n_lights += (int)kv.second.size();
    d["node_lights"] = n_lights;
    d["player_pos"] = Vector3(s.player_pos.X, s.player_pos.Y, -s.player_pos.Z);
    d["time_of_day"] = s.time_of_day;
    return d;
}

Vector3 GoannaClient::server_player_position() const {
    if (!m_session)
        return Vector3();
    SessionStats s = m_session->stats();
    return Vector3(s.player_pos.X, s.player_pos.Y, -s.player_pos.Z);
}

// Placing the camera has to move the local player too, not only the position
// reported to the server. Two things key off LocalPlayer rather than off the
// camera, and both break quietly when it is left behind. GoannaSession::
// pruneDistantBlocks drops every block beyond a radius of it, so flying used
// to punch holes in the terrain it flew over: blocks arrived around the
// camera, were pruned against the body two seconds later, and sendDeletedBlocks
// then told the server we no longer had them, so it sent them again. And
// step_player resumes from it, which is why switching fly off teleported you
// back to wherever walking had left the body.
void GoannaClient::set_player_pose(const Vector3 &pos, float pitch_deg, float yaw_deg) {
    if (!m_session)
        return;
    const v3f luanti(pos.x, pos.y, -pos.z);
    // Luanti's pitch is positive looking down, Godot's rotation.x positive
    // looking up; step_player negates it for the walking path and this path
    // did not. The server culls what it sends against the look direction it
    // is told (RemoteClient::GetNextBlocks), so a flying player looking 20
    // degrees down was served as one looking 20 degrees up: the ground under
    // them fell outside the cone and a hillside at the horizon was what
    // arrived at full detail, while the foreground stayed at the far tiers.
    m_session->setPlayerPose(luanti, -pitch_deg, yaw_deg);
    // The schedulers weight by where the camera looks, and this path does not
    // go through the local player's pitch and yaw, so it has to say so
    // itself. Godot's convention, unnegated: setViewAngles wants the camera's.
    setViewAngles(pitch_deg, yaw_deg);
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    if (LocalPlayer *p = m_session->player()) {
        // Every caller hands us the camera, which is the eye, but every reader
        // of the local player's position takes it for the feet: the collision
        // box stands on it, the dig ray starts an eye offset above it, and the
        // first-person body is drawn from it. Setting it to the eye put the
        // body's feet at eye height, so in fly mode (which is what the control
        // channel's "pose" turns on) the legs and waist filled the lens and
        // every screenshot had a wall of skin across it.
        p->setPosition(luanti * BS - p->getEyeOffset());
        // No inherited velocity: walking would otherwise resume with whatever
        // speed the player had when the camera took over.
        p->setSpeed(v3f(0, 0, 0));
    }
}

static Color toColor(const video::SColor &c) {
    return Color(c.getRed() / 255.0f, c.getGreen() / 255.0f, c.getBlue() / 255.0f, c.getAlpha() / 255.0f);
}
static Vector3 toGodotDir(const v3f &v) { return Vector3(v.X, v.Y, -v.Z); }

// ---- in-game data for the UI layer ----

Array GoannaClient::take_chat() {
    Array out;
    if (!m_session)
        return out;
    for (auto &line : m_session->takeChat()) {
        Dictionary d;
        d["type"] = (int)line.type;
        d["sender"] = String::utf8(wide_to_utf8(unescape_translate(line.sender)).c_str());
        d["message"] = String::utf8(wide_to_utf8(unescape_translate(line.message)).c_str());
        d["raw_message"] = String::utf8(wide_to_utf8(line.message).c_str());
        out.push_back(d);
    }
    return out;
}

void GoannaClient::send_chat(const String &message) {
    if (m_session)
        m_session->sendChat(utf8_to_wide(message.utf8().get_data()));
}

int GoannaClient::hp() const { return m_session ? m_session->hp() : 0; }
int GoannaClient::breath() const { return m_session ? m_session->breath() : 0; }

Dictionary GoannaClient::hud_state() const {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->hudLock());
    Array elems;
    for (auto &kv : m_session->hudElements()) {
        const HudElement &e = kv.second;
        Dictionary h;
        h["id"] = (int)kv.first;
        h["type"] = (int)e.type;
        h["pos"] = Vector2(e.pos.X, e.pos.Y);
        h["name"] = String::utf8(e.name.c_str());
        h["scale"] = Vector2(e.scale.X, e.scale.Y);
        h["text"] = String::utf8(e.text.c_str());
        h["number"] = (int)e.number;
        h["item"] = (int)e.item;
        h["dir"] = (int)e.dir;
        h["align"] = Vector2(e.align.X, e.align.Y);
        h["offset"] = Vector2(e.offset.X, e.offset.Y);
        h["world_pos"] = Vector3(e.world_pos.X, e.world_pos.Y, -e.world_pos.Z);
        h["size"] = Vector2(e.size.X, e.size.Y);
        h["z_index"] = (int)e.z_index;
        h["text2"] = String::utf8(e.text2.c_str());
        h["style"] = (int)e.style;
        elems.push_back(h);
    }
    d["elements"] = elems;
    d["flags"] = (int)m_session->hudFlags();
    d["version"] = (int)m_session->hudVersion();
    d["hotbar_itemcount"] = (int)m_session->hotbarItemCount();
    d["hotbar_image"] = String::utf8(m_session->hotbarImage().c_str());
    d["hotbar_selected_image"] = String::utf8(m_session->hotbarSelectedImage().c_str());
    d["hp"] = (int)m_session->hp();
    d["breath"] = (int)m_session->breath();
    return d;
}

static Dictionary inventoryLists(Inventory *inv, IItemDefManager *idef) {
    Dictionary lists;
    if (!inv)
        return lists;
    for (InventoryList *list : inv->getLists()) {
        Array items;
        for (u32 i = 0; i < list->getSize(); ++i) {
            const ItemStack &st = list->getItem(i);
            Dictionary it;
            it["name"] = String::utf8(st.name.c_str());
            it["count"] = (int)st.count;
            it["wear"] = (int)st.wear;
            if (!st.name.empty() && idef) {
                const ItemDefinition &def = st.getDefinition(idef);
                it["description"] = String::utf8(def.description.c_str());
                it["inventory_image"] = String::utf8(def.inventory_image.name.c_str());
                it["stack_max"] = (int)def.stack_max;
                it["type"] = (int)def.type;
            }
            items.push_back(it);
        }
        lists[String::utf8(list->getName().c_str())] = items;
    }
    return lists;
}

Dictionary GoannaClient::inventory_state() {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    d["version"] = (int)m_session->inventoryVersion();
    d["lists"] = inventoryLists(m_session->inventory(), m_session->getItemDefManager());
    return d;
}

Dictionary GoannaClient::inventory_state_at(const String &location) {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    Inventory *inv = m_session->inventoryAt(location.utf8().get_data());
    d["found"] = inv != nullptr;
    d["version"] = (int)(m_session->inventoryVersion() + m_session->detachedVersion());
    d["lists"] = inventoryLists(inv, m_session->getItemDefManager());
    return d;
}

PackedStringArray GoannaClient::detached_inventory_names() {
    PackedStringArray names;
    if (!m_session)
        return names;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    for (auto &kv : m_session->detachedInventories())
        names.push_back(String::utf8(kv.first.c_str()));
    return names;
}

void GoannaClient::respawn() {
    // 5.16 servers show builtin's "__builtin:death" formspec; closing it
    // with quit set is what respawns the player (builtin/game/death_screen.lua).
    if (m_session)
        m_session->sendInventoryFields("__builtin:death", {{"quit", "true"}});
}

Ref<Texture2D> GoannaClient::texture(const String &name) {
    if (!m_session)
        return Ref<Texture2D>();
    u32 id = m_session->tsrc()->getTextureId(name.utf8().get_data());
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(id);
    if (!gt)
        return Ref<Texture2D>();
    return gt->godotTexture();
}

Ref<Texture2D> GoannaClient::item_icon(const String &item_name) {
    if (!m_session)
        return Ref<Texture2D>();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    IItemDefManager *idef = m_session->getItemDefManager();
    ItemStack stack(item_name.utf8().get_data(), 1, 0, idef);
    if (stack.name.empty())
        return Ref<Texture2D>();
    ItemImageDef img = stack.getInventoryImage(idef);
    std::string tex = img.name;
    if (tex.empty()) {
        const ItemDefinition &def = stack.getDefinition(idef);
        if (def.type != ITEM_NODE && !def.inventory_image.name.empty())
            tex = def.inventory_image.name;
    }
    if (tex.empty()) {
        // Node item with no flat inventory image. Compose an isometric cube
        // icon with Luanti's own [inventorycube modifier (builtin's
        // core.inventorycube: top, left, right, with ^ escaped as &), which
        // runs entirely in the image pipeline: no offscreen 3D pass, and it
        // caches like any other generated texture. Tile order is
        // +Y,-Y,+X,-X,+Z,-Z, so top/left/right are tiles 0, 3 and 4.
        const ContentFeatures &f = m_session->nodeDefs()->get(stack.name);
        if (f.visuals) {
            auto tile_name = [&](int i) {
                const TileLayer &tl = f.visuals->tiles[i].layers[0];
                std::string n = tl.texture_id
                        ? m_session->tsrc()->imageName(tl.texture_id, tl.texture_layer_idx)
                        : std::string();
                std::replace(n.begin(), n.end(), '^', '&');
                return n;
            };
            std::string top = tile_name(0), left = tile_name(3), right = tile_name(4);
            if (left.empty()) left = top;
            if (right.empty()) right = left;
            if (!top.empty() && f.drawtype != NDT_AIRLIKE)
                tex = "[inventorycube{" + top + "{" + left + "{" + right;
            else
                tex = top;
        }
    }
    if (tex.empty())
        return Ref<Texture2D>();
    u32 id = m_session->tsrc()->getTextureId(tex);
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(id);
    if (!gt)
        return Ref<Texture2D>();
    return gt->godotTexture();
}

String GoannaClient::inventory_formspec() const {
    return m_session ? String::utf8(m_session->inventoryFormspec().c_str()) : String();
}

Array GoannaClient::take_shown_formspecs() {
    Array out;
    if (!m_session)
        return out;
    for (auto &fs : m_session->takeShownFormspecs()) {
        Dictionary d;
        d["formspec"] = String::utf8(fs.formspec.c_str());
        d["formname"] = String::utf8(fs.formname.c_str());
        d["context"] = String::utf8(fs.context.c_str());
        out.push_back(d);
    }
    return out;
}

void GoannaClient::send_nodemeta_fields(const String &context, const String &formname, const Dictionary &fields) {
    if (!m_session)
        return;
    std::string ctx = context.utf8().get_data();
    if (ctx.rfind("nodemeta:", 0) != 0)
        return;
    std::string coords = ctx.substr(9);
    std::replace(coords.begin(), coords.end(), ',', ' ');
    std::istringstream is(coords);
    v3s16 p;
    is >> p.X >> p.Y >> p.Z;
    if (is.fail())
        return;
    std::map<std::string, std::string> f;
    Array keys = fields.keys();
    for (int i = 0; i < keys.size(); ++i)
        f[String(keys[i]).utf8().get_data()] = String(fields[keys[i]]).utf8().get_data();
    m_session->sendNodemetaFields(p, formname.utf8().get_data(), f);
}

void GoannaClient::send_inventory_fields(const String &formname, const Dictionary &fields) {
    if (!m_session)
        return;
    std::map<std::string, std::string> f;
    Array keys = fields.keys();
    for (int i = 0; i < keys.size(); ++i) {
        String k = keys[i];
        String v = fields[keys[i]];
        f[k.utf8().get_data()] = v.utf8().get_data();
    }
    m_session->sendInventoryFields(formname.utf8().get_data(), f);
}

int GoannaClient::wield_index() const {
    return m_session ? m_session->wieldIndex() : 0;
}

void GoannaClient::inventory_action(const String &action) {
    if (m_session)
        m_session->sendInventoryAction(action.utf8().get_data());
}

void GoannaClient::set_wield_index(int index) {
    if (!m_session)
        return;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    m_session->setWieldIndex((u16)index);
}

Dictionary GoannaClient::step_interact(double dt, bool dig, bool place, bool place_pressed, bool sneak) {
    Dictionary d;
    d["type"] = "nothing";
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    LocalPlayer *p = m_session->player();
    if (!p)
        return d;
    GoannaSession::InteractInput in;
    in.dig = dig;
    in.place = place;
    in.place_pressed = place_pressed;
    in.sneak = sneak;
    // Tell the server which of the two buttons is down. A vanilla client sends
    // this in every position packet; Goanna sent zero, so no game ever saw the
    // local player digging and no game ever played its mining animation on the
    // body, which is most of why the first-person arm looked wrong in a dig.
    m_session->setPlayerKeys(dig, place);
    in.eye_pos_bs = p->getPosition() + p->getEyeOffset();
    // Luanti camera direction from pitch/yaw (Camera::update)
    float pitch = p->getPitch(), yaw = p->getYaw();
    v3f dir(0, 0, 1);
    dir.rotateYZBy(pitch);
    dir.rotateXZBy(yaw);
    in.look_dir = dir.normalize();
    m_session->stepInteract((float)dt, in);
    const auto &st = m_session->interactState();
    const PointedThing &pt = st.pointed;
    if (pt.type == POINTEDTHING_NODE) {
        d["type"] = "node";
        d["node"] = Vector3(pt.node_undersurface.X, pt.node_undersurface.Y, -pt.node_undersurface.Z);
        d["above"] = Vector3(pt.node_abovesurface.X, pt.node_abovesurface.Y, -pt.node_abovesurface.Z);
        d["point"] = Vector3(pt.intersection_point.X / BS, pt.intersection_point.Y / BS, -pt.intersection_point.Z / BS);
        d["node_name"] = String::utf8(m_session->nodeDefs()->get(m_session->map().getNode(pt.node_undersurface)).name.c_str());
    } else if (pt.type == POINTEDTHING_OBJECT) {
        d["type"] = "object";
        d["object_id"] = (int)pt.object_id;
        auto it = m_session->objects().find(pt.object_id);
        if (it != m_session->objects().end())
            d["object_name"] = String::utf8(it->second->name().c_str());
    }
    d["digging"] = st.digging;
    d["progress"] = st.dig_time_complete > 0 && st.dig_time_complete < 100000.0f
            ? std::min(1.0f, st.dig_time / st.dig_time_complete) : 0.0f;
    d["crack_level"] = st.crack_level;
    return d;
}

bool GoannaClient::is_underwater(const Vector3 &eye) {
    const bool under = isUnderwaterAt(eye);
    // The water shader drops back faces unless the eye is in the water, and
    // learns where the eye is from this global; main.gd asks every frame.
    static bool last = false;
    static bool first = true;
    if (first || under != last) {
        RenderingServer::get_singleton()->global_shader_parameter_set("goanna_eye_underwater", under ? 1.0f : 0.0f);
        last = under;
        first = false;
    }
    return under;
}

bool GoannaClient::isUnderwaterAt(const Vector3 &eye) {
    if (!m_session)
        return false;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    // Godot (x, y, -z) nodes -> Luanti node coordinates.
    v3s16 p((s16)std::floor(eye.x + 0.5f), (s16)std::floor(eye.y + 0.5f), (s16)std::floor(-eye.z + 0.5f));
    MapNode n = m_session->map().getNode(p);
    if (n.getContent() == CONTENT_IGNORE)
        return false;
    return m_session->nodeDefs()->get(n).isLiquid();
}

void GoannaClient::set_time_of_day_override(float tod) {
    if (m_session)
        m_session->setTimeOfDayOverride(tod);
}

Array GoannaClient::take_sounds() {
    Array out;
    if (!m_session)
        return out;
    for (auto &ev : m_session->takeSounds()) {
        Dictionary d;
        d["id"] = (int)ev.server_id;
        d["name"] = String::utf8(ev.name.c_str());
        d["gain"] = ev.gain;
        d["pitch"] = ev.pitch;
        d["loop"] = ev.loop;
        d["positional"] = ev.positional;
        d["position"] = Vector3(ev.pos.X, ev.pos.Y, ev.pos.Z);
        d["object_id"] = (int)ev.object_id;
        d["start_time"] = ev.start_time;
        out.push_back(d);
    }
    return out;
}

PackedInt32Array GoannaClient::take_stopped_sounds() {
    PackedInt32Array out;
    if (!m_session)
        return out;
    for (s32 id : m_session->takeStoppedSounds())
        out.push_back(id);
    return out;
}

static inline Vector3 gv(const v3f &v) { return Vector3(v.X, v.Y, v.Z); }

Array GoannaClient::take_particle_spawners() {
    Array out;
    if (!m_session)
        return out;
    for (auto &e : m_session->takeParticleSpawners()) {
        Dictionary d;
        d["id"] = (int)e.id;
        d["amount"] = (int)e.amount;
        d["time"] = e.time;
        d["pos_min"] = gv(e.pos_min); d["pos_max"] = gv(e.pos_max);
        d["vel_min"] = gv(e.vel_min); d["vel_max"] = gv(e.vel_max);
        d["acc_min"] = gv(e.acc_min); d["acc_max"] = gv(e.acc_max);
        d["exp_min"] = e.exp_min; d["exp_max"] = e.exp_max;
        d["size_min"] = e.size_min; d["size_max"] = e.size_max;
        d["texture"] = String::utf8(e.texture.c_str());
        d["vertical"] = e.vertical;
        d["collision"] = e.collision;
        d["attached_id"] = (int)e.attached_id;
        d["glow"] = (int)e.glow;
        d["collision_removal"] = e.collision_removal;
        d["object_collision"] = e.object_collision;
        d["blend_mode"] = (int)e.blend_mode;
        d["anim_type"] = e.anim_type;
        d["anim_a"] = e.anim_a;
        d["anim_b"] = e.anim_b;
        d["anim_frame_length"] = e.anim_frame_length;
        d["node_param0"] = (int)e.node_param0;
        d["node_param2"] = (int)e.node_param2;
        d["node_tile"] = (int)e.node_tile;
        d["drag"] = gv(e.drag);
        d["jitter_min"] = gv(e.jitter_min); d["jitter_max"] = gv(e.jitter_max);
        d["bounce_min"] = e.bounce_min; d["bounce_max"] = e.bounce_max;
        d["radius_min"] = gv(e.radius_min); d["radius_max"] = gv(e.radius_max);
        d["attractor_kind"] = (int)e.attractor_kind;
        d["attract_min"] = e.attract_min; d["attract_max"] = e.attract_max;
        d["attractor_origin"] = gv(e.attractor_origin);
        d["attractor_direction"] = gv(e.attractor_direction);
        d["attractor_kill"] = e.attractor_kill;
        // The pool a spawner picks each particle's texture from. One entry is
        // the ordinary case and means the same thing as "texture".
        Array pool;
        for (const auto &t : e.texpool)
            pool.push_back(String::utf8(t.c_str()));
        d["texpool"] = pool;
        out.push_back(d);
    }
    return out;
}

Array GoannaClient::take_dug_nodes() {
    Array out;
    if (!m_session)
        return out;
    for (auto &e : m_session->takeDugNodes()) {
        Dictionary d;
        d["pos"] = gv(e.pos);
        d["texture"] = String::utf8(e.texture.c_str());
        d["count"] = e.count;
        d["colour"] = Color(((e.colour >> 16) & 0xff) / 255.0f, ((e.colour >> 8) & 0xff) / 255.0f,
                (e.colour & 0xff) / 255.0f, ((e.colour >> 24) & 0xff) / 255.0f);
        out.push_back(d);
    }
    return out;
}

PackedInt32Array GoannaClient::take_deleted_spawners() {
    PackedInt32Array out;
    if (!m_session)
        return out;
    for (u32 id : m_session->takeDeletedSpawners())
        out.push_back((int)id);
    return out;
}

Array GoannaClient::take_particles() {
    Array out;
    if (!m_session)
        return out;
    for (auto &e : m_session->takeParticles()) {
        Dictionary d;
        d["position"] = gv(e.pos);
        d["velocity"] = gv(e.vel);
        d["acceleration"] = gv(e.acc);
        d["expirationtime"] = e.expirationtime;
        d["size"] = e.size;
        d["texture"] = String::utf8(e.texture.c_str());
        out.push_back(d);
    }
    return out;
}

PackedStringArray GoannaClient::media_names() {
    PackedStringArray out;
    if (!m_session)
        return out;
    for (const auto &n : m_session->mediaNames())
        out.push_back(String::utf8(n.c_str()));
    return out;
}

String GoannaClient::node_name_at(const Vector3 &pos) {
    if (!m_session)
        return String();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    v3s16 np((s16)floorf(pos.x + 0.5f), (s16)floorf(pos.y + 0.5f), (s16)floorf(-pos.z + 0.5f));
    MapNode n = m_session->map().getNode(np);
    return String::utf8(m_session->nodeDefs()->get(n).name.c_str());
}

// What colour the ground around the given point would throw back: the tile
// colour of the surface found under a coarse grid of columns, palette tint
// included (Mineclonia's grass is a grey texture; the green is param2).
// main.gd feeds it to the bounce light and the shader ground fill, so an
// object's underside is tinted by what it actually stands on: red desert,
// green plain, blue over open sea (weighted down: water throws back little
// diffuse light). Alpha carries the share of columns that answered, so a
// caller can hold its last tint when nothing is loaded.
// Mean surface height of the loaded columns just under the given point, or
// -1e9 when none answer (the scan reaches only a little below the camera, so
// high flight keeps the caller's last answer). main.gd anchors the haze
// layer with it, so the depth fog thins as the camera climbs above the
// terrain instead of drowning the whole ground from altitude.
float GoannaClient::ground_height(const Vector3 &center) {
    if (!m_session)
        return -1e9f;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    const s16 cx = (s16)floorf(center.x + 0.5f);
    const s16 cy = (s16)floorf(center.y + 0.5f);
    const s16 cz = (s16)floorf(-center.z + 0.5f);
    float sum = 0.0f;
    int n = 0;
    for (int dz = -4; dz <= 4; ++dz)
        for (int dx = -4; dx <= 4; ++dx)
            for (s16 y = cy + 8; y >= cy - 24; --y) {
                MapNode nd = m_session->map().getNode(v3s16(cx + dx * 3, y, cz + dz * 3));
                const content_t c = nd.getContent();
                if (c == CONTENT_AIR)
                    continue;
                if (c == CONTENT_IGNORE)
                    break;
                sum += (float)y;
                ++n;
                break;
            }
    return n >= 20 ? sum / (float)n : -1e9f;
}

Color GoannaClient::ground_albedo(const Vector3 &center) {
    if (!m_session)
        return Color(0.5f, 0.5f, 0.5f, 0.0f);
    // Two phases, because composing a tile image to average it is
    // milliseconds and this runs twice a second forever: the map walk under
    // its lock only gathers each column's surface (content, param2), and
    // colours come from a per content cache afterwards. At most a few
    // uncached contents are composed per call, so entering a new biome
    // warms the cache over a couple of samples instead of hitching one
    // frame; unresolved columns simply sit this sample out. The uncached
    // path was the difference between 90 and under 30 frames a second.
    struct Sample {
        content_t c;
        u16 param2;
    };
    std::vector<Sample> samples;
    int cols = 0;
    {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        const NodeDefManager *ndef = m_session->nodeDefs();
        const s16 cx = (s16)floorf(center.x + 0.5f);
        const s16 cy = (s16)floorf(center.y + 0.5f);
        const s16 cz = (s16)floorf(-center.z + 0.5f);
        for (int dz = -4; dz <= 4; ++dz)
            for (int dx = -4; dx <= 4; ++dx) {
                ++cols;
                for (s16 y = cy + 8; y >= cy - 16; --y) {
                    MapNode n = m_session->map().getNode(v3s16(cx + dx * 3, y, cz + dz * 3));
                    const content_t c = n.getContent();
                    if (c == CONTENT_AIR)
                        continue;
                    if (c == CONTENT_IGNORE)
                        break;
                    const ContentFeatures &f = ndef->get(n);
                    if (!f.visuals || !f.visuals->tiles[0].layers[0].texture_id)
                        break;
                    samples.push_back({c, n.getParam2()});
                    break;
                }
            }
    }
    const NodeDefManager *ndef = m_session->nodeDefs();
    int budget = 4;
    float r = 0.0f, g = 0.0f, b = 0.0f, w = 0.0f;
    int answered = 0;
    for (const Sample &s : samples) {
        auto it = m_ground_albedo_cache.find(s.c);
        if (it == m_ground_albedo_cache.end()) {
            if (budget <= 0)
                continue;
            --budget;
            const ContentFeatures &f = ndef->get(s.c);
            const TileLayer &tl = f.visuals->tiles[0].layers[0];
            const std::string tname = m_session->tsrc()->imageName(tl.texture_id, tl.texture_layer_idx);
            video::SColor avg(0, 0, 0, 0);
            if (!tname.empty())
                avg = m_session->tsrc()->getTextureAverageColor(tname);
            it = m_ground_albedo_cache.emplace(s.c, avg.color).first;
        }
        const video::SColor avg(it->second);
        if (avg.getAlpha() == 0)
            continue;
        const ContentFeatures &f = ndef->get(s.c);
        video::SColor pc(255, 255, 255, 255);
        f.visuals->getColor(s.param2, &pc);
        const float wt = f.isLiquid() ? 0.35f : 1.0f;
        r += (avg.getRed() / 255.0f) * (pc.getRed() / 255.0f) * wt;
        g += (avg.getGreen() / 255.0f) * (pc.getGreen() / 255.0f) * wt;
        b += (avg.getBlue() / 255.0f) * (pc.getBlue() / 255.0f) * wt;
        w += wt;
        ++answered;
    }
    if (w <= 0.0f)
        return Color(0.5f, 0.5f, 0.5f, 0.0f);
    return Color(r / w, g / w, b / w, (float)answered / (float)cols);
}

PackedByteArray GoannaClient::media_bytes(const String &name) {
    PackedByteArray out;
    std::string data;
    if (m_session && m_session->mediaBytes(name.utf8().get_data(), data)) {
        out.resize((int64_t)data.size());
        memcpy(out.ptrw(), data.data(), data.size());
    }
    return out;
}

Dictionary GoannaClient::node_sound(const String &node_name, const String &kind) {
    Dictionary d;
    if (!m_session)
        return d;
    std::string sname;
    float gain = 1.0f, pitch = 1.0f;
    if (!m_session->nodeSound(node_name.utf8().get_data(), kind.utf8().get_data(), sname, gain, pitch))
        return d;
    d["name"] = String::utf8(sname.c_str());
    d["gain"] = gain;
    d["pitch"] = pitch;
    return d;
}

Dictionary GoannaClient::sky_state() const {
    Dictionary d;
    if (!m_session)
        return d;
    SkyState st = m_session->skyState();
    d["version"] = (int)st.version;
    d["time_of_day"] = st.time_of_day;
    d["time_speed"] = st.time_speed;
    d["wicked_time_of_day"] = getWickedTimeOfDay(st.time_of_day);
    float ratio = st.day_night_override ? st.day_night_override_ratio : dayNightRatio(st.time_of_day) / 1000.0f;
    d["day_night_ratio"] = ratio;
    d["sun_direction"] = toGodotDir(sunDirection(st.time_of_day, st.sky.body_orbit_tilt));
    d["moon_direction"] = toGodotDir(moonDirection(st.time_of_day, st.sky.body_orbit_tilt));
    Dictionary sky;
    sky["type"] = String(st.sky.type.c_str());
    sky["bgcolor"] = toColor(st.sky.bgcolor);
    sky["clouds"] = st.sky.clouds;
    sky["fog_sun_tint"] = toColor(st.sky.fog_sun_tint);
    sky["fog_moon_tint"] = toColor(st.sky.fog_moon_tint);
    sky["fog_tint_type"] = String(st.sky.fog_tint_type.c_str());
    sky["fog_distance"] = st.sky.fog_distance;
    sky["fog_start"] = st.sky.fog_start;
    sky["fog_color"] = toColor(st.sky.fog_color);
    sky["day_sky"] = toColor(st.sky.sky_color.day_sky);
    sky["day_horizon"] = toColor(st.sky.sky_color.day_horizon);
    sky["dawn_sky"] = toColor(st.sky.sky_color.dawn_sky);
    sky["dawn_horizon"] = toColor(st.sky.sky_color.dawn_horizon);
    sky["night_sky"] = toColor(st.sky.sky_color.night_sky);
    sky["night_horizon"] = toColor(st.sky.sky_color.night_horizon);
    sky["indoors"] = toColor(st.sky.sky_color.indoors);
    Array textures;
    for (auto &t : st.sky.textures) textures.push_back(String(t.c_str()));
    sky["textures"] = textures;
    d["sky"] = sky;
    Dictionary sun;
    sun["visible"] = st.sun.visible;
    sun["texture"] = String(st.sun.texture.c_str());
    sun["sunrise_visible"] = st.sun.sunrise_visible;
    sun["scale"] = st.sun.scale;
    d["sun"] = sun;
    Dictionary moon;
    moon["visible"] = st.moon.visible;
    moon["texture"] = String(st.moon.texture.c_str());
    moon["scale"] = st.moon.scale;
    d["moon"] = moon;
    Dictionary stars;
    stars["visible"] = st.stars.visible;
    stars["count"] = (int)st.stars.count;
    stars["color"] = toColor(st.stars.starcolor);
    stars["scale"] = st.stars.scale;
    stars["day_opacity"] = st.stars.day_opacity;
    d["stars"] = stars;
    Dictionary clouds;
    clouds["density"] = st.clouds.density;
    clouds["color_bright"] = toColor(st.clouds.color_bright);
    clouds["color_ambient"] = toColor(st.clouds.color_ambient);
    clouds["color_shadow"] = toColor(st.clouds.color_shadow);
    clouds["height"] = st.clouds.height;
    clouds["thickness"] = st.clouds.thickness;
    clouds["speed"] = Vector2(st.clouds.speed.X, st.clouds.speed.Y);
    d["clouds"] = clouds;
    Dictionary lighting;
    lighting["shadow_intensity"] = st.lighting.shadow_intensity;
    lighting["saturation"] = st.lighting.saturation;
    lighting["exposure_correction"] = st.lighting.exposure.exposure_correction;
    lighting["luminance_min"] = st.lighting.exposure.luminance_min;
    lighting["luminance_max"] = st.lighting.exposure.luminance_max;
    lighting["volumetric_light_strength"] = st.lighting.volumetric_light_strength;
    lighting["shadow_tint"] = toColor(st.lighting.shadow_tint);
    lighting["bloom_intensity"] = st.lighting.bloom_intensity;
    lighting["bloom_strength_factor"] = st.lighting.bloom_strength_factor;
    lighting["bloom_radius"] = st.lighting.bloom_radius;
    d["lighting"] = lighting;
    // The ridge probe's latest answer (lodUpdateFar): the terrain horizon
    // toward the sun's azimuth. main.gd smooths it and derives the cloud
    // deck's own horizon from height and distance.
    Dictionary ridge;
    ridge["sin"] = m_ridge_sin;
    ridge["height"] = m_ridge_height;
    ridge["distance"] = m_ridge_dist;
    d["ridge"] = ridge;
    return d;
}

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
    while (it != m_lod_chains.end() && visited < budget) {
        ++visited;
        const v3s16 bp = it->first;
        const BlockLodChain *chain = it->second.get();
        ++it;
        const LodLevel *lv = chain->forCell(MAP_BLOCKSIZE);
        if (!lv || lv->cells.empty())
            continue;
        const LodLevel::Cell &c = lv->cells[0];
        if (!(c.flags & LodLevel::kFilled))
            continue;
        content_t content = c.face[0];
        uint8_t p2 = c.param2[0];
        if ((content == CONTENT_AIR || content == CONTENT_IGNORE) &&
                c.liquid != CONTENT_AIR) {
            content = c.liquid;
            p2 = c.liquid_param2;
        }
        if (content == CONTENT_AIR || content == CONTENT_IGNORE)
            continue;
        const int top_in = (c.top == 0 || c.top >= MAP_BLOCKSIZE) ? MAP_BLOCKSIZE : c.top;
        const int16_t top_y = (int16_t)(bp.Y * MAP_BLOCKSIZE + top_in - 1);
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

Dictionary GoannaClient::perf_worst_take() {
    Dictionary d;
    d["lod_worst_ms"] = m_ms_lod_worst;
    d["near_batch_worst_ms"] = m_ms_near_batch_worst;
    d["occluder_worst_ms"] = m_ms_occluder_worst;
    m_ms_lod_worst = 0.0;
    m_ms_near_batch_worst = 0.0;
    m_ms_occluder_worst = 0.0;
    return d;
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

Dictionary GoannaClient::step_player(double dt, const Dictionary &keys, float pitch_deg, float yaw_deg) {
    Dictionary out;
    if (!m_session)
        return out;
    LocalPlayer *p = m_session->player();
    if (!p)
        return out;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    // Mantling: Luanti's own autojump, which steps the player up a single
    // block ledge it walks into (with clear headroom) using an ordinary jump,
    // so the server sees nothing a vanilla client with autojump would not.
    // Goanna defaults it on because it plays better; the toggle turns it off
    // for strict vanilla parity.
    PlayerSettings &ps = p->getPlayerSettings();
    ps.autojump = m_mantle;
    ps.aux1_descends = m_aux1_descends;
    ps.pitch_move = m_pitch_move;
    ps.always_fly_fast = m_always_fly_fast;
    v3f spos;
    float spitch, syaw;
    if (m_session->takeServerMove(spos, spitch, syaw)) {
        p->setPosition(spos);
        p->setSpeed(v3f(0, 0, 0));
    }
    // Luanti: pitch positive = looking down; yaw matches Godot after z-mirror.
    PlayerControl &c = p->control;
    c.direction_keys = ((bool)keys.get("up", false) & 1) | (((bool)keys.get("down", false) & 1) << 1) |
            (((bool)keys.get("left", false) & 1) << 2) | (((bool)keys.get("right", false) & 1) << 3);
    // Autojump sets a flag on the player; the vanilla client feeds it back in
    // as a jump press on the next frame (game.cpp: isKeyDown(JUMP) ||
    // player->getAutojump()). Without this the flag was set and ignored.
    c.jump = (bool)keys.get("jump", false) || p->getAutojump();
    c.sneak = keys.get("sneak", false);
    c.aux1 = keys.get("aux1", false);
    c.pitch = -pitch_deg;
    c.yaw = yaw_deg;
    setViewAngles(pitch_deg, yaw_deg);
    // Upstream seeds these from the joystick each frame (0 with no stick), then
    // setMovementFromKeys() only overrides them while a direction key is held,
    // leaving them untouched otherwise. Goanna has no joystick and reuses the
    // persistent control, so without this reset the last movement_speed sticks
    // and the player keeps walking after the key is released.
    c.movement_speed = 0.0f;
    c.movement_direction = 0.0f;
    c.setMovementFromKeys();

    if (dt > 0.1) dt = 0.1;
    if (dt > 0)
        m_session->stepPlayer((float)dt);
    if (std::getenv("GOANNA_DEBUG_MANTLE")) {
        static int n = 0;
        if (dt > 0 && c.direction_keys != 0 && ++n % 20 == 0)
            fprintf(stderr, "mantle in: ground=%d speed=%.2f jump=%d aj=%d pos=%.1f,%.2f,%.1f\n",
                    (int)p->touching_ground, p->control.movement_speed,
                    (int)p->control.jump, (int)p->getAutojump(),
                    p->getPosition().X / BS, p->getPosition().Y / BS, p->getPosition().Z / BS);
    }
    if (std::getenv("GOANNA_DEBUG_MANTLE") && p->getAutojump())
        fprintf(stderr, "goanna mantle: autojump fired at y=%.2f\n", p->getPosition().Y / BS);

    v3f pos = p->getPosition();
    v3f eye = pos + p->getEyeOffset();
    // report to server (nodes) with real speed and input intent, so the
    // server's movement check does not reset us (which breaks item pickup)
    m_session->setPlayerPose(pos / BS, p->getPitch(), p->getYaw(), p->getSpeed() / BS,
            p->control.movement_speed, p->control.movement_direction);
    out["pos"] = Vector3(pos.X / BS, pos.Y / BS, -pos.Z / BS);
    out["eye_pos"] = Vector3(eye.X / BS, eye.Y / BS, -eye.Z / BS);
    out["pitch"] = -p->getPitch();
    out["yaw"] = p->getYaw();
    out["on_ground"] = p->touching_ground;
    out["in_liquid"] = p->in_liquid;
    v3f sp = p->getSpeed();
    out["speed"] = Vector3(sp.X / BS, sp.Y / BS, -sp.Z / BS);
    out["gravity"] = p->movement_gravity / BS;
    out["free_move"] = p->getPlayerSettings().free_move;
    out["climbing"] = p->is_climbing;
    return out;
}

Ref<Material> GoannaClient::materialForIrr(const video::SMaterial &m, u16 layer) {
    return materialFor(keyForIrr(m, layer));
}

MaterialKey GoannaClient::keyForIrr(const video::SMaterial &m, u16 layer) {
    MaterialKey key;
    GoannaTexture *gt = dynamic_cast<GoannaTexture *>(m.getTexture(0));
    key.texture_id = gt ? gt->id() : 0;
    // Mining crack: crack tiles carry crack_anylength.png at the crack layer
    // and their level in MaterialTypeParam (packed by MapBlockMesh::animate).
    // Composite the crack frame over the base through the texture-modifier
    // DSL; the distinct texture id keys a distinct cached material per level.
    if (gt && m.getTexture(MapBlockMesh::TEXTURE_LAYER_CRACK)) {
        auto pr = MapBlockMesh::unpackCrackMaterialParam(m.MaterialTypeParam);
        if (pr.first >= 0) {
            // [crack:<tiles>:<frame_count>:<progression>. frame_count is the
            // number of ANIMATION frames in the destination texture, not the
            // number of crack stages: the crack is scaled to one frame's
            // height and blitted into each. Passing the stage count squashed
            // the crack to a fraction of the node's height and repeated it,
            // which read as thin lines and made the early stages invisible.
            // Our per-level composite is a single-frame texture, so pass 1.
            std::string cracked = m_session->tsrc()->imageName(gt->id(), layer) +
                    "^[crack:" + std::to_string((int)pr.second) + ":1:" +
                    std::to_string(pr.first);
            if (getenv("GOANNA_DEBUG_CRACK"))
                UtilityFunctions::print("crack: level ", pr.first, "/",
                        m_session->crackAnimationLength(), " tiles ", (int)pr.second,
                        " -> ", String(cracked.c_str()));
            u32 cid = m_session->tsrc()->getTextureId(cracked);
            if (cid != 0) {
                key.texture_id = cid;
                key.composited = true; // already a real image; do not resolve again
            }
        }
    }
    key.shader_id = GoannaShaderSource::isShaderMaterial(m.MaterialType)
            ? GoannaShaderSource::shaderIdFromMaterial(m.MaterialType) : 0;
    key.backface_culling = m.BackfaceCulling;
    if (gt && gt->isArray()) {
        // The array path covers the common case: an opaque, culled tile with
        // no crack overlay. Anything else (a special shader, a double-sided
        // plant, a tile being dug) resolves back to its own single image, so
        // it is never sampled as if it were an array.
        bool cracked = m.getTexture(MapBlockMesh::TEXTURE_LAYER_CRACK) != nullptr;
        // Waving leaves are backface-culled (they are cube-shaped, unlike
        // waving plants), so the checks above do not rule them out, but
        // nodes_array.gdshader has no wind logic at all: routing them
        // through it silently drops the sway, which is how leaves ended up
        // rendering still. materialFor() below picks the special per-material
        // shader (leaves, plants, glass, water) whenever it is not an array,
        // so keep those material types off the array path here too.
        MaterialType mtype = m_session->shsrc().materialType(key.shader_id);
        bool wants_special_shader = mtype == TILE_MATERIAL_WAVING_LEAVES ||
                mtype == TILE_MATERIAL_WAVING_PLANTS ||
                mtype == TILE_MATERIAL_LIQUID_TRANSPARENT ||
                mtype == TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT ||
                mtype == TILE_MATERIAL_WAVING_LIQUID_BASIC ||
                ((mtype == TILE_MATERIAL_ALPHA || mtype == TILE_MATERIAL_PLAIN_ALPHA) &&
                        m.BackfaceCulling);
        // Only commit to the array path if the Godot array actually built:
        // otherwise the key would name a texture with no 2D image behind it
        // and the tile would render untextured white.
        bool array_ready = m.BackfaceCulling && !cracked && !wants_special_shader &&
                m_session->shsrc().usesArrayTexture(key.shader_id) &&
                gt->godotArray().is_valid();
        if (array_ready) {
            key.array_texture = true;
        } else if (!key.composited) {
            if (getenv("GOANNA_DEBUG_ARRAY") && m.BackfaceCulling && !cracked)
                UtilityFunctions::print("array fallback: id=", gt->id(),
                        " layers=", (int)gt->layerNames().size(),
                        " shader_array=", m_session->shsrc().usesArrayTexture(key.shader_id),
                        " built=", gt->godotArray().is_valid());
            // Must always land on a real 2D image: leaving the array id here
            // gives the special shaders (glass, leaves, water) a sampler2D
            // they cannot read, which renders as a smooth untextured pane.
            const auto &names = gt->layerNames();
            if (!names.empty()) {
                size_t idx = layer < names.size() ? layer : 0;
                key.texture_id = m_session->tsrc()->getTextureId(names[idx]);
            }
        }
    }
    if (getenv("GOANNA_DEBUG_CRACK") && m.getTexture(MapBlockMesh::TEXTURE_LAYER_CRACK)) {
        // the FINAL texture this material will use, after every fallback
        UtilityFunctions::print("crack final: ",
                String(m_session->tsrc()->getTextureName(key.texture_id).c_str()),
                " array=", key.array_texture);
    }
    return key;
}

// Nodes that use a liquid drawtype without being a liquid.
//
// Mineclonia's ice is the case that matters: drawtype liquid, so that it tiles
// seamlessly with itself the way water does, but liquid_type LIQUID_NONE
// because it is a solid block you walk on. Luanti's tile generation only looks
// at the drawtype, so the tile arrives as TILE_MATERIAL_LIQUID_TRANSPARENT and
// materialFor hands it to the water shader.
//
// Drawn as water it looks like water: the shader reads the depth buffer to
// work out how thick the column in front of it is, so a sheet of ice renders
// pale where something sits close behind it and dark where the water below is
// deep. That is the patchwork of dark rectangles on a frozen ocean, and why it
// changes as the view does, and why only water with ice over it is affected.
// The node is never wrong, only its material.
//
// ContentFeatures has both halves of the answer already, so collect the tile
// textures of every node that draws as a liquid and is not one, and keep them
// off the water shader.
void GoannaClient::buildFakeLiquidTextures() {
    if (m_fake_liquid_built || !m_session)
        return;
    const NodeDefManager *ndef = m_session->nodeDefs();
    if (!ndef)
        return;
    m_fake_liquid_built = true;
    // NodeDefManager exposes no count, but get() is bounds safe and returns
    // the unknown feature past the end, so walk the whole content_t range once.
    for (u32 c = 0; c <= 0xffff; ++c) {
        const ContentFeatures &f = ndef->get((content_t)c);
        if (f.name.empty() || f.name == "unknown")
            continue;
        if (f.drawtype != NDT_LIQUID && f.drawtype != NDT_FLOWINGLIQUID)
            continue;
        if (f.liquid_type != LIQUID_NONE)
            continue;
        for (const auto &tdef : f.tiledef) {
            if (tdef.name.empty())
                continue;
            u32 id = m_session->tsrc()->getTextureId(tdef.name);
            if (id)
                m_fake_liquid_tex.insert(id);
        }
    }
    if (getenv("GOANNA_DEBUG_WHITE"))
        UtilityFunctions::print("fake liquids: ", (int)m_fake_liquid_tex.size(),
                " textures drawn as liquid that are not one");
}

Ref<Material> GoannaClient::materialFor(const MaterialKey &key) {
    auto it = m_materials.find(key.hash());
    if (it != m_materials.end())
        return it->second;
    if (!m_shaders_loaded) {
        m_shaders_loaded = true;
        ResourceLoader *rl = ResourceLoader::get_singleton();
        m_sh_water = rl->load("res://shaders/water.gdshader");
        m_sh_leaves = rl->load("res://shaders/waving_leaves.gdshader");
        m_sh_plants = rl->load("res://shaders/waving_plants.gdshader");
        m_sh_glass = rl->load("res://shaders/glass.gdshader");
        m_sh_array = rl->load("res://shaders/nodes_array.gdshader");
        m_sh_array_scissor = rl->load("res://shaders/nodes_array_scissor.gdshader");
    }
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(key.texture_id);
    Ref<ImageTexture> tex = gt ? gt->godotTexture() : Ref<ImageTexture>();
    MaterialType mtype = m_session->shsrc().materialType(key.shader_id);
    video::E_MATERIAL_TYPE base = m_session->shsrc().baseMaterial(key.shader_id);
    u8 emissive = m_session->emissiveLevel(key.texture_id);
    // Dim sources (firefly bush, light_source 2) should light their
    // surroundings, not render as a glowing material; only strong sources
    // (torches, glowstone) get emission. The point-light pool covers dim ones.
    if (emissive < 6)
        emissive = 0;
    if (getenv("GOANNA_DEBUG_WHITE") && !tex.is_valid())
        UtilityFunctions::print("no-tex material: id=", key.texture_id, " '",
                String(m_session->tsrc()->getTextureName(key.texture_id).c_str()),
                "' mtype=", (int)mtype, " shader=", key.shader_id);
    if (getenv("GOANNA_DEBUG_MATERIALS")) {
        UtilityFunctions::print("goanna material: tex=", key.texture_id, " '",
                String(m_session->tsrc()->getTextureName(key.texture_id).c_str()),
                "' shader=", key.shader_id, " mtype=", (int)mtype, " base=", (int)base,
                " emissive=", (int)emissive, " cull=", key.backface_culling);
    }

    // --- array texture: one material for a whole bunch of tiles ---
    if (key.array_texture) {
        GoannaTexture *agt = m_session->tsrc()->goannaTexture(key.texture_id);
        Ref<Texture2DArray> arr = agt ? agt->godotArray() : Ref<Texture2DArray>();
        if (arr.is_valid()) {
            Ref<ShaderMaterial> sm;
            sm.instantiate();
            // Two shaders, not one with a scissor toggle: godotengine/godot#60388,
            // see nodes_array.gdshader.
            sm->set_shader(agt->hasAlpha() ? m_sh_array_scissor : m_sh_array);
            sm->set_shader_parameter("albedo_array", arr);
            // Authored PBR from the server's own media, if a pack ships it:
            // this is what a resource pack buys over inferring relief from
            // the diffuse texture, and it needs no protocol change at all.
            // GOANNA_NO_NORMAL=1 binds everything else and drops only the
            // normal array, so a fixed camera A/B separates what the normal
            // map contributes from what swapping the albedo contributes. The
            // two are easy to confuse: a pack changes both at once, and the
            // albedo is much the louder of them.
			const char *no_pbr_env = getenv("GOANNA_NO_PBR");
			const bool pbr_disabled = no_pbr_env && *no_pbr_env;
            Ref<Texture2DArray> nrm = (pbr_disabled || getenv("GOANNA_NO_NORMAL"))
                    ? Ref<Texture2DArray>()
                    : agt->godotArraySuffixed(*m_session->tsrc(), "_n");
            Ref<Texture2DArray> spc = pbr_disabled
                    ? Ref<Texture2DArray>()
                    : agt->godotArraySuffixed(*m_session->tsrc(), "_s");
            for (const auto &d : kMatStrengthDefaults)
                sm->set_shader_parameter(String(d.first.c_str()) + String("_strength"),
                        material_strength(String(d.first.c_str())));
            // Which material each layer is, so the shader can treat sand as
            // sand and planks as planks. The classifier keys on the base
            // image, and a generated layer is named by its whole tile string,
            // modifiers and all, the same normalisation goanna_textures.cpp
            // uses when it fills a missing _s.
            {
                const MaterialTable &mtable = m_session->materialTable();
                const auto &lnames = agt->layerNames();
                PackedInt32Array classes;
                PackedFloat32Array coarse;
                classes.resize((int)lnames.size());
                coarse.resize((int)lnames.size());
                for (size_t i = 0; i < lnames.size(); ++i) {
                    std::string plain = tileBaseName(lnames[i]);
                    if (plain.empty())
                        plain = lnames[i];
                    classes[(int)i] = (int)mtable.textureClass(plain);
                    coarse[(int)i] = m_session->tsrc()->textureCoarseness(lnames[i]);
                }
                sm->set_shader_parameter("layer_class", classes);
                sm->set_shader_parameter("layer_coarse", coarse);
                if (getenv("GOANNA_DEBUG_PBR")) {
                    int n = (int)std::min<size_t>(lnames.size(), 4);
                    for (int i = 0; i < n; ++i)
                        UtilityFunctions::print("layer_class ", String(lnames[i].c_str()),
                                " base='", String(tileBaseName(lnames[i]).c_str()),
                                "' cls=", classes[i], " coarse=", coarse[i]);
                }
            }
            // Worked out from how flat this pack's authored maps measured
            // when the array was built, so a flat pack is lifted and a good
            // one is left alone. 1.0 when there is nothing to correct.
            sm->set_shader_parameter("pack_normal_gain",
                    nrm.is_valid() ? agt->normalGain() : 1.0f);
            sm->set_shader_parameter("has_normal", nrm.is_valid());
            sm->set_shader_parameter("has_spec", spc.is_valid());
            if (nrm.is_valid())
                sm->set_shader_parameter("normal_array", nrm);
            if (spc.is_valid())
                sm->set_shader_parameter("spec_array", spc);
            // The far tiers are past the reach of the node light pool, so
            // their block light is added as emission, which the near mesh
            // must not do or a torch counts twice. They also alias at range
            // (docs/far-rendering.md, "Shade the far field as a far field"),
            // so each layer's own average colour rides along for the shader
            // to blend toward with distance; the near mesh never draws far
            // enough to need it and leaves lod_flatten false.
            if (key.lod) {
                sm->set_shader_parameter("block_light_emission", 1.0f);
                sm->set_shader_parameter("lod_flatten", true);
                PackedVector3Array avg;
                const auto &names = agt->layerNames();
                avg.resize((int)names.size());
                for (size_t i = 0; i < names.size(); ++i) {
                    // The average is taken over the sRGB bytes of the
                    // texture; the shader blends it into ALBEDO, which is
                    // linear (the array is sampled as source_color). Handed
                    // over unconverted it read brighter and paler than the
                    // same tile near, which is the far band changing colour
                    // with distance (docs/launch-target.md, R1).
                    const Color c = toColor(m_session->tsrc()->getTextureAverageColor(names[i])).srgb_to_linear();
                    avg[(int)i] = Vector3(c.r, c.g, c.b);
                }
                sm->set_shader_parameter("lod_avg_colour", avg);
                // How much of each tile the near mesh's alpha test actually
                // keeps. A far tier draws a leaf cell as a solid box, so
                // without this a canopy at range is 18 to 36 per cent more
                // leaf than the same canopy up close, which reads as the
                // trees changing colour as they cross into the far field.
                PackedFloat32Array cover;
                cover.resize((int)names.size());
                for (size_t i = 0; i < names.size(); ++i)
                    cover[(int)i] = m_session->tsrc()->textureCoverage(names[i]);
                sm->set_shader_parameter("lod_coverage", cover);
                // The mean material response of each tile, so a far surface
                // converges to the average of what the near renderer would
                // show rather than to a fixed matte constant. Falls back to
                // the no-companion defaults when the _s array is absent.
                const auto &means = agt->layerSpecMeans();
                PackedFloat32Array rough, metal, spec;
                rough.resize((int)names.size());
                metal.resize((int)names.size());
                spec.resize((int)names.size());
                for (size_t i = 0; i < names.size(); ++i) {
                    const bool have = i < means.size();
                    rough[(int)i] = have ? means[i].rough : 1.0f;
                    metal[(int)i] = have ? means[i].metal : 0.0f;
                    spec[(int)i] = have ? means[i].spec : 0.2f;
                }
                sm->set_shader_parameter("lod_avg_rough", rough);
                sm->set_shader_parameter("lod_avg_metal", metal);
                sm->set_shader_parameter("lod_avg_spec", spec);
                // What the relief is worth, so flattening it can hand its
                // roughness back rather than leaving a flat shiny surface.
                const auto &nvar = agt->layerNormalVariance();
                PackedFloat32Array nv;
                nv.resize((int)names.size());
                for (size_t i = 0; i < names.size(); ++i)
                    nv[(int)i] = i < nvar.size() ? nvar[i] : 0.0f;
                sm->set_shader_parameter("lod_normal_variance", nv);
            }
            if (getenv("GOANNA_DEBUG_PBR"))
                UtilityFunctions::print("pbr array id=", key.texture_id,
                        " normal=", nrm.is_valid(), " spec=", spc.is_valid());
            m_materials[key.hash()] = sm;
            return sm;
        }
    }

    // --- shader variants by Luanti material type ---
    Ref<Shader> sh;
    switch (mtype) {
    case TILE_MATERIAL_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_BASIC:
        // ice and its like draw as liquids without being one; see
        // buildFakeLiquidTextures. They are alpha blended solid blocks, which
        // is what glass.gdshader is for and what its own header has always
        // said it was for; the drawtype is the only reason they never reached
        // it. Refraction and a low roughness are most of what separates ice
        // from a sheet of tinted water. GOANNA_SOLID_ICE wants the plain
        // opaque material instead, so leave that path alone.
        buildFakeLiquidTextures();
        if (!m_fake_liquid_tex.count(key.texture_id))
            sh = m_sh_water;
        else if (!m_solid_ice)
            sh = m_sh_glass;
        break;
    case TILE_MATERIAL_WAVING_LEAVES:
        sh = m_sh_leaves; break;
    case TILE_MATERIAL_WAVING_PLANTS:
        sh = m_sh_plants; break;
    case TILE_MATERIAL_ALPHA:
    case TILE_MATERIAL_PLAIN_ALPHA:
        // Refraction glass is only right for solid, backface-culled nodes
        // (glass, ice, stained glass). Double-sided alpha-blend tiles are
        // plants, leaves and the like: the glass shader's screen mix and
        // specular make them read white, so they take the standard path.
        if (key.backface_culling)
            sh = m_sh_glass;
        break;
    default:
        break;
    }
    if (getenv("GOANNA_DEBUG_WHITE") && sh.is_valid())
        UtilityFunctions::print((sh == m_sh_glass ? "GLASS " : sh == m_sh_plants ? "PLANTS " : sh == m_sh_leaves ? "LEAVES " : "WATER "),
                "'", String(m_session->tsrc()->getTextureName(key.texture_id).c_str()), "' mtype=", (int)mtype,
                " cull=", key.backface_culling, " texvalid=", tex.is_valid());
    if (sh.is_valid() && tex.is_valid() && emissive == 0) {
        Ref<ShaderMaterial> sm;
        sm.instantiate();
        sm->set_shader(sh);
        sm->set_shader_parameter("albedo_tex", tex);
        bool waving = (mtype == TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT ||
                mtype == TILE_MATERIAL_WAVING_LIQUID_BASIC || mtype == TILE_MATERIAL_WAVING_LEAVES ||
                mtype == TILE_MATERIAL_WAVING_PLANTS);
        if (sh == m_sh_water || sh == m_sh_leaves || sh == m_sh_plants)
            sm->set_shader_parameter("waving", waving);
        // Water shades by distance, not by tier: the near mesh runs the same
        // flatten curve as its far tier material, so wherever the near mesh
        // ends the far tier continues the very same functions of distance
        // and the hand-off has nothing to draw a seam with.
        if (sh == m_sh_water)
            sm->set_shader_parameter("lod_flatten", true);
        // Glass, ice, leaves and plants take their LabPBR companions, looked
        // up by stem the way the entity path does (goanna_entities.cpp): the
        // _n is the authored relief, and the _s smoothness is what breaks a
        // frozen sheet's reflection into frost and slick instead of one
        // mirror. Foliage was left out of this until now, so a pack's maps
        // reached the ground and the walls and stopped at the treeline, and
        // every mat_ slider moved one and not the other.
        if (sh == m_sh_glass || sh == m_sh_leaves || sh == m_sh_plants) {
            std::string base = m_session->tsrc()->getTextureName(key.texture_id);
            base = base.substr(0, base.find('^'));
            const size_t dotpos = base.rfind('.');
            const std::string stem = dotpos == std::string::npos ? base : base.substr(0, dotpos);
            const std::string ext = dotpos == std::string::npos ? std::string() : base.substr(dotpos);
            auto lookup = [&](const char *suffix) -> Ref<Texture2D> {
                const std::string name = stem + suffix + ext;
                if (stem.empty() || !m_session->tsrc()->isKnownSourceImage(name))
                    return Ref<Texture2D>();
                GoannaTexture *cgt = dynamic_cast<GoannaTexture *>(m_session->tsrc()->getTexture(name));
                return cgt ? Ref<Texture2D>(cgt->godotTexture()) : Ref<Texture2D>();
            };
            Ref<Texture2D> nrm_tex;
            Ref<Texture2D> spc_tex;
			const char *no_pbr_env = getenv("GOANNA_NO_PBR");
			if (!no_pbr_env || !*no_pbr_env) {
                nrm_tex = lookup("_n");
                spc_tex = lookup("_s");
            }
            sm->set_shader_parameter("has_normal", nrm_tex.is_valid());
            sm->set_shader_parameter("has_spec", spc_tex.is_valid());
            if (nrm_tex.is_valid())
                sm->set_shader_parameter("normal_tex", nrm_tex);
            if (spc_tex.is_valid())
                sm->set_shader_parameter("spec_tex", spc_tex);
            // The settings panel's mat_ channels, so a slider reaches
            // foliage as well as terrain. Glass has its own fixed response
            // and is left alone.
            if (sh == m_sh_leaves || sh == m_sh_plants) {
                for (const char *ch : {"normal", "ao", "roughness", "specular",
                                       "sss", "emission"})
                    sm->set_shader_parameter(String(ch) + String("_strength"),
                            material_strength(String(ch)));
            }
        }
        m_materials[key.hash()] = sm;
        return sm;
    }

    // --- standard material ---
    Ref<StandardMaterial3D> mat;
    mat.instantiate();
    mat->set_roughness(1.0f);
    mat->set_metallic(0.0f);
    mat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat->set_texture_filter(BaseMaterial3D::TEXTURE_FILTER_NEAREST_WITH_MIPMAPS);
    mat->set_cull_mode(key.backface_culling ? BaseMaterial3D::CULL_BACK : BaseMaterial3D::CULL_DISABLED);
    if (tex.is_valid()) {
        mat->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, tex);
        if (base == video::EMT_TRANSPARENT_ALPHA_CHANNEL) {
            // GOANNA_SOLID_ICE=1: render a node drawn as a liquid that is not
            // one as opaque, rather than at the translucency its texture asks
            // for. Mineclonia's ice is a flat alpha of 186, so 27 per cent of
            // what is behind it shows through, and that 27 per cent costs a
            // great deal: two transparent surfaces in different mapblocks are
            // sorted by object centre, so a large ice mesh can sort in front
            // of a waterfall it is behind, and flip as the camera moves. Going
            // opaque puts it in the opaque pass where depth resolves it per
            // pixel and no sorting is involved. It is a trade, not a fix: you
            // stop seeing the water under the ice.
            buildFakeLiquidTextures();
            if (m_solid_ice && m_fake_liquid_tex.count(key.texture_id)) {
                // leave the material opaque
            } else {
                mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
                mat->set_depth_draw_mode(BaseMaterial3D::DEPTH_DRAW_ALWAYS);
            }
        } else if (base == video::EMT_TRANSPARENT_ALPHA_CHANNEL_REF || (gt && gt->hasAlpha())) {
            mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR);
            mat->set_alpha_scissor_threshold(0.5f);
        }
        // Auto-bump: a normal map derived from the diffuse luminance. Skip
        // fully alpha-blended tiles (their transparency is not surface relief)
        // and emissive tiles.
        if (m_auto_bump > 0.0f && gt && base != video::EMT_TRANSPARENT_ALPHA_CHANNEL) {
            Ref<Texture2D> nrm = gt->godotNormal(m_auto_bump);
            if (nrm.is_valid()) {
                mat->set_feature(BaseMaterial3D::FEATURE_NORMAL_MAPPING, true);
                mat->set_texture(BaseMaterial3D::TEXTURE_NORMAL, nrm);
                mat->set_normal_scale(1.0f);
            }
        }
        if (mtype == TILE_MATERIAL_LIQUID_OPAQUE || mtype == TILE_MATERIAL_WAVING_LIQUID_OPAQUE)
            mat->set_roughness(0.35f); // lava-like
        if (emissive > 0) {
            // light-emitting node: glow with the bright part of its own
            // texture, not the whole tile (a torch's handle is not the
            // flame). SDFGI picks this up. Quadratic in the light level, so
            // a dim source (firefly bush, light_source 2) barely glows
            // instead of rendering as a white fullbright plant, while
            // torches and glowstone stay bright.
            //
            // EMISSION_OP_ADD is the BaseMaterial3D default, and it adds the
            // flat emission colour to the emission texture rather than
            // tinting it: emission white plus a mask that is black outside
            // the flame still adds white everywhere, which is a full bright
            // node-shaped block regardless of what the texture says. Multiply
            // instead, so a masked-out texel (0, 0, 0) actually stays dark.
            float lvl = emissive / 14.0f;
            mat->set_feature(BaseMaterial3D::FEATURE_EMISSION, true);
            mat->set_emission_operator(BaseMaterial3D::EMISSION_OP_MULTIPLY);
            Ref<ImageTexture> glow = gt ? gt->godotEmissionMask() : Ref<ImageTexture>();
            mat->set_texture(BaseMaterial3D::TEXTURE_EMISSION, glow.is_valid() ? glow : tex);
            mat->set_emission(Color(1, 1, 1));
            mat->set_emission_energy_multiplier(1.8f * lvl * lvl);
        }
    } else {
        mat->set_albedo(Color(0.9, 0.4, 0.9));
    }
    m_materials[key.hash()] = mat;
    return mat;
}

void GoannaClient::harvestLights(v3s16 bp, MapBlock *block) {
    std::vector<NodeLight> lights;
    const NodeDefManager *ndef = m_session->nodeDefs();
    for (int z = 0; z < MAP_BLOCKSIZE; ++z)
    for (int y = 0; y < MAP_BLOCKSIZE; ++y)
    for (int x = 0; x < MAP_BLOCKSIZE; ++x) {
        MapNode n = block->getNodeNoCheck(x, y, z);
        const ContentFeatures &f = ndef->get(n);
        if (f.light_source < 2)
            continue;
        NodeLight l;
        l.pos = Vector3(bp.X * MAP_BLOCKSIZE + x, bp.Y * MAP_BLOCKSIZE + y, -(bp.Z * MAP_BLOCKSIZE + z));
        // A light at the node centre sits inside its own mesh (a lantern's
        // cage, a glowing cube), so the moment its shadow map turns on it
        // occludes itself and appears to switch off. Nudge it into the first
        // open neighbour: below first (hanging lanterns), then above (floor
        // lamps), then the sides. If everything is solid it is genuinely
        // enclosed and staying dark is correct.
        {
            static const v3s16 nudge_dirs[6] = {
                {0, -1, 0}, {0, 1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}};
            v3s16 npos(bp.X * MAP_BLOCKSIZE + x, bp.Y * MAP_BLOCKSIZE + y, bp.Z * MAP_BLOCKSIZE + z);
            for (const v3s16 &d : nudge_dirs) {
                MapNode nb = m_session->map().getNode(npos + d);
                if (nb.getContent() == CONTENT_IGNORE)
                    continue;
                if (ndef->get(nb).visuals->solidness != 2) {
                    l.pos += Vector3(d.X, d.Y, -d.Z) * 0.6f;
                    break;
                }
            }
        }
        l.level = f.light_source / 14.0f;
        // colour from the node's first tile (torch textures average to warm orange)
        video::SColor c(255, 255, 220, 160);
        if (f.visuals && f.visuals->tiles[0].layers[0].texture_id) {
            const TileLayer &tl = f.visuals->tiles[0].layers[0];
            std::string tname = m_session->tsrc()->imageName(tl.texture_id, tl.texture_layer_idx);
            if (!tname.empty())
                c = m_session->tsrc()->getTextureAverageColor(tname);
        }
        // brighten: an average of a mostly-dark torch texture is dim
        Color col(c.getRed() / 255.0f, c.getGreen() / 255.0f, c.getBlue() / 255.0f);
        float m = std::max(col.r, std::max(col.g, col.b));
        if (m > 0.05f) col = col / m;
        l.color = col.lerp(Color(1, 0.85, 0.6), 0.3f);
        l.color.a = 1.0f;
        if (getenv("GOANNA_DEBUG_LIGHTS"))
            UtilityFunctions::print("goanna light: ", String(f.name.c_str()), " at ", l.pos,
                    " level ", (int)f.light_source, " colour ", l.color);
        lights.push_back(l);
    }
    if (lights.empty())
        m_block_lights.erase(bp);
    else
        m_block_lights[bp] = std::move(lights);
}

void GoannaClient::sync_entities(double dt) {
    if (!m_session)
        return;
    auto t0 = clock_t_::now();
    if (!m_entities) {
        m_entities = std::make_unique<EntityRenderer>(this);
        m_entities->setShowBody(m_show_body);
        m_entities->setAutoBump(m_auto_bump);
    }
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    if (dt > 0.1) dt = 0.1;
    m_session->stepObjects((float)dt);
    m_entities->sync(*m_session, (float)dt, Vector3());
    ema(m_ms_entities, ms_since(t0));
}

void GoannaClient::set_arm_swing(float s) {
    m_arm_swing = std::clamp(s, 0.0f, 1.0f);
    if (m_entities)
        m_entities->setArmSwing(m_arm_swing);
}

void GoannaClient::set_show_body(bool show) {
    m_show_body = show;
    if (m_entities)
        m_entities->setShowBody(show);
}

static ItemStack goanna_wielded_item(GoannaSession *session) {
    Inventory *inv = session->inventory();
    if (!inv)
        return ItemStack();
    InventoryList *main_list = inv->getList("main");
    u16 idx = session->wieldIndex();
    if (!main_list || idx >= main_list->getSize())
        return ItemStack();
    return main_list->getItem(idx);
}

String GoannaClient::wield_item_name() {
    if (!m_session)
        return String();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return String::utf8(goanna_wielded_item(m_session.get()).name.c_str());
}

Dictionary GoannaClient::wield_info() {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    if (!m_entities)
        m_entities = std::make_unique<EntityRenderer>(this);
    ItemStack item = goanna_wielded_item(m_session.get());
    d["name"] = String::utf8(item.name.c_str());
    v3f sc(1, 1, 1);
    Ref<ArrayMesh> mesh = m_entities->buildItemMesh(*m_session, item, true, &sc);
    d["mesh"] = mesh;
    d["scale"] = Vector3(sc.X, sc.Y, sc.Z);
    return d;
}

// The light the wielded item would cast placed as a node, decoded 0 to 255,
// or 0 for anything unlit. main.gd drives the head light with it, so a torch
// in the hand lights the way (docs/pbr-plan.md, "The macro scale"). Client
// side only: nothing is asked of the server and nothing shown that is not
// the player's own flame.
int GoannaClient::wield_light() {
    if (!m_session)
        return 0;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    ItemStack item = goanna_wielded_item(m_session.get());
    if (item.name.empty())
        return 0;
    const NodeDefManager *ndef = m_session->nodeDefs();
    content_t id = CONTENT_IGNORE;
    if (!ndef || !ndef->getId(item.name, id))
        return 0;
    const ContentFeatures &f = ndef->get(id);
    return f.light_source > 0 ? decode_light(f.light_source) : 0;
}

Dictionary GoannaClient::item_mesh(const String &item_name) {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    if (!m_entities)
        m_entities = std::make_unique<EntityRenderer>(this);
    ItemStack item(item_name.utf8().get_data(), 1, 0, m_session->getItemDefManager());
    d["name"] = item_name;
    v3f sc(1, 1, 1);
    Ref<ArrayMesh> mesh = m_entities->buildItemMesh(*m_session, item, false, &sc);
    d["mesh"] = mesh;
    d["scale"] = Vector3(sc.X, sc.Y, sc.Z);
    return d;
}

Dictionary GoannaClient::model_preview(const String &mesh_name, const PackedStringArray &textures,
        const Vector2 &frame_loop, float speed) {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    if (!m_entities)
        m_entities = std::make_unique<EntityRenderer>(this);
    std::vector<std::string> texs;
    texs.reserve(textures.size());
    for (int i = 0; i < textures.size(); ++i)
        texs.push_back(textures[i].utf8().get_data());
    AABB box;
    Node3D *node = m_entities->buildModelPreview(*m_session, mesh_name.utf8().get_data(), texs,
            frame_loop.x, frame_loop.y, speed, &box);
    if (!node)
        return d;
    d["node"] = node;
    d["aabb"] = box;
    return d;
}

Dictionary GoannaClient::render_stats() {
    const auto t_stats = clock_t_::now();
    Dictionary d;
    d["stats_ms"] = m_ms_stats;
    d["mesh_ms"] = m_ms_mesh;
    d["upload_ms"] = m_ms_upload;
    d["lights_ms"] = m_ms_lights;
    d["motes_ms"] = m_ms_motes;
    d["entities_ms"] = m_ms_entities;
    d["blocks_meshed_last"] = m_last_meshed;
    d["blocks_queued"] = m_last_queue;
    d["block_meshes"] = (int)m_near_blocks.size();
    int near_surfaces = 0, near_regions = 0, near_source_surfaces = 0;
    int occluder_regions = 0, occluder_triangles = 0;
    for (const auto &kv : m_near_regions) {
        near_surfaces += kv.second.surfaces;
        if (kv.second.node || kv.second.glow_node)
            ++near_regions;
        if (kv.second.occluder_node) {
            ++occluder_regions;
            occluder_triangles += kv.second.occluder_triangles;
        }
    }
    for (const auto &kv : m_near_blocks) {
        near_source_surfaces += kv.second.source_surfaces;
        if (kv.second.special_node && kv.second.special_node->get_mesh().is_valid())
            near_surfaces += kv.second.special_node->get_mesh()->get_surface_count();
        if (kv.second.special_node)
            for (int ci = 0; ci < kv.second.special_node->get_child_count(); ++ci) {
                MeshInstance3D *child = Object::cast_to<MeshInstance3D>(
                        kv.second.special_node->get_child(ci));
                if (child && child->get_mesh().is_valid())
                    near_surfaces += child->get_mesh()->get_surface_count();
            }
    }
    d["near_surfaces"] = near_surfaces;
    d["near_source_surfaces"] = near_source_surfaces;
    d["near_regions"] = near_regions;
    d["occluder_regions"] = occluder_regions;
    d["occluder_triangles"] = occluder_triangles;
    d["occluder_swap_ms"] = m_ms_occluder_swap;
    d["occluder_swaps"] = (int64_t)m_occluder_swaps;
    d["near_batch_ms"] = m_ms_near_batch;
    d["near_regions_built_last"] = m_near_regions_built_last;
    d["entities"] = m_entities ? m_entities->count() : 0;
    d["materials"] = (int)m_materials.size();
    d["resident_blocks"] = m_session ? m_session->residentBlocks() : 0;
    d["light_pool"] = (int)m_light_pool.size();
    d["lights_in_range"] = m_lights_in_range;
    d["light_churn"] = m_light_churn;
    d["mote_pool"] = (int)m_mote_pool.size();
    // Far tiers: how many blocks each tier draws, how many region meshes,
    // and what the merge achieved. The per tier readout docs/far-rendering.md
    // asks for, so a tier cannot regress the draw call budget unnoticed.
    d["lod_ms"] = m_ms_lod;
    d["lod_update_ms"] = m_ms_lod_update;
    d["lod_tier_scan_ms"] = m_ms_lod_tier_scan;
    // Worst single costs since perf_worst_take last cleared them. These
    // were read-and-reset here at first, which made them blind: main.gd's
    // _apply_sky calls render_stats every frame, so a 1 Hz sampler only
    // ever saw the last frame's worst (found by the perf tester on its
    // first cell). render_stats now only reports; the sampler that wants
    // the window owns the reset through perf_worst_take.
    d["lod_worst_ms"] = m_ms_lod_worst;
    d["near_batch_worst_ms"] = m_ms_near_batch_worst;
    d["occluder_worst_ms"] = m_ms_occluder_worst;
    d["lod_summary_ms"] = m_ms_lod_summaries;
    d["lod_request_ms"] = m_ms_lod_requests;
    d["lod_far_scan_ms"] = m_ms_lod_far_scan;
    d["lod_chain_ms"] = m_ms_lod_chain;
    d["lod_chains_built_last"] = m_lod_chains_built_last;
    d["lod_retier_queue"] = m_lod_retier_pending ? 1 : 0;
    d["poll_max_ms"] = std::max(m_ms_poll_max, m_ms_poll_max_last);
    d["poll_lock_ms"] = m_ms_poll_lock;
    d["poll_queue_ms"] = m_ms_poll_queue;
    d["poll_blocks_ms"] = m_ms_poll_blocks;
    d["poll_near_ms"] = m_ms_poll_near;
    d["poll_lod_ms"] = m_ms_poll_lod;
    d["lod_regions_built_last"] = m_lod_last_built;
    // The mesh workers. A queue that only grows means capture is outrunning
    // the pool; `ready` growing means publication is the bottleneck, not
    // meshing, and the budget per poll is what to raise.
    const MeshPool::Stats mp = m_mesh_pool.stats();
    d["mesh_threads"] = mp.threads;
    d["mesh_queued"] = mp.queued;
    d["mesh_running"] = mp.running;
    d["mesh_ready"] = mp.ready;
    d["mesh_rejected"] = mp.rejected;
    d["mesh_q_coverage"] = mp.queued_stage[(int)MeshWorkStage::kCoverage];
    d["mesh_q_near"] = mp.queued_stage[(int)MeshWorkStage::kNear];
    d["mesh_q_structure"] = mp.queued_stage[(int)MeshWorkStage::kStructure];
    // The scheduler, not the queue. Depth says how much work there is; these
    // say whether it is being done in the right order. `sched_head` is the
    // effective distance of the job that runs next and `sched_nearest` the
    // nearest job anywhere in that same worker queue. They can differ because
    // a more urgent class legitimately wins; unlike the old far-only number,
    // both now describe the same set of near and far candidates.
    const goanna::ViewPriority vp = viewPriority();
    d["sched_head"] = mp.has_head ? goanna::ViewPriority::distanceOf(mp.head_priority) : 0;
    d["sched_head_class"] = mp.has_head
            ? goanna::ViewPriority::className(goanna::ViewPriority::classOf(mp.head_priority))
            : "idle";
    d["sched_nearest"] = mp.has_nearest
            ? goanna::ViewPriority::distanceOf(mp.nearest_priority) : 0;
    d["sched_stale"] = m_sched_stale;
    d["sched_oldest_ms"] = m_sched_oldest_ms;
    d["sched_boot"] = m_sched_pending[(int)goanna::ViewPriority::kBootstrap];
    d["sched_stale_band"] = m_sched_pending[(int)goanna::ViewPriority::kStale];
    d["sched_cover"] = m_sched_pending[(int)goanna::ViewPriority::kCoverage];
    d["sched_refine"] = m_sched_pending[(int)goanna::ViewPriority::kRefine];
    d["sched_maintain"] = m_sched_pending[(int)goanna::ViewPriority::kMaintain];
    // How far the cone has opened, which explains a queue that has started
    // filling in behind the player.
    d["sched_cone"] = vp.widen;
    int lod_building = 0;
    for (auto &kv : m_lod_regions)
        if (kv.second.building)
            ++lod_building;
    d["lod_building"] = lod_building;
    int lod_regions = 0, lod_faces = 0, lod_quads = 0, lod_surfaces = 0, lod_dirty = 0;
    int lod_partial = 0;
    for (auto &kv : m_lod_regions) {
        if (kv.second.node)
            ++lod_regions;
        lod_faces += kv.second.faces;
        lod_quads += kv.second.quads;
        lod_partial += kv.second.partial;
        lod_surfaces += kv.second.surfaces;
        if (kv.second.dirty)
            ++lod_dirty;
    }
    d["lod_regions"] = lod_regions;
    d["lod_regions_dirty"] = lod_dirty;
    d["lod_faces"] = lod_faces;
    d["lod_partial"] = lod_partial;
    d["lod_quads"] = lod_quads;
    d["lod_surfaces"] = lod_surfaces;
    d["lod_chains"] = (int)m_lod_chains.size();
    d["lod_chain_queue"] = (int)m_lod_chain_queue.size();
    // The handoff freeze bookkeeping, visible because a leak here is a
    // region that draws its old mesh forever (the stale-drawn HUD count):
    // regions currently frozen against rebuild, and the pending handoffs
    // that hold them.
    d["lod_frozen_regions"] = (int)m_lod_handoff_old_counts.size();
    d["lod_handoff_to_near"] = (int)m_lod_handoff_to_near.size();
    d["lod_handoff_far"] = (int)m_lod_handoff_far.size();
    d["far_blocks"] = (int)m_far_blocks.size();
    d["far_remote"] = (int)m_far_remote.size();
    d["far_grant"] = m_session ? m_session->farRenderingGrant() : 0;
    d["far_extent"] = m_far_extent;
    d["far_reach"] = m_far_reach;
    d["far_requests_inflight"] = m_far_inflight;
    int far_areas_complete = 0, far_areas_partial = 0, far_areas_empty = 0;
    for (const auto &kv : m_far_requested) {
        if (kv.second.complete)
            ++far_areas_complete;
        else if (kv.second.empty)
            ++far_areas_empty;
        else if (kv.second.answered)
            ++far_areas_partial;
    }
    d["far_areas_requested"] = (int)m_far_requested.size();
    d["far_areas_complete"] = far_areas_complete;
    d["far_areas_partial"] = far_areas_partial;
    d["far_areas_empty"] = far_areas_empty;
    d["far_ray_yield"] = m_far_ray_yield;
    if (m_session && m_session->store()) {
        d["store_blocks"] = (int64_t)m_session->store()->blocksKnown();
        d["store_mb"] = (double)m_session->store()->bytes() / (1024.0 * 1024.0);
    }
    Dictionary tiers;
    // The tier histogram is verbose diagnostics, not a HUD input. Building it
    // walked every retained summary whenever the overlay sampled statistics,
    // recreating part of the stationary scaling bug from outside update_lod.
    if (getenv("GOANNA_PERF")) {
        for (auto &kv : m_block_tier) {
            Variant cur = tiers.get(kv.second, 0);
            tiers[kv.second] = (int)cur + 1;
        }
    }
    d["lod_tiers"] = tiers;
    RenderingServer *rs = RenderingServer::get_singleton();
    // The engine queries below (get_rendering_info, the viewport counters,
    // the measured render times) can force a main-to-render-thread sync,
    // and the HUD calls render_stats every frame; the user's own HUD has
    // shown this stats block at 3.5 to 6.4 ms on a big world. They refresh
    // at most five times a second and the dictionary carries the cached
    // values between refreshes, which is plenty for a HUD and for a 1 Hz
    // benchmark sampler, and keeps the measurement from taxing the frame
    // it measures.
    const bool refresh_info = ms_since(m_render_info_at) > 200.0;
    if (rs && refresh_info) {
        m_render_info_at = clock_t_::now();
        // The TOTAL counters lump every pass in the frame together: depth
        // prepass, colour, all shadow cascades, the radiance cubemap. The
        // per pass viewport counters below are the ones to read for what
        // the camera actually drew, and the shadow pair beside them for
        // what the cascades cost; both vary with view direction, since the
        // cascades are fitted to the camera frustum. (A benchmark once read
        // identical TOTALs across three directions as culling being off;
        // the real cause was a camera set from a run snippet, which
        // main._process silently overwrites every frame.)
        m_render_info["draw_calls"] = (int)rs->get_rendering_info(RenderingServer::RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME);
        m_render_info["primitives"] = (int64_t)rs->get_rendering_info(RenderingServer::RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME);
        m_render_info["objects"] = (int)rs->get_rendering_info(RenderingServer::RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME);
        m_render_info["video_mem_mb"] = (double)rs->get_rendering_info(RenderingServer::RENDERING_INFO_VIDEO_MEM_USED) / (1024.0 * 1024.0);
        Viewport *viewport = get_viewport();
        if (viewport) {
            const RID rid = viewport->get_viewport_rid();
            m_render_info["vis_draw_calls"] = (int)rs->viewport_get_render_info(rid,
                    RenderingServer::VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
                    RenderingServer::VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME);
            m_render_info["vis_primitives"] = (int64_t)rs->viewport_get_render_info(rid,
                    RenderingServer::VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
                    RenderingServer::VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME);
            m_render_info["vis_objects"] = (int)rs->viewport_get_render_info(rid,
                    RenderingServer::VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
                    RenderingServer::VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME);
            m_render_info["shadow_draw_calls"] = (int)rs->viewport_get_render_info(rid,
                    RenderingServer::VIEWPORT_RENDER_INFO_TYPE_SHADOW,
                    RenderingServer::VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME);
            m_render_info["shadow_primitives"] = (int64_t)rs->viewport_get_render_info(rid,
                    RenderingServer::VIEWPORT_RENDER_INFO_TYPE_SHADOW,
                    RenderingServer::VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME);
            m_render_info["occlusion_enabled"] = viewport->is_using_occlusion_culling();
            m_render_info["render_cpu_setup_ms"] = rs->get_frame_setup_time_cpu();
            m_render_info["render_cpu_draw_ms"] = rs->viewport_get_measured_render_time_cpu(rid);
            m_render_info["render_gpu_ms"] = rs->viewport_get_measured_render_time_gpu(rid);
        }
    }
    d.merge(m_render_info, true);
    ema(m_ms_stats, ms_since(t_stats));
    return d;
}

Array GoannaClient::entity_list() {
    if (!m_session || !m_entities)
        return Array();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->list(*m_session);
}

void GoannaClient::update_lights(const Vector3 &around, int max_lights) {
    auto t0 = clock_t_::now();

    // A lamp's identity is where it is. Node aligned positions make the
    // rounding exact, so this key is stable for as long as the lamp exists and
    // survives the pool being rebuilt.
    auto key_of = [](const NodeLight *l) {
        return ((int64_t)llroundf(l->pos.x) * 73856093LL) ^
                ((int64_t)llroundf(l->pos.y) * 19349663LL) ^
                ((int64_t)llroundf(l->pos.z) * 83492791LL);
    };
    // Steeper than linear so a level-2 firefly bush is a soft glow while a
    // level-14 torch keeps its old brightness.
    auto range_of = [](float level) { return 3.0f + 11.0f * level; };
    auto energy_of = [](float level) { return 5.5f * std::pow(level, 1.6f); };

    struct Cand {
        const NodeLight *l;
        int64_t key;
        float score;
    };
    std::vector<Cand> all;
    for (auto &kv : m_block_lights)
        for (auto &l : kv.second) {
            // Rank by the distance to the lamp's lit region, not to the lamp.
            //
            // A lamp lights the geometry around itself, and that geometry is
            // visible from much further away than the lamp is "near". Ranking
            // by raw camera distance therefore leaves the lanterns on a house
            // fifty blocks off out of the pool entirely, and admits them only
            // once the player has walked close enough to outrank whatever is
            // underfoot. The house appearing to light up as you approach it is
            // that, not a texture or a shadow effect.
            //
            // Subtracting the range gives the distance to the nearest surface
            // the lamp can actually light, which is zero for anything the
            // player is standing inside and grows only once its lit region is
            // genuinely far away. A bright lantern therefore outranks a dim
            // firefly bush at the same distance, which is the right answer.
            // Not clamped at zero. Clamping ties every lamp whose lit region
            // reaches the camera at the same score, which in a lit room is most
            // of them, and the tie-break then decides by key, meaning
            // arbitrarily. Letting it go negative ranks by how far inside the
            // lamp's reach the camera is, so a lamp overhead beats one across
            // the room instead of drawing with it.
            float score = l.pos.distance_to(around) - range_of(l.level);
            if (score < 64.0f)
                all.push_back({ &l, key_of(&l), score });
        }
    m_lights_in_range = (int)all.size();
    m_light_churn = 0;

    // Break ties on the key. A symmetrical build gives you equally ranked
    // lamps constantly, and without a tie-break their order comes from however
    // the block map happened to iterate, so they can swap between frames with
    // nothing having moved.
    std::sort(all.begin(), all.end(), [](const Cand &a, const Cand &b) {
        return a.score != b.score ? a.score < b.score : a.key < b.key;
    });

    while ((int)m_light_pool.size() < max_lights) {
        OmniLight3D *ol = memnew(OmniLight3D);
        ol->set_shadow(false);
        ol->set_visible(false);
        // Keep node lights out of global illumination. Godot's default for a
        // light is BAKE_DYNAMIC, meaning it feeds SDFGI, and SDFGI re-converges
        // over several frames whenever its lighting changes. This pool follows
        // the camera, so walking past a torch perturbed GI continuously and the
        // world visibly settled behind the player. Measured on the light_pool
        // fixture: a step differed from its own settled frame by 11.34 at frame
        // 0, decaying over four frames, and that transient disappeared if
        // either SDFGI or these lights' shadows were turned off, which is what
        // identified the pair as the cause rather than either alone.
        //
        // Torchlight is a small, local, moving contribution that GI was not
        // selling anyway; the sun and sky still light the scene through SDFGI.
        ol->set_bake_mode(Light3D::BAKE_DISABLED);
        ol->set_shadow_caster_mask(0xFFFFFFFFu & ~GLOW_LAYER);
        add_child(ol);
        m_light_pool.push_back(ol);
        m_light_slot.push_back(LightSlot());
    }
    // Shrink as well as grow: the pool size is a setting, and a lowered one
    // that left its slots behind would keep lighting the scene from them.
    while ((int)m_light_pool.size() > std::max(0, max_lights)) {
        OmniLight3D *ol = m_light_pool.back();
        m_light_pool.pop_back();
        m_light_slot.pop_back();
        ol->queue_free();
    }
    const size_t slots = m_light_pool.size();

    // Admission and eviction deliberately use different thresholds.
    //
    // Where there are more lamps in range than slots the set is saturated, and
    // every step changes the rank of every lamp. Taking the best max_lights
    // each frame therefore switches lamps on and off continuously. So a lamp
    // must reach max_lights to be given a slot, but keeps it until it falls
    // past keep_limit.
    const size_t admit_limit = std::min(all.size(), (size_t)std::max(0, max_lights));
    const size_t keep_limit = std::min(all.size(), (size_t)std::max(0, max_lights) * 3 / 2);

    // Where the pooled lights end, for the node shaders. A distant village
    // used to pass through three states: far tiers bake block light as
    // emission (lit), the near mesh relies on the light pool (dark, because
    // its lamps did not make the pool), then close up the pool admits them
    // (lit again). The shaders fade the same baked emission in past this
    // distance, so the middle state is lit by the bake the far field would
    // have used. The score is the camera's distance to a lamp's lit region,
    // which is what a surface's view distance approximates; unsaturated
    // pools light everything they consider, so only the 64-node candidate
    // window bounds it then.
    float unlit_from = 64.0f;
    if (all.size() > admit_limit)
        unlit_from = std::min(unlit_from, std::max(0.0f, all[admit_limit].score));
    RenderingServer::get_singleton()->global_shader_parameter_set(
            "goanna_lamp_reach", unlit_from);

    std::map<int64_t, size_t> rank_of;
    for (size_t i = 0; i < all.size(); ++i)
        rank_of.emplace(all[i].key, i);

    // Carry slot ownership over. A lamp keeps the same OmniLight3D as long as
    // it is still in the retain window, so its shadow map is not rebuilt and
    // its identity does not migrate across the pool.
    std::vector<const Cand *> holder(slots, nullptr);
    std::set<int64_t> held;
    // GOANNA_LIGHT_RANK=1 restores the old behaviour: slot i is simply the i-th
    // best lamp, reassigned every frame, with no retained identity, no retain
    // window and no fade. This is what the stable path is measured against.
    static const bool rank_pool = getenv("GOANNA_LIGHT_RANK") != nullptr;
    if (rank_pool) {
        for (size_t s = 0; s < slots && s < admit_limit; ++s) {
            holder[s] = &all[s];
            held.insert(all[s].key);
        }
    } else {
        for (size_t s = 0; s < slots; ++s) {
            if (!m_light_slot[s].key)
                continue;
            auto it = rank_of.find(m_light_slot[s].key);
            if (it == rank_of.end() || it->second >= keep_limit)
                continue;
            holder[s] = &all[it->second];
            held.insert(it->first);
        }
        // Then fill whatever is free from the best lamps that do not have a
        // slot. A slot still fading out is not free: taking it would swap one
        // lamp for another mid-fade, which is the step the fade exists to
        // avoid.
        size_t next = 0;
        for (size_t s = 0; s < slots; ++s) {
            if (holder[s] || m_light_slot[s].fade > 0.0f)
                continue;
            while (next < admit_limit && held.count(all[next].key))
                ++next;
            if (next >= admit_limit)
                break;
            holder[s] = &all[next];
            held.insert(all[next].key);
            ++next;
        }
        // Neither pass above ever displaces a holder that is merely inside
        // keep_limit: retaining looks at the holder's own rank alone, and
        // filling only ever touches an already free slot. So a lamp that is
        // the single best candidate in the world, freshly placed, can sit
        // outside the pool indefinitely if every slot happens to already
        // hold something still under keep_limit, which a torch placed
        // anywhere already reasonably lit does. That is the gap between "is
        // ranked within admit_limit" and "is given a slot" the comment above
        // promises does not exist. Close it: evict the worst-ranked holder
        // (never one mid fade-out) for each top-admit_limit lamp still
        // without a slot.
        for (size_t i = 0; i < admit_limit; ++i) {
            if (held.count(all[i].key))
                continue;
            size_t victim = slots, worst_rank = 0;
            for (size_t s = 0; s < slots; ++s) {
                // A held slot's fade only ever ramps up (the render loop
                // below counts it down only once holder[s] goes null), so
                // there is no fade-out to interrupt here: unlike the free
                // slot search above, excluding fade > 0 would exclude every
                // stable, fully lit lamp, which is every eviction target
                // there is.
                if (!holder[s])
                    continue;
                auto it = rank_of.find(holder[s]->key);
                const size_t r = it != rank_of.end() ? it->second : all.size();
                if (victim == slots || r > worst_rank) {
                    worst_rank = r;
                    victim = s;
                }
            }
            if (victim == slots)
                break; // nothing evictable: every slot is free
            // Only trade up. The worst holder can still rank better than
            // this candidate, and candidates only get worse from here, so
            // stop rather than swap a brighter lamp for a dimmer one.
            if (worst_rank <= i)
                break;
            held.erase(holder[victim]->key);
            holder[victim] = &all[i];
            held.insert(all[i].key);
        }
    }

    // Which of those cast shadows, decided with its own hysteresis.
    //
    // Only the nearest few can: an omni shadow is a cube map and costs six
    // depth passes. Choosing them by rank every frame, with no memory, means
    // two lamps either side of the boundary swap shadow casting the moment
    // their order flips, which a step or two does.
    //
    // The budget matters more than it looks. A lantern is a solid node, so it
    // occludes its own light upward: with a shadow map the eave directly above
    // it is dark, and without one the light passes through the lantern block
    // and the eave glows. A lamp crossing the budget therefore does not merely
    // lose a shadow, it starts lighting surfaces it should not reach at all.
    const size_t SHADOW_COUNT = (size_t)std::max(0, m_shadow_lamps);
    // GOANNA_SHADOW_KEEP: the rank a shadow caster may fall to before losing
    // its shadow. Setting it equal to SHADOW_COUNT removes the hysteresis and
    // restores rank-per-frame behaviour, which is how this was measured.
    const size_t KEEP_RANK = getenv("GOANNA_SHADOW_KEEP")
            ? (size_t)atoi(getenv("GOANNA_SHADOW_KEEP")) : SHADOW_COUNT * 7 / 4;
    std::set<int64_t> next_shadowed;
    size_t rank = 0;
    for (size_t i = 0; i < all.size() && next_shadowed.size() < SHADOW_COUNT; ++i) {
        if (!held.count(all[i].key))
            continue;
        if (rank < KEEP_RANK && m_light_shadowed.count(all[i].key))
            next_shadowed.insert(all[i].key);
        ++rank;
    }
    for (size_t i = 0; i < all.size() && next_shadowed.size() < SHADOW_COUNT; ++i)
        if (held.count(all[i].key))
            next_shadowed.insert(all[i].key);
    m_light_shadowed.swap(next_shadowed);

    // GOANNA_NO_LIGHT_SHADOWS=1 keeps the lights but takes their shadows away,
    // so "is it the lights" and "is it their shadow maps" stay separable.
    static const bool no_light_shadows = getenv("GOANNA_NO_LIGHT_SHADOWS") != nullptr;
    // Admission and eviction ramp rather than step. Even a perfectly stable
    // pool has to drop a lamp eventually, and a lamp that vanishes between one
    // frame and the next is visible as a jump in the lighting of everything it
    // touched. About seven frames is short enough to look immediate and long
    // enough not to read as a switch.
    const float FADE_STEP = rank_pool ? 1.0f : 0.15f;

    // Wall clock, not dtime: update_lights() is called with the camera
    // position only (see the header), and a phase that free-runs off real
    // time keeps flickering even the frames a lamp's own admission or
    // ranking does not otherwise touch.
    const float flicker_t = (float)std::chrono::duration<double>(
            clock_t_::now().time_since_epoch()).count();

    for (size_t s = 0; s < slots; ++s) {
        OmniLight3D *ol = m_light_pool[s];
        LightSlot &slot = m_light_slot[s];
        const Cand *c = holder[s];
        if (c) {
            if (slot.key != c->key) {
                ++m_light_churn;
                slot.key = c->key;
                slot.fade = 0.0f;
                // A stable pseudo-random phase from the key, not the pool
                // slot: two lamps swapping slots must not swap flicker too,
                // or the swap reads as the flame itself jumping.
                slot.flicker_phase = (float)((uint64_t)c->key % 1000003u) *
                        (6.2831853f / 1000003.0f);
            }
            slot.pos = c->l->pos;
            slot.color = c->l->color;
            slot.level = c->l->level;
            slot.fade = std::min(1.0f, slot.fade + FADE_STEP);
        } else if (slot.key) {
            slot.fade -= FADE_STEP;
            if (slot.fade <= 0.0f) {
                slot.fade = 0.0f;
                slot.key = 0;
                ++m_light_churn;
                ol->set_visible(false);
                if (ol->has_shadow())
                    ol->set_shadow(false);
                continue;
            }
        } else {
            continue;
        }

        // A living flame, not a strobe: three sine waves at incommensurate
        // frequencies so the sum never repeats on a beat a player can catch,
        // each lamp's own phase keeping a room from pulsing in lockstep. The
        // amplitudes sum to a touch over a tenth of the lamp's energy either
        // way, which reads as restless rather than as motion.
        float flicker = 1.0f;
        if (m_light_flicker) {
            const float p = slot.flicker_phase;
            flicker = 1.0f + 0.04f * std::sin(flicker_t * 3.7f + p)
                            + 0.02f * std::sin(flicker_t * 9.1f + p * 2.3f)
                            + 0.012f * std::sin(flicker_t * 17.0f + p * 0.7f);
        }

        // Only write when something actually differs. Re-setting a light's
        // transform every frame is not free: it dirties the shadow map for a
        // lamp that has not moved since it was placed. Energy is a plain
        // scalar the shadow map does not care about, so the flicker term is
        // free to change it every frame regardless.
        const float want_range = range_of(slot.level);
        const float want_energy = energy_of(slot.level) * slot.fade * flicker;
        if (ol->get_position() != slot.pos)
            ol->set_position(slot.pos);
        if (ol->get_color() != slot.color)
            ol->set_color(slot.color);
        if (ol->get_param(Light3D::PARAM_RANGE) != want_range)
            ol->set_param(Light3D::PARAM_RANGE, want_range);
        if (ol->get_param(Light3D::PARAM_ENERGY) != want_energy)
            ol->set_param(Light3D::PARAM_ENERGY, want_energy);
        if (ol->get_param(Light3D::PARAM_ATTENUATION) != 1.5f)
            ol->set_param(Light3D::PARAM_ATTENUATION, 1.5f);
        if (!ol->is_visible())
            ol->set_visible(true);
        const bool want_shadow = !no_light_shadows && m_light_shadowed.count(slot.key) != 0;
        if (ol->has_shadow() != want_shadow)
            ol->set_shadow(want_shadow);
    }
    ema(m_ms_lights, ms_since(t0));
}

// ---- ambient motes -------------------------------------------------------

void GoannaClient::harvestMotes(v3s16 bp, MapBlock *block) {
    std::vector<MoteNode> motes;
    const NodeDefManager *ndef = m_session->nodeDefs();
    for (int z = 0; z < MAP_BLOCKSIZE; ++z)
    for (int y = 0; y < MAP_BLOCKSIZE; ++y)
    for (int x = 0; x < MAP_BLOCKSIZE; ++x) {
        MapNode n = block->getNodeNoCheck(x, y, z);
        const ContentFeatures &f = ndef->get(n);
        int kind = -1;
        if (itemgroup_get(f.groups, "leaves") > 0)
            kind = 0;
        else if (f.drawtype == NDT_PLANTLIKE || itemgroup_get(f.groups, "flower") > 0 ||
                itemgroup_get(f.groups, "flora") > 0)
            kind = 1;
        else if (itemgroup_get(f.groups, "sand") > 0 || itemgroup_get(f.groups, "falling_node") > 0)
            kind = 2;
        if (kind < 0)
            continue;
        // Subsample so a dense canopy does not become thousands of emitters.
        if (((x * 3 + y * 5 + z * 7) & 7) != 0)
            continue;
        // Only surface nodes shed motes: require air directly above (inside the
        // block; at the top boundary assume exposed).
        if (y + 1 < MAP_BLOCKSIZE) {
            MapNode above = block->getNodeNoCheck(x, y + 1, z);
            if (above.getContent() != CONTENT_AIR)
                continue;
        }
        MoteNode m;
        m.kind = kind;
        m.pos = Vector3(bp.X * MAP_BLOCKSIZE + x, bp.Y * MAP_BLOCKSIZE + y, -(bp.Z * MAP_BLOCKSIZE + z));
        video::SColor c(255, 200, 200, 200);
        if (f.visuals && f.visuals->tiles[0].layers[0].texture_id) {
            const TileLayer &tl = f.visuals->tiles[0].layers[0];
            std::string tname = m_session->tsrc()->imageName(tl.texture_id, tl.texture_layer_idx);
            if (!tname.empty())
                c = m_session->tsrc()->getTextureAverageColor(tname);
        }
        // Palette-tinted foliage (Mineclonia leaves, grass) has a greyscale
        // texture; the green comes from the node's palette colour by param2.
        // Without it the average reads brown/orange.
        if (f.visuals) {
            video::SColor pc(255, 255, 255, 255);
            f.visuals->getColor(n.getParam2(), &pc);
            c.set(255, c.getRed() * pc.getRed() / 255,
                    c.getGreen() * pc.getGreen() / 255,
                    c.getBlue() * pc.getBlue() / 255);
        }
        Color col(c.getRed() / 255.0f, c.getGreen() / 255.0f, c.getBlue() / 255.0f, 1.0f);
        // Keep the hue; lift brightness only mildly so lighting still owns it.
        float mx = std::max(col.r, std::max(col.g, col.b));
        if (mx > 0.02f && mx < 0.55f)
            col = col * (0.55f / mx);
        m.color = col;
        motes.push_back(m);
    }
    if (motes.empty())
        m_block_motes.erase(bp);
    else
        m_block_motes[bp] = std::move(motes);
}

void GoannaClient::ensureMoteMaterials() {
    if (m_mote_proc[0].is_valid())
        return;
    using PPM = ParticleProcessMaterial;
    for (int k = 0; k < 3; ++k) {
        Ref<PPM> pm;
        pm.instantiate();
        pm->set_emission_shape(PPM::EMISSION_SHAPE_SPHERE);
        m_mote_proc[k] = pm;
    }
    // leaves: sparse petals drifting on a soft wind (maple-petal look), not
    // falling like rain. Weak gravity, a sideways bias, turbulence for the
    // wander, and a wide emission volume so they spread over several blocks.
    m_mote_proc[0]->set_gravity(Vector3(0.05f, -0.12f, 0.03f));
    m_mote_proc[0]->set_emission_sphere_radius(1.6f);
    m_mote_proc[0]->set_direction(Vector3(0.4f, -0.4f, 0.2f));
    m_mote_proc[0]->set_spread(70.0f);
    m_mote_proc[0]->set_param_min(PPM::PARAM_INITIAL_LINEAR_VELOCITY, 0.05f);
    m_mote_proc[0]->set_param_max(PPM::PARAM_INITIAL_LINEAR_VELOCITY, 0.2f);
    m_mote_proc[0]->set_param_min(PPM::PARAM_ANGULAR_VELOCITY, -90);
    m_mote_proc[0]->set_param_max(PPM::PARAM_ANGULAR_VELOCITY, 90);
    m_mote_proc[0]->set_param_min(PPM::PARAM_SCALE, 0.5f);
    m_mote_proc[0]->set_param_max(PPM::PARAM_SCALE, 0.9f);
    m_mote_proc[0]->set_param_min(PPM::PARAM_DAMPING, 0.05f);
    m_mote_proc[0]->set_param_max(PPM::PARAM_DAMPING, 0.2f);
    m_mote_proc[0]->set_turbulence_enabled(true);
    m_mote_proc[0]->set_turbulence_noise_strength(0.35f);
    m_mote_proc[0]->set_turbulence_noise_scale(1.2f);
    // flora: slow pollen, barely rising
    m_mote_proc[1]->set_gravity(Vector3(0, 0.02f, 0));
    m_mote_proc[1]->set_emission_sphere_radius(0.8f);
    m_mote_proc[1]->set_spread(60.0f);
    m_mote_proc[1]->set_param_min(PPM::PARAM_INITIAL_LINEAR_VELOCITY, 0.02f);
    m_mote_proc[1]->set_param_max(PPM::PARAM_INITIAL_LINEAR_VELOCITY, 0.1f);
    m_mote_proc[1]->set_param_min(PPM::PARAM_SCALE, 0.25f);
    m_mote_proc[1]->set_param_max(PPM::PARAM_SCALE, 0.5f);
    m_mote_proc[1]->set_turbulence_enabled(true);
    m_mote_proc[1]->set_turbulence_noise_strength(0.25f);
    // sand/gravel: dust kicked up, settles quickly
    m_mote_proc[2]->set_gravity(Vector3(0, -1.4f, 0));
    m_mote_proc[2]->set_emission_sphere_radius(0.35f);
    m_mote_proc[2]->set_direction(Vector3(0, 1, 0));
    m_mote_proc[2]->set_param_min(PPM::PARAM_INITIAL_LINEAR_VELOCITY, 0.1f);
    m_mote_proc[2]->set_param_max(PPM::PARAM_INITIAL_LINEAR_VELOCITY, 0.5f);
    m_mote_proc[2]->set_param_min(PPM::PARAM_SCALE, 0.3f);
    m_mote_proc[2]->set_param_max(PPM::PARAM_SCALE, 0.6f);
}

void GoannaClient::set_motes(float density) {
    if (density < 0.0f)
        density = 0.0f;
    m_motes = density;
    if (density == 0.0f)
        for (auto &e : m_mote_pool)
            if (e.node)
                e.node->set_emitting(false);
}

void GoannaClient::update_motes(const Vector3 &around, int max_emitters) {
    if (m_motes <= 0.0f) {
        for (auto &e : m_mote_pool)
            if (e.node && e.node->is_emitting())
                e.node->set_emitting(false);
        return;
    }
    ensureMoteMaterials();
    // Motes are only worth drawing up close.
    const float radius = 20.0f;
    std::vector<const MoteNode *> all;
    for (auto &kv : m_block_motes)
        for (auto &m : kv.second)
            if (m.pos.distance_squared_to(around) < radius * radius)
                all.push_back(&m);
    std::sort(all.begin(), all.end(), [&](const MoteNode *a, const MoteNode *b) {
        return a->pos.distance_squared_to(around) < b->pos.distance_squared_to(around);
    });
    // Choose the nearest candidates as targets, but bind each emitter to a
    // specific node and keep it there: assigning "emitter i = i-th nearest"
    // reshuffles as the player moves and makes every puff teleport. Emitters
    // whose node is still a target stay put; freed ones take up new targets.
    int want = std::min((int)all.size(), max_emitters);
    if (getenv("GOANNA_DEBUG_MOTES")) {
        static int dbg = 0;
        if (dbg++ % 60 == 0)
            UtilityFunctions::print("motes: candidates ", (int)all.size(), " active ", want,
                    " (blocks ", (int)m_block_motes.size(), ")");
    }
    static const int base_amount[3] = {3, 3, 5};
    static const float lifetime[3] = {9.0f, 8.0f, 1.6f};
    while ((int)m_mote_pool.size() < max_emitters) {
        MoteEmitter e;
        e.node = memnew(GPUParticles3D);
        e.node->set_visible(false);
        e.node->set_emitting(false);
        Ref<QuadMesh> qm;
        qm.instantiate();
        qm->set_size(Vector2(0.11f, 0.11f));
        Ref<StandardMaterial3D> mm;
        mm.instantiate();
        mm->set_shading_mode(BaseMaterial3D::SHADING_MODE_PER_PIXEL);
        mm->set_billboard_mode(BaseMaterial3D::BILLBOARD_ENABLED);
        mm->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
        // A little roughness so they are not tiny specular sparkles.
        mm->set_roughness(1.0f);
        qm->set_material(mm);
        e.node->set_draw_pass_mesh(0, qm);
        add_child(e.node);
        m_mote_pool.push_back(e);
    }
    auto key = [](const Vector3 &p) {
        return String::num_int64((int64_t)Math::round(p.x)) + "," +
               String::num_int64((int64_t)Math::round(p.y)) + "," +
               String::num_int64((int64_t)Math::round(p.z));
    };
    std::map<String, const MoteNode *> targets;
    for (int i = 0; i < want; ++i)
        targets[key(all[i]->pos)] = all[i];
    // Keep emitters already sitting on a still-wanted target; release others.
    std::set<String> covered;
    for (auto &e : m_mote_pool) {
        if (e.kind < 0)
            continue;
        String k = key(e.at);
        if (targets.count(k) && !covered.count(k))
            covered.insert(k);
        else {
            e.node->set_emitting(false);
            e.node->set_visible(false);
            e.kind = -1;
        }
    }
    auto assign = [&](MoteEmitter &e, const MoteNode *m) {
        e.at = m->pos;
        e.kind = m->kind;
        e.node->set_position(m->pos + Vector3(0, m->kind == 0 ? 0.2f : 0.0f, 0));
        e.node->set_process_material(m_mote_proc[m->kind]);
        e.node->set_lifetime(lifetime[m->kind]);
        e.node->set_amount(std::max(1, (int)(base_amount[m->kind] * std::min(m_motes, 3.0f))));
        Ref<Mesh> mesh = e.node->get_draw_pass_mesh(0);
        if (mesh.is_valid()) {
            Ref<StandardMaterial3D> mm = ((QuadMesh *)mesh.ptr())->get_material();
            if (mm.is_valid())
                mm->set_albedo(m->color);
        }
        e.node->restart();
        e.node->set_visible(true);
        e.node->set_emitting(true);
    };
    size_t ei = 0;
    for (auto &kv : targets) {
        if (covered.count(kv.first))
            continue;
        while (ei < m_mote_pool.size() && m_mote_pool[ei].kind >= 0)
            ++ei;
        if (ei >= m_mote_pool.size())
            break;
        assign(m_mote_pool[ei], kv.second);
        ++ei;
    }
}

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


void GoannaClient::set_mesh_threads(int threads) {
    threads = std::clamp(threads, -1, 16);
    if (threads == m_mesh_threads)
        return;
    m_mesh_threads = threads;
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

// --- far rendering: tiers and regions (docs/far-rendering.md rungs 2, 3) ---

// Tier 0 is Luanti's full detail mesh. The four far tiers consume the rest of
// the retained occupancy ladder: cell 2, 4, 8 and 16. Repeating cell 1 as a
// far tier meant a 32-mapblock detail radius kept almost the entire ordinary
// 1024-node horizon at node resolution; the useful coarse rungs existed only
// beyond the grant. Atomic publication supplies transition overlap, so a
// duplicate steady-state resolution is unnecessary.
int GoannaClient::lodTierCount() const {
    return BlockLodChain::kLevels - 1;
}

int GoannaClient::lodCellFor(int tier) const {
    // Protocol summaries start at m_lod_cell (normally cell 4), while exact
    // chains retain finer rungs. This is the fallback pass used for summaries;
    // lodBuildRegion separately selects 1 << tier for exact data.
    const int rung = 1 << std::clamp(tier, 1, BlockLodChain::kLevels - 1);
    return std::min(MAP_BLOCKSIZE, std::max(m_lod_cell, rung));
}

// Region edge, in blocks. Keep the finest pass at roughly 32 cells per axis:
// an indivisible cell-1 build over the old four-block edge visited a 64-cubed
// volume and took 16--42 ms by itself, making any per-frame time budget
// meaningless. Coarser tiers grow spatially while retaining the same meshing
// workload and better batching at distance.
int GoannaClient::lodRegionBlocks(int tier) const {
    // The region edge doubles with the tier, like the cells do, keeping a
    // region at about a quarter of its band's inner radius. It used to run
    // 2, 4, 8, 8, 8, so while a far tier's cells were 8 times coarser its
    // regions were nearly the same physical size, and the instance count
    // per ring of horizon grew linearly with distance. Worse, most far
    // blocks are not on the horizon at all: at the test_world beach the
    // field held 16k tier 1 and 23k tier 2 blocks (the deep columns under
    // the 256 to 1024 node band) against 2.6k in tier 3, so two thirds of
    // the 3100 regions were 32 node tier 1 boxes, and the open west view
    // cost 4703 camera draws at 244 primitives each. Regions build on the
    // mesh workers and the far field rarely rebuilds once published, so
    // the churn cost of bigger batches lands off the main thread.
    if (tier <= 1)
        return 4;
    if (tier == 2)
        return 8;
    if (tier == 3)
        return std::min(16, 4 * m_lod_cell);
    return std::min(32, 8 * m_lod_cell);
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
    const float d = Vector2(centre.x - around.x, centre.z - around.z).length();
    auto cur = m_block_tier.find(bp);
    const int current = cur == m_block_tier.end() ? 0 : cur->second;
    const int tiers = lodTierCount();
    const float first = (float)m_lod_distance * MAP_BLOCKSIZE;
    // Residency is a data-source fact, not a presentation level. It promises
    // full detail only inside the configured detail radius. A local server
    // may send 32--40 mapblocks; keeping all of those at tier zero produced
    // 11 million primitives while the actual far field was only ~13k quads.
    // Outside this floor, live blocks enter the same atomic handoff as stored
    // blocks, so server range can improve knowledge without defeating LOD.
    // A live block inside the detail radius belongs to near. If it has not
    // arrived, however, keep the far fallback: server streaming coverage is
    // not a solid disc and reserving the whole radius for data we do not have
    // opens the circular moat seen while flying. lodBeginNearHandoff retires
    // that fallback only after the regional near mesh is actually published.
    if (live && d <= first)
        return 0;
    // Coarse bands double from a capped base, not from the detail distance.
    // They used to double from `first` itself, so raising detail from 12 to
    // 32 blocks also pushed cell 4 geometry out to a kilometre and the
    // cell 16 tier past a 4096 grant entirely: measured at 10M primitives
    // and 15k draws on the diffusion world. Detail buys the near field;
    // the far ladder keeps its own scale. At the old default of 12 the cap
    // changes nothing.
    const float base = std::min(first, 256.0f);
    auto threshold = [&](int t) {
        return std::max(first, base * (float)(1 << (t - 1)));
    };
    int desired = 1;
    for (int t = 1; t < tiers; ++t)
        if (d > threshold(t + 1))
            desired = t + 1;
    if (desired < current && current >= 1 && d > threshold(current) * 0.85f)
        return current;
    return desired;
}

const BlockLodChain *GoannaClient::lodChain(v3s16 bp) {
    auto it = m_lod_chains.find(bp);
    if (it != m_lod_chains.end())
        return it->second.get();
    if (!m_session)
        return nullptr;
    MapBlock *b = m_session->getBlock(bp);
    if (b) {
        // Tier zero is already represented by the exact near mesh. Its
        // serialized source is in BlockStore, so deriving a second exact LOD
        // hierarchy now only stalls block polling. It will be derived lazily
        // after this block leaves the live set and a far region asks for it.
        auto tier = m_block_tier.find(bp);
        if (tier != m_block_tier.end() && tier->second <= 0)
            return nullptr;
        const auto t_chain = clock_t_::now();
        auto owned = std::make_shared<BlockLodChain>();
        // Full blocks retain their exact node boundary. Summaries begin at
        // cell 4, but data we have actually received must not be needlessly
        // reduced to the summary's resolution.
        buildLodChain(m_session->nodeDefs(), b, *owned, BlockLodChain::levelForCell(1));
        ema(m_ms_lod_chain, ms_since(t_chain));
        ++m_lod_chains_built_last;
        const BlockLodChain *built = owned.get();
        m_lod_chains[bp] = std::move(owned);
        return built;
    }
    // Not live: the store, if the server has granted far rendering. This is
    // the one seam between the live range and what was seen before: the
    // chain is the same shape either way, and the block itself is let go as
    // soon as the chain is built.
    if (m_session->farRenderingGrant() <= 0)
        return nullptr;
    std::unique_ptr<MapBlock> stored = m_session->loadStoredBlock(bp);
    if (!stored)
        return nullptr;
    const auto t_chain = clock_t_::now();
    auto owned = std::make_shared<BlockLodChain>();
    buildLodChain(m_session->nodeDefs(), stored.get(), *owned, BlockLodChain::levelForCell(1));
    ema(m_ms_lod_chain, ms_since(t_chain));
    ++m_lod_chains_built_last;
    owned->stored = true;
    const BlockLodChain *built = owned.get();
    m_lod_chains[bp] = std::move(owned);
    return built;
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
    // The knowledge/mesh split (docs/sky-orchestration.md, "The baked
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

// Blocks the server is not sending but the store holds, within the granted
// far distance: assigned to tiers like received blocks and drawn from their
// chains. Rescans when the player crosses a block boundary or every two
// seconds, and lets go of what has passed out of range. Caller holds the map
// lock.
void GoannaClient::lodUpdateFar(const Vector3 &around) {
    if (!m_session)
        return;
    int grant = m_session->farRenderingGrant();
    // The default is the grant, not a fixed number (docs/launch-target.md
    // task 2d): a 512 node default left half of a 1024 node grant unused
    // until someone thought to raise it. An explicit choice, env var or
    // settings panel, still wins.
    if (!m_far_distance_explicit && grant > 0 && grant != m_far_distance) {
        m_far_distance = std::clamp(grant, 0, 4096);
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
    for (int64_t idx = m_far_store_cursor; idx < scan_end; ++idx) {
                const int rx = lo.X + (int)(idx % span_x);
                const int ry = lo.Y + (int)((idx / span_x) % span_y);
                const int rz = lo.Z + (int)(idx / (span_x * span_y));
                if (!m_session->storedRegionMask(v3s16(rx, ry, rz), bits))
                    continue;
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
                        m_lod_chains.erase(chained);
                        m_far_remote.erase(bp);
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
    // the world is seen ending in clear air (docs/far-rendering.md,
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
    // The ridge probe (docs/sky-orchestration.md): how high the drawn
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
// chains exactly as stored blocks do (docs/far-rendering.md). Areas are
// asked for nearest first, a few in flight, and never asked twice.
void GoannaClient::lodRequestSummaries(const v3s16 &centre, int radius) {
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
    // Vertical window. A fixed one area either side (docs/far-rendering.md's
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
    // docs/far-rendering.md.
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
        // something (docs/far-rendering.md, "Where the summary budget
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
    for (const std::string &msg : m_session->takeFarSummaries()) {
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
        m_far_pending.erase(v3s16(ox, oy, oz));
        m_far_inflight = (int)m_far_pending.size();
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
                // docs/launch-target.md's purple cells) turned a name this
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
        ask.complete = complete_records == total;
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
                if (old != m_lod_chains.end() && !old->second->summary)
                    continue;
            }
            auto name_of = [&](uint8_t idx, content_t fallback) -> content_t {
                return idx != 0 && idx < ids.size() ? ids[idx] : fallback;
            };
            auto ch_owned = std::make_shared<BlockLodChain>();
            BlockLodChain &ch = *ch_owned;
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
			if (!any_filled)
				continue;
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
            // Not stored: a summary is what the server holds now, not a
            // memory of what it once sent, so it is not marked stale
            // (docs/launch-target.md, R1). The chain is still known.
            ch.stored = false;
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

void GoannaClient::lodMarkDirty(const LodRegionKey &key) {
    LodRegion &r = m_lod_regions[key];
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
    // no longer meets this one (docs/far-rendering.md, "The far field as a
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

void GoannaClient::lodEnqueueChain(const v3s16 &bp) {
    auto tier = m_block_tier.find(bp);
    // The exact near mesh owns a tier 0 block, so it needs no chain to
    // draw; but box occluders read the chain's fine occlusion bits, and
    // without near coverage the box mode emitted almost nothing (measured
    // 2026-08-31: 3.5k box triangles against 537k mesh-cut at the vista)
    // while the mesh-cut construction it replaces was about 45 per cent of
    // the flying hitch rate on a same-client A/B.
    if (tier != m_block_tier.end() && tier->second <= 0 && !m_occluder_boxes)
        return;
    if (m_lod_chains.count(bp) || m_lod_chain_missing.count(bp) || !m_lod_chain_queued.insert(bp).second)
        return;
    m_lod_chain_queue.push_back(bp);
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
    m_lod_chains.erase(bp);
    lodAssign(bp, 0);
}

// One near block's meshing, run on a mesh worker.
//
// The map reads are already done: gatherMeshData copied the block and its
// 3x3x3 neighbourhood into `data`, and the light field copied the same
// neighbourhood's light and occupancy, both on the main thread under the map
// lock. What is left is the two expensive parts, Luanti's mesher and the
// occlusion trace, neither of which touches the map, Godot or (for a block
// with no dig crack in it) the texture source.
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
// its own lock (goanna_lod.h, LodTileCache).
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
    if (!missing)
        for (const v3s16 &bp : r.members)
            if (!r.published_members.count(bp)) {
                missing = true;
                break;
            }
    const int wanted_exact = std::min(lodCellFor(key.tier), 1 << std::max(1, key.tier));
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
            r.node->queue_free();
            r.node = nullptr;
        }
        r.faces = r.quads = r.surfaces = 0;
        r.published = false;
        r.published_members.clear();
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
        auto tier = m_block_tier.find(bp);
        if (tier != m_block_tier.end() && tier->second <= 0)
            return nullptr; // near geometry owns it; close the LOD frontier
        // Not built yet: ask for it, and come back to this region when it is.
        lodEnqueueChain(bp);
        if (m_lod_chain_queued.count(bp))
            m_lod_chain_waiters[bp].insert(key);
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
        return std::min(lodCellFor(it->second), 1 << std::max(1, it->second));
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
    const int exact_cell = std::min(lodCellFor(key.tier), 1 << std::max(1, key.tier));
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
    const int e = out.edge();
    for (int z = 0; z < e; ++z)
        for (int y = 0; y < e; ++y)
            for (int x = 0; x < e; ++x) {
                const v3s16 bp = exact.origin + v3s16((s16)(x - margin), (s16)(y - margin),
                                                        (s16)(z - margin));
                LodRegionSnapshot::Entry *en = out.at(bp);
                if (!en)
                    continue;
                // Through the live lookups, so a chain that is missing is
                // still asked for and this region still registers as waiting
                // on it, exactly as the synchronous path did.
                const BlockLodChain *ch = exact.chain ? exact.chain(bp) : nullptr;
                if (ch) {
                    auto it = m_lod_chains.find(bp);
                    if (it != m_lod_chains.end())
                        en->chain = it->second;
                }
                en->drawn_cell = exact.drawn_cell ? exact.drawn_cell(bp) : -1;
                // Membership without the cell test: bind() adds that, and it
                // differs between the exact and fallback passes.
                auto mit = m_lod_member.find(bp);
                en->member = mit != m_lod_member.end() && mit->second == key;
            }
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
    // The block being dug asks the texture source for the crack overlay while
    // it meshes, which is main thread only here, and it re-meshes on every
    // crack step anyway. One block, meshed inline.
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
    int published = 0;
    MeshPool::Done done;
    while (m_mesh_pool.next(done)) {
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
                    job->occ_idx, job->members);
            ++published;
            if (region.members.empty() && !region.dirty)
                m_near_regions.erase(it);
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

void GoannaClient::lodPublishRegion(const LodRegionKey &key, LodRegion &r, const LodRegionMesh &lm,
        std::chrono::steady_clock::time_point t0, int exact_cell_used, int coarse_cell_used) {
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
            line += String(" tex ") + String::num_int64(sf.texture_id) + ":" +
                    String::num_int64((int64_t)sf.idx.size() / 6);
        UtilityFunctions::print(line, " ", String::num(ms_since(t0), 2), " ms");
    }
    if (lm.empty()) {
        if (r.node) {
            r.node->queue_free();
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
    Ref<ArrayMesh> mesh;
    mesh.instantiate();
    int si = 0;
    for (const LodSurface &sf : lm.surfaces) {
        const int nv = (int)sf.pos.size();
        if (nv == 0 || sf.idx.empty())
            continue;
        PackedVector3Array verts, norms;
        PackedVector2Array uvs, uv2s;
        PackedColorArray cols;
        PackedByteArray custom0;
        PackedInt32Array idx;
        verts.resize(nv);
        norms.resize(nv);
        uvs.resize(nv);
        uv2s.resize(nv);
        cols.resize(nv);
        custom0.resize(nv * 4);
        for (int i = 0; i < nv; ++i) {
            verts[i] = Vector3(sf.pos[i].X, sf.pos[i].Y, sf.pos[i].Z);
            norms[i] = Vector3(sf.nrm[i].X, sf.nrm[i].Y, sf.nrm[i].Z);
            uvs[i] = Vector2(sf.uv[i].X, sf.uv[i].Y);
            uv2s[i] = Vector2(sf.uv2[i].X, sf.uv2[i].Y);
            const u32 c = sf.col[i];
            cols[i] = Color(((c >> 16) & 0xff) / 255.0f, ((c >> 8) & 0xff) / 255.0f,
                    (c & 0xff) / 255.0f, 1.0f);
            for (int k = 0; k < 4; ++k)
                custom0[i * 4 + k] = sf.custom0[i * 4 + k];
        }
        idx.resize((int)sf.idx.size());
        for (size_t i = 0; i < sf.idx.size(); ++i)
            idx[i] = (int)sf.idx[i];
        Array arrays;
        arrays.resize(Mesh::ARRAY_MAX);
        arrays[Mesh::ARRAY_VERTEX] = verts;
        arrays[Mesh::ARRAY_NORMAL] = norms;
		arrays[Mesh::ARRAY_TANGENT] = node_tangents(verts, norms, uvs, idx);
        arrays[Mesh::ARRAY_TEX_UV] = uvs;
        arrays[Mesh::ARRAY_TEX_UV2] = uv2s;
        arrays[Mesh::ARRAY_COLOR] = cols;
        arrays[Mesh::ARRAY_CUSTOM0] = custom0;
        arrays[Mesh::ARRAY_INDEX] = idx;
        mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                Dictionary(), kNodeSurfaceFlags);
        Ref<Material> mat;
        if (sf.liquid) {
            // Water at distance, docs/far-rendering.md rung 6: the same water
            // shader as the near mesh, on the liquid's own tile, with the
            // same parameters, so the sea reads as sea at the horizon with
            // its specular, fresnel and the sky's reflection. Everything that
            // must differ between near and far (waves, the reflection march,
            // absorption, the flatten toward the tile average) is a function
            // of view distance inside the shader itself, because two
            // materials that agree at every distance cannot draw a seam at
            // the hand-off. Waving used to be off here, and the reflection
            // march was gated on it, which left the far sea a dark band
            // against the reflecting near water (the R2 recorded in
            // docs/far-rendering.md, "the far tier water plane").
            auto wit = m_lod_water.find(sf.texture_id);
            if (wit == m_lod_water.end()) {
                Ref<ShaderMaterial> wm;
                if (!m_shaders_loaded)
                    materialFor(MaterialKey()); // loads the shaders
                GoannaTexture *wgt = m_session->tsrc()->goannaTexture(sf.texture_id);
                if (m_sh_water.is_valid() && wgt && wgt->godotTexture().is_valid()) {
                    wm.instantiate();
                    wm->set_shader(m_sh_water);
                    wm->set_shader_parameter("albedo_tex", wgt->godotTexture());
                    wm->set_shader_parameter("waving", true);
                    wm->set_shader_parameter("lod_flatten", true);
                }
                wit = m_lod_water.emplace(sf.texture_id, wm).first;
            }
            mat = wit->second;
        } else if (sf.texture_id) {
            // The same array shader and arrays as the near mesh, so there is
            // no distance at which the world changes renderer; only the tier
            // copy adds block light as emission.
            MaterialKey k;
            k.texture_id = sf.texture_id;
            k.array_texture = true;
            k.lod = true;
            mat = materialFor(k);
        } else {
            // Tiles with no array texture: the flat colour the old single
            // tier drew everything with, now only the exception.
            if (m_lod_material.is_null()) {
                m_lod_material.instantiate();
                m_lod_material->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
                // The vertex colour here is the tile's sRGB average (the
                // fallback in goanna_lod.cpp), so say so, or Godot reads it
                // as linear and the tile is brighter than it is anywhere
                // else (docs/launch-target.md, R1).
                m_lod_material->set_flag(BaseMaterial3D::FLAG_SRGB_VERTEX_COLOR, true);
                m_lod_material->set_roughness(1.0f);
                m_lod_material->set_metallic(0.0f);
            }
            mat = m_lod_material;
        }
        if (mat.is_valid())
            mesh->surface_set_material(si, mat);
        ++si;
    }
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
    auto t0 = clock_t_::now();
    // Chains first, inside half the budget. A chain that a region was
    // waiting on dirties that region again.
    while (!m_lod_chain_queue.empty() && ms_since(t0) < budget_ms * 0.5) {
        const v3s16 bp = m_lod_chain_queue.front();
        m_lod_chain_queue.pop_front();
        m_lod_chain_queued.erase(bp);
        // Only blocks that matter to a region: a neighbour of nothing drawn
        // is a chain no one reads, and the store could supply millions.
        const bool wanted = m_lod_member.count(bp) || m_lod_chain_waiters.count(bp);
        const BlockLodChain *built = wanted ? lodChain(bp) : nullptr;
        if (wanted && !built)
            m_lod_chain_missing.insert(bp);
        auto w = m_lod_chain_waiters.find(bp);
        if (w != m_lod_chain_waiters.end()) {
            if (built)
                for (const LodRegionKey &k : w->second)
                    if (m_lod_regions.count(k))
                        lodMarkDirty(k);
            m_lod_chain_waiters.erase(w);
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

int GoannaClient::poll_blocks(int max_blocks) {
    if (!m_session)
        return 0;
    if (m_session->prepareContentIfReady())
        return 0;
    std::vector<v3s16> fresh_raw = m_session->takeNewBlocks();
    std::vector<v3s16> fresh;
    int done = 0;
    auto t_poll = clock_t_::now();
    // A time budget as well as a count: a full detail block costs about 5 ms
    // to mesh and upload, so 24 of them in one poll was a 120 ms frame, which
    // is what the arrival of a new area felt like. What does not fit is
    // requeued and comes next frame. GOANNA_POLL_MS overrides the budget.
    static const double poll_budget_ms = [] {
        const char *v = getenv("GOANNA_POLL_MS");
        return v ? std::max(1.0, atof(v)) : 6.0;
    }();
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
    const int keep = m_session->wantedRange + 4;
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
    for (const v3s16 &bp : fresh) {
        if (done >= max_blocks || (done > 0 && ms_since(t_poll) > poll_budget_ms)) {
            m_session->requeueBlock(bp);
            continue;
        }
        MapBlock *block = m_session->getBlock(bp);
        if (!block)
            continue;
        if (std::getenv("GOANNA_DEBUG_CONTENT") && !m_session->contentPrepared()) {
            static int early = 0;
            if (++early % 25 == 1)
                fprintf(stderr, "goanna content: meshing block %d before content prepared\n", early);
        }
        // Far blocks are drawn by their region's mesh at their tier, never one
        // by one: see lodBuildRegion and docs/far-rendering.md.
        int tier = lodTierFor(bp, m_lod_centre, true);
        // The network handler has already persisted the compact serialized
        // block. Do not synchronously derive a second exact hierarchy for a
        // block about to receive an exact near mesh: cell-1 made this poll
        // take 90--127 ms while streaming. If it later leaves the live set,
        // lodChain() derives the sparse hierarchy lazily from BlockStore.
        m_lod_chains.erase(bp); // discard an older summary/store view
        m_lod_chain_queued.erase(bp); // stale deque entries are harmless
        m_lod_chain_waiters.erase(bp);
        m_lod_handoff_near.erase(bp);
        m_lod_chain_missing.erase(bp);
        m_far_blocks.erase(bp); // live now, whatever the store said
        m_far_remote.erase(bp);
        m_block_queued_at.erase(bp); // reached the front: aging starts over
        if (tier >= 1) {
            nearDrop(bp);
            lodAssign(bp, tier);
            m_block_tier[bp] = tier;
            ++done;
            continue;
        }
        auto t_mesh = clock_t_::now();
        // Luanti's own light never reaches the vertices (g_goanna_no_light,
        // see goanna_mesh_flags.h), so it is read here instead, from the same
        // nodes, along with the occlusion trace. docs/mesh-attributes.md.
        std::unique_ptr<MapBlockMesh> bm;
        BlockLightField lightfield;
        std::map<uint32_t, std::vector<VertexLight>> vertex_light;
        auto ready = m_near_ready.find(bp);
        if (ready != m_near_ready.end()) {
            auto wanted = m_near_generation.find(bp);
            if (wanted == m_near_generation.end() || ready->second.generation != wanted->second) {
                m_near_ready.erase(ready);
                if (m_mesh_pool.running() && nearSubmit(bp, block))
                    continue;
                ready = m_near_ready.end();
            }
        }
        if (ready != m_near_ready.end()) {
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
        Ref<ArrayMesh> mesh;
        mesh.instantiate();
        int si = 0;
        // Accumulate by material: a block emits one buffer per tile layer, and
        // each surface is its own draw call, so buffers that resolve to the
        // same material (which array textures make common) are concatenated
        // into a single surface. This is where the draw-call saving is: the
        // array texture only makes the materials equal, merging is what turns
        // that into fewer draws.
        struct SurfAccum {
            MaterialKey key;
            PackedVector3Array verts, norms;
            PackedVector2Array uvs, uv2s;
            PackedColorArray cols;
            PackedByteArray custom0; // block light, sky light, occlusion, spare
            PackedInt32Array idx;
            bool is_array = false;
        };
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
                MaterialKey key = keyForIrr(buf->getMaterial(), nv ? v[0].Aux : 0);
                // Which node a face belongs to: step half a node back along the
                // outward normal from the face centre and you are inside it.
                // Used for the glow split below and for the block semantic ID
                // in UV2.y (docs/mesh-attributes.md), which is per node.
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
                // Vertices are shared within a buffer, so each destination keeps
                // its own remap rather than duplicating every triangle's three.
                std::map<u32, int> remap[2];
                for (u32 t = 0; t + 2 < ni; t += 3) {
                    const u16 tri[3] = { idx16[t], idx16[t + 1], idx16[t + 2] };
                    const content_t owner = owner_content(tri);
                    const bool glows = !glow_casts && gnd && owner != CONTENT_IGNORE &&
                            gnd->get(owner).light_source > 0;
                    const int g = glows ? 1 : 0;
                    const float block_id = owner == CONTENT_IGNORE ? 0.0f : (float)mtable.blockOf(owner);
                    SurfAccum &tacc = g ? glow_groups[key.hash()] : groups[key.hash()];
                    tacc.key = key;
                    tacc.is_array = key.array_texture;
                    for (int k = 0; k < 3; ++k) {
                        const u32 sv = tri[k];
                        auto found = remap[g].find(sv);
                        if (found != remap[g].end()) {
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
                        // UV2 always, per docs/mesh-attributes.md: x is the
                        // array layer, y the block semantic ID that an Iris
                        // pack reads as mc_Entity.x, from the classifier's
                        // block column for the owning node. 0 is the correct
                        // failure: unremarkable, not wrong.
                        tacc.uv2s.push_back(Vector2(tacc.is_array ? (float)v[sv].Aux : 0.0f, block_id));
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
                        remap[g][sv] = di;
                        tacc.idx.push_back(di);
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
        auto keep_regional = [&](SurfAccum &acc, bool glow) {
            NearSurface surface;
            surface.key = acc.key;
            surface.verts = acc.verts;
            surface.norms = acc.norms;
            surface.uvs = acc.uvs;
            surface.uv2s = acc.uv2s;
            surface.cols = acc.cols;
            surface.custom0 = acc.custom0;
            surface.idx = acc.idx;
            surface.glow = glow;
            near_block.surfaces.push_back(std::move(surface));
        };
        for (auto &kv : groups) {
            SurfAccum &acc = kv.second;
            if (acc.verts.is_empty() || acc.idx.is_empty())
                continue;
            ++near_block.source_surfaces;
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
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), kNodeSurfaceFlags);
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
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            gmesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), kNodeSurfaceFlags);
            gmesh->surface_set_material(gsi++, materialFor(acc.key));
        }
        // A block of nothing but region-batched or glowing surfaces still
        // has geometry, so all three destinations have to be empty before it
        // is thrown away.
        if (near_block.surfaces.empty() && si == 0 && gsi == 0) {
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
        if (si > 0 || gsi > 0) {
            mi = memnew(MeshInstance3D);
            add_child(mi);
            near_block.special_node = mi;
        }
        if (si > 0)
            mi->set_mesh(mesh);
        // The glow mesh hangs off the block mesh rather than being tracked
        // beside it, so every place that frees a block frees this too and none
        // of them had to learn about it.
        MeshInstance3D *gmi = nullptr;
        if (gsi > 0) {
            gmi = memnew(MeshInstance3D);
            gmi->set_layer_mask(GLOW_LAYER);
            mi->add_child(gmi);
            gmi->set_mesh(gmesh);
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
        // nominally six-millisecond poll take 130--158 ms.
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
    nearRebuild(std::max(2.0, poll_budget_ms - ms_since(t_poll)));
    ema(m_ms_poll_near, ms_since(t_near));
    const auto t_lod = clock_t_::now();
    lodRebuild(std::max(2.0, poll_budget_ms - ms_since(t_poll)));
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

void GoannaClient::_bind_methods() {
    ClassDB::bind_method(D_METHOD("hello"), &GoannaClient::hello);
    ClassDB::bind_method(D_METHOD("luanti_version"), &GoannaClient::luanti_version);
    ClassDB::bind_method(D_METHOD("set_material_strength", "channel", "value"), &GoannaClient::set_material_strength);
    ClassDB::bind_method(D_METHOD("material_strength", "channel"), &GoannaClient::material_strength);
    ClassDB::bind_method(D_METHOD("server_options"), &GoannaClient::server_options);
    ClassDB::bind_method(D_METHOD("set_solid_ice", "on"), &GoannaClient::set_solid_ice);
    ClassDB::bind_method(D_METHOD("solid_ice"), &GoannaClient::solid_ice);
    ClassDB::bind_method(D_METHOD("set_texture_map", "csv"), &GoannaClient::set_texture_map);
    ClassDB::bind_method(D_METHOD("set_texture_path", "path"), &GoannaClient::set_texture_path);
    ClassDB::bind_method(D_METHOD("texture_path"), &GoannaClient::texture_path);
    ClassDB::bind_method(D_METHOD("connect_to", "host", "port", "player_name", "password"),
            &GoannaClient::connect_to);
    ClassDB::bind_method(D_METHOD("disconnect_from_server"), &GoannaClient::disconnect_from_server);
    ClassDB::bind_method(D_METHOD("status"), &GoannaClient::status);
    ClassDB::bind_method(D_METHOD("poll_blocks", "max_blocks"), &GoannaClient::poll_blocks);
    ClassDB::bind_method(D_METHOD("block_mesh_count"), &GoannaClient::block_mesh_count);
    ClassDB::bind_method(D_METHOD("material_count"), &GoannaClient::material_count);
    ClassDB::bind_method(D_METHOD("material_diagnostics", "texture_name"),
            &GoannaClient::material_diagnostics, DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("set_player_pose", "pos", "pitch_deg", "yaw_deg"),
            &GoannaClient::set_player_pose);
    ClassDB::bind_method(D_METHOD("server_player_position"), &GoannaClient::server_player_position);
    ClassDB::bind_method(D_METHOD("step_player", "dt", "keys", "pitch_deg", "yaw_deg"), &GoannaClient::step_player);
    ClassDB::bind_method(D_METHOD("take_sounds"), &GoannaClient::take_sounds);
    ClassDB::bind_method(D_METHOD("take_stopped_sounds"), &GoannaClient::take_stopped_sounds);
    ClassDB::bind_method(D_METHOD("media_bytes", "name"), &GoannaClient::media_bytes);
    ClassDB::bind_method(D_METHOD("media_names"), &GoannaClient::media_names);
    ClassDB::bind_method(D_METHOD("take_particle_spawners"), &GoannaClient::take_particle_spawners);
    ClassDB::bind_method(D_METHOD("take_deleted_spawners"), &GoannaClient::take_deleted_spawners);
    ClassDB::bind_method(D_METHOD("take_dug_nodes"), &GoannaClient::take_dug_nodes);
    ClassDB::bind_method(D_METHOD("take_particles"), &GoannaClient::take_particles);
    ClassDB::bind_method(D_METHOD("node_name_at", "pos"), &GoannaClient::node_name_at);
    ClassDB::bind_method(D_METHOD("ground_albedo", "center"), &GoannaClient::ground_albedo);
    ClassDB::bind_method(D_METHOD("ground_height", "center"), &GoannaClient::ground_height);
    ClassDB::bind_method(D_METHOD("node_sound", "node_name", "kind"), &GoannaClient::node_sound);
    ClassDB::bind_method(D_METHOD("sky_state"), &GoannaClient::sky_state);
    ClassDB::bind_method(D_METHOD("horizon_bake_request", "origin", "r0", "r1"),
            &GoannaClient::horizon_bake_request);
    ClassDB::bind_method(D_METHOD("horizon_bake_poll"), &GoannaClient::horizon_bake_poll);
    ClassDB::bind_method(D_METHOD("perf_worst_take"), &GoannaClient::perf_worst_take);
    ClassDB::bind_method(D_METHOD("update_lights", "around", "max_lights"), &GoannaClient::update_lights);
    ClassDB::bind_method(D_METHOD("set_shadow_lamps", "n"), &GoannaClient::set_shadow_lamps);
    ClassDB::bind_method(D_METHOD("shadow_lamps"), &GoannaClient::shadow_lamps);
    ClassDB::bind_method(D_METHOD("set_light_flicker", "on"), &GoannaClient::set_light_flicker);
    ClassDB::bind_method(D_METHOD("light_flicker"), &GoannaClient::light_flicker);
    ClassDB::bind_method(D_METHOD("set_motes", "density"), &GoannaClient::set_motes);
    ClassDB::bind_method(D_METHOD("motes"), &GoannaClient::motes);
    ClassDB::bind_method(D_METHOD("update_motes", "around", "max_emitters"), &GoannaClient::update_motes);
    ClassDB::bind_method(D_METHOD("sync_entities", "dt"), &GoannaClient::sync_entities);
    ClassDB::bind_method(D_METHOD("take_chat"), &GoannaClient::take_chat);
    ClassDB::bind_method(D_METHOD("send_chat", "message"), &GoannaClient::send_chat);
    ClassDB::bind_method(D_METHOD("hp"), &GoannaClient::hp);
    ClassDB::bind_method(D_METHOD("breath"), &GoannaClient::breath);
    ClassDB::bind_method(D_METHOD("hud_state"), &GoannaClient::hud_state);
    ClassDB::bind_method(D_METHOD("inventory_state"), &GoannaClient::inventory_state);
    ClassDB::bind_method(D_METHOD("inventory_state_at", "location"), &GoannaClient::inventory_state_at);
    ClassDB::bind_method(D_METHOD("detached_inventory_names"), &GoannaClient::detached_inventory_names);
    ClassDB::bind_method(D_METHOD("respawn"), &GoannaClient::respawn);
    ClassDB::bind_method(D_METHOD("texture", "name"), &GoannaClient::texture);
    ClassDB::bind_method(D_METHOD("item_icon", "item_name"), &GoannaClient::item_icon);
    ClassDB::bind_method(D_METHOD("inventory_formspec"), &GoannaClient::inventory_formspec);
    ClassDB::bind_method(D_METHOD("take_shown_formspecs"), &GoannaClient::take_shown_formspecs);
    ClassDB::bind_method(D_METHOD("send_inventory_fields", "formname", "fields"), &GoannaClient::send_inventory_fields);
    ClassDB::bind_method(D_METHOD("set_wield_index", "index"), &GoannaClient::set_wield_index);
    ClassDB::bind_method(D_METHOD("wield_index"), &GoannaClient::wield_index);
    ClassDB::bind_method(D_METHOD("inventory_action", "action"), &GoannaClient::inventory_action);
    ClassDB::bind_method(D_METHOD("step_interact", "dt", "dig", "place", "place_pressed", "sneak"), &GoannaClient::step_interact, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("send_nodemeta_fields", "context", "formname", "fields"), &GoannaClient::send_nodemeta_fields);
    ClassDB::bind_method(D_METHOD("entity_count"), &GoannaClient::entity_count);
    ClassDB::bind_method(D_METHOD("entity_positions"), &GoannaClient::entity_positions);
    ClassDB::bind_method(D_METHOD("entity_list"), &GoannaClient::entity_list);
    ClassDB::bind_method(D_METHOD("render_stats"), &GoannaClient::render_stats);
    ClassDB::bind_method(D_METHOD("set_show_body", "show"), &GoannaClient::set_show_body);
    ClassDB::bind_method(D_METHOD("set_arm_swing", "s"), &GoannaClient::set_arm_swing);
    ClassDB::bind_method(D_METHOD("show_body"), &GoannaClient::show_body);
    ClassDB::bind_method(D_METHOD("wield_item_name"), &GoannaClient::wield_item_name);
    ClassDB::bind_method(D_METHOD("wield_light"), &GoannaClient::wield_light);
    ClassDB::bind_method(D_METHOD("wield_info"), &GoannaClient::wield_info);
    ClassDB::bind_method(D_METHOD("item_mesh", "item_name"), &GoannaClient::item_mesh);
    ClassDB::bind_method(D_METHOD("model_preview", "mesh_name", "textures", "frame_loop", "speed"),
            &GoannaClient::model_preview);
    ClassDB::bind_method(D_METHOD("set_time_of_day_override", "tod"), &GoannaClient::set_time_of_day_override);
    ClassDB::bind_method(D_METHOD("is_underwater", "eye"), &GoannaClient::is_underwater);
    ClassDB::bind_method(D_METHOD("set_bevel", "width"), &GoannaClient::set_bevel);
    ClassDB::bind_method(D_METHOD("bevel"), &GoannaClient::bevel);
    ClassDB::bind_method(D_METHOD("set_auto_bump", "strength"), &GoannaClient::set_auto_bump);
    ClassDB::bind_method(D_METHOD("auto_bump"), &GoannaClient::auto_bump);
    ClassDB::bind_method(D_METHOD("prune_blocks", "radius"), &GoannaClient::prune_blocks);
    ClassDB::bind_method(D_METHOD("resident_blocks"), &GoannaClient::resident_blocks);
    ClassDB::bind_method(D_METHOD("set_lod_distance", "blocks"), &GoannaClient::set_lod_distance);
    ClassDB::bind_method(D_METHOD("lod_distance"), &GoannaClient::lod_distance);
    ClassDB::bind_method(D_METHOD("set_lod_cell", "nodes"), &GoannaClient::set_lod_cell);
    ClassDB::bind_method(D_METHOD("set_mesh_threads", "threads"), &GoannaClient::set_mesh_threads);
    ClassDB::bind_method(D_METHOD("mesh_threads"), &GoannaClient::mesh_threads);
    ClassDB::bind_method(D_METHOD("lod_cell"), &GoannaClient::lod_cell);
    ClassDB::bind_method(D_METHOD("update_lod", "around", "max_rebuild"), &GoannaClient::update_lod);
    ClassDB::bind_method(D_METHOD("set_store_path", "root"), &GoannaClient::set_store_path);
    ClassDB::bind_method(D_METHOD("store_path"), &GoannaClient::store_path);
    ClassDB::bind_method(D_METHOD("set_far_distance", "nodes"), &GoannaClient::set_far_distance);
    ClassDB::bind_method(D_METHOD("set_far_mesh_distance", "nodes"),
            &GoannaClient::set_far_mesh_distance);
    ClassDB::bind_method(D_METHOD("far_mesh_distance"), &GoannaClient::far_mesh_distance);
    ClassDB::bind_method(D_METHOD("set_occluder_distance", "nodes"),
            &GoannaClient::set_occluder_distance);
    ClassDB::bind_method(D_METHOD("occluder_distance"), &GoannaClient::occluder_distance);
    ClassDB::bind_method(D_METHOD("set_occluder_boxes", "on"), &GoannaClient::set_occluder_boxes);
    ClassDB::bind_method(D_METHOD("occluder_boxes"), &GoannaClient::occluder_boxes);
    ClassDB::bind_method(D_METHOD("far_distance"), &GoannaClient::far_distance);
    ClassDB::bind_method(D_METHOD("set_view_range", "blocks"), &GoannaClient::set_view_range);
    ClassDB::bind_method(D_METHOD("view_range"), &GoannaClient::view_range);
    ClassDB::bind_method(D_METHOD("set_view_fov", "degrees"), &GoannaClient::set_view_fov);
    ClassDB::bind_method(D_METHOD("set_mantle", "on"), &GoannaClient::set_mantle);
    ClassDB::bind_method(D_METHOD("mantle"), &GoannaClient::mantle);
    ClassDB::bind_method(D_METHOD("set_aux1_descends", "on"), &GoannaClient::set_aux1_descends);
    ClassDB::bind_method(D_METHOD("aux1_descends"), &GoannaClient::aux1_descends);
    ClassDB::bind_method(D_METHOD("set_pitch_move", "on"), &GoannaClient::set_pitch_move);
    ClassDB::bind_method(D_METHOD("pitch_move"), &GoannaClient::pitch_move);
    ClassDB::bind_method(D_METHOD("set_always_fly_fast", "on"), &GoannaClient::set_always_fly_fast);
    ClassDB::bind_method(D_METHOD("always_fly_fast"), &GoannaClient::always_fly_fast);
    ClassDB::bind_method(D_METHOD("set_safe_dig", "on"), &GoannaClient::set_safe_dig);
    ClassDB::bind_method(D_METHOD("safe_dig"), &GoannaClient::safe_dig);
    ClassDB::bind_method(D_METHOD("set_repeat_dig_interval", "s"), &GoannaClient::set_repeat_dig_interval);
    ClassDB::bind_method(D_METHOD("repeat_dig_interval"), &GoannaClient::repeat_dig_interval);
    ClassDB::bind_method(D_METHOD("set_repeat_place_interval", "s"), &GoannaClient::set_repeat_place_interval);
    ClassDB::bind_method(D_METHOD("repeat_place_interval"), &GoannaClient::repeat_place_interval);
}

} // namespace goanna
