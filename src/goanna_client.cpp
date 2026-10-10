// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Most of GoannaClient (goanna_client.h): the near meshing pipeline
// (poll_blocks, nearSubmit, nearRebuild, nearPublishBatch), the far field
// and its LOD tiers (update_lod and the lod* methods), materials
// (keyForIrr, materialFor), node animation, node lights and motes, the
// entity hookup, the interface getters GDScript reads (take_*, hud_state,
// inventory_state, sky_state) and _bind_methods. The surface and fine data
// halves of the far field are in goanna_client_surface.cpp and
// goanna_client_fine.cpp.
//
// Every GoannaClient method runs on Godot's main thread. The three mesh job
// types defined here (NearBatchJob, NearBlockJob, LodRegionJob) are the
// exception: their run() executes on a MeshPool worker and must keep to the
// rule in goanna_mesh_pool.h, working only on what was captured when the job
// was made. docs/develop/architecture.md, "Threads and the handoff", and
// "The life of a session" walk through the order things happen in.
//
// This file is due to be split; until then, search for the method name.

#include "goanna_client_internal.h"

using namespace godot;

namespace goanna {

GoannaClient::GoannaClient() {
    if (const char *flame = getenv("GOANNA_FLAME_MATERIAL"))
        m_flame_material = !(flame[0] == '0' && flame[1] == 0);
    // Only live clients own the cache. Packed arrays are released before
    // Godot shuts down, including when the last player disconnects.
    static std::weak_ptr<SharedMeshCache> shared_meshes;
    m_shared_meshes = shared_meshes.lock();
    if (!m_shared_meshes) {
        m_shared_meshes = std::make_shared<SharedMeshCache>(128ull << 20);
        shared_meshes = m_shared_meshes;
    }
    static std::weak_ptr<SharedNearCache> shared;
    m_shared_near = shared.lock();
    if (!m_shared_near) {
        m_shared_near = std::make_shared<SharedNearCache>(128ull << 20);
        shared = m_shared_near;
    }
    const char *grass = std::getenv("GOANNA_GRASS");
    set_meta("goanna_grass_enabled", grass && std::string(grass) == "1");
    const char *ab = std::getenv("GOANNA_AUTO_BUMP");
    if (ab && *ab) {
        m_auto_bump = std::max(0.0f, (float)atof(ab));
        m_auto_bump_pinned = true;
    }
    const char *ts = std::getenv("GOANNA_TEXTURE_SIZE");
    if (ts && *ts) {
        m_texture_size = std::max(0, atoi(ts));
        m_texture_size_pinned = true;
    }
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
    // Legacy carving switch. Zero turns carving
    // off entirely and the dig falls back to the crack overlay alone, which is
    // what makes an A/B shot of the same dig possible.
    const char *cv = std::getenv("GOANNA_CARVE");
    if (cv)
        g_goanna_carve_depth = (float)atof(cv);
    const char *cd = std::getenv("GOANNA_CARVE_DEMO");
    if (cd)
        g_goanna_carve_demo = atoi(cd);
    const char *cz = std::getenv("GOANNA_CARVE_DEMO_Z");
    if (cz)
        g_goanna_carve_demo_z = atoi(cz);
}

int GoannaClient::resident_blocks() { return m_session ? (int)m_session->residentBlocks() : 0; }

void GoannaClient::set_view_range(int blocks) {
    m_view_range = blocks < 1 ? 1 : (blocks > 60 ? 60 : blocks);
    if (m_session)
        m_session->wantedRange = m_view_range;
}
int GoannaClient::view_range() const { return m_session ? m_session->wantedRange : m_view_range; }
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

GoannaClient::~GoannaClient() {
    m_carve_active = false;
    // Before the session and the tile cache go.
    m_lod_storage.stop();
    m_mesh_pool.stop();
    if (m_horizon_thread.joinable())
        m_horizon_thread.join();
}

void GoannaClient::enable_render_scope() {
    if (!m_render_scope && !m_session)
        m_render_scope = std::make_unique<RenderScope>(get_instance_id());
}

Ref<Shader> GoannaClient::load_view_shader(const String &path) {
    return m_render_scope ? m_render_scope->load(path)
            : Ref<Shader>(ResourceLoader::get_singleton()->load(path));
}

void GoannaClient::set_view_shader_parameter(const StringName &name, const Variant &value) {
    if (m_render_scope)
        m_render_scope->set(name, value);
    else
        RenderingServer::get_singleton()->global_shader_parameter_set(name, value);
}

String GoannaClient::view_shader_parameter_name(const String &name) const {
    return m_render_scope ? m_render_scope->name(name) : name;
}

String GoannaClient::hello() const {
    return "goanna: extension loaded";
}

String GoannaClient::luanti_version() const {
    return String("luanti core ") + g_version_hash;
}

Dictionary GoannaClient::server_options() const {
    Dictionary d;
    if (!m_session)
        return d;
    for (const auto &kv : m_session->serverOptions())
        d[String(kv.first.c_str())] = String(kv.second.c_str());
    return d;
}

void GoannaClient::set_content_hold(bool on) {
    m_content_hold = on;
    if (m_session)
        m_session->setContentHold(on);
}

void GoannaClient::connect_to(const String &host, int port, const String &player_name,
        const String &password) {
    m_shared_identity.clear();
    m_lod_storage.stop();
    m_lod_loads.clear();
    fineClear();
    m_lod_cached_summaries.clear();
    m_lod_primed_regions.clear();
    m_mesh_pool.stop();
    surfaceClear();
    // Luanti's base texture pack lives in the luanti/ checkout next to project/,
    // or in a release beside the Goanna folder. An exported game cannot
    // globalize res://: it comes back as the relative "../luanti", which
    // resolved against whatever folder the player started Goanna from, so
    // the base textures were found only when that was the program's own.
    String share = OS::get_singleton()->has_feature("template")
            ? OS::get_singleton()->get_executable_path().get_base_dir().path_join("../luanti").simplify_path()
            : ProjectSettings::get_singleton()->globalize_path("res://../luanti");
    GoannaSession::setSharePath(share.utf8().get_data());
    nearClear();
    // Materials retain the outgoing session's texture objects. Texture ids
    // start over for each connection, so keeping this cache makes a later
    // pack reuse shader materials still bound to the first pack's arrays.
    clearMaterials();
    m_fake_liquid_tex.clear();
    m_ice_tex.clear();
    m_clear_glass_tex.clear();
    m_liquid_tex.clear();
    m_lava_tex.clear();
    m_portal_tex.clear();
    m_portal_arrays.clear();
    m_flame_tex.clear();
    m_fake_liquid_built = false;
    // Icon jobs point into the outgoing session's meshes and images.
    m_item_icons.clear();
    m_shared_identity.clear();
    m_session = std::make_unique<GoannaSession>();
    // The camera is created before connect_to(), so _report_fov() normally
    // arrives before the session. Apply the retained cone before the first
    // player-position packet or the server streams only its 70 degree
    // default and cuts vertical wedges from a wide viewport.
    m_session->cameraFov = m_view_fov;
    // Likewise the view range: the settings are applied before the session
    // exists, and the session's own default is 12 whatever the tier said.
    m_session->wantedRange = m_view_range;
    if (m_session->tsrc()) {
        m_session->tsrc()->setInferredReliefStrength(m_auto_bump);
        m_session->tsrc()->setTextureSize((u32)m_texture_size);
    }
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
    m_lod_chain_retry_regions.clear();
    m_lod_handoff_near.clear();
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
    m_session->setContentHold(m_content_hold);
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
    if (const char *env = getenv("GOANNA_MESH_THREADS"); env && m_poll_budget_ms <= 0)
        m_mesh_threads = std::clamp(atoi(env), -1, 16);
    if (m_mesh_threads >= 0)
        m_mesh_pool.start(m_mesh_threads);
}

void GoannaClient::disconnect_from_server() {
    m_carve_active = false;
    m_carve = goanna::FormDig();
    m_carve_pos = v3s16(-32768, -32768, -32768);
    m_lod_storage.stop();
    m_lod_loads.clear();
    fineClear();
    m_lod_cached_summaries.clear();
    m_lod_primed_regions.clear();
    // Jobs hold the session's node definitions, texture source and material
    // table by raw pointer, so no worker may be running when it goes.
    m_mesh_pool.stop();
    m_near_ready.clear();
    m_near_inflight.clear();
    m_near_generation.clear();
    m_block_queued_at.clear();
    nearClear();
    m_item_icons.clear();
    // Animated materials retain raw frame pointers owned by the texture
    // source. The control channel can leave frames running after disconnect.
    clearMaterials();
    m_session.reset();
}

Dictionary GoannaClient::status() const {
    Dictionary d;
    if (!m_session) {
        d["state"] = "none";
        return d;
    }
    d["content_held"] = m_session->contentHeld();
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

// The same Luanti mesher and material factory as the near world, supplied
// exclusively with the server's observations. Never copy the ordinary map:
// its adjacent cells can contain a cave the fortress has not discovered.
Ref<ArrayMesh> GoannaClient::overseer_mesh(const Dictionary &layer, Vector3i block_pos) {
    Ref<ArrayMesh> result;
    if (!m_session || !m_session->contentPrepared() || !layer.has("rect"))
        return result;
    const Dictionary rect = layer["rect"];
    const int x0 = rect.get("x0", 0), x1 = rect.get("x1", -1);
    const int z0 = rect.get("z0", 0), z1 = rect.get("z1", -1);
    const int y = layer.get("y", 0);
    const int width = x1 - x0 + 1, depth = z1 - z0 + 1;
    const Array cells = layer.get("cells", Array()), floors = layer.get("floors", Array());
    const Array palette = layer.get("palette", Array());
    const Array below = layer.get("below", Array());
    if (below.size() > 8) return result;
    std::vector<Array> levels{cells};
    if (below.is_empty()) levels.push_back(floors);
    else for (int d = 0; d < below.size(); ++d) {
        if (below[d].get_type() != Variant::DICTIONARY) return result;
        const Dictionary slice = below[d];
        const Array values = slice.get("cells", Array());
        if (values.size() != cells.size()) return result;
        levels.push_back(values);
    }
    const int bottom = y - (int)levels.size() + 1;
    if (width < 1 || width > 64 || depth < 1 || depth > 64 ||
            cells.size() != width * depth || floors.size() != cells.size() ||
            std::abs(y) > 30999 || std::abs(x0) > 30999 || std::abs(x1) > 30999 ||
            std::abs(z0) > 30999 || std::abs(z1) > 30999 || palette.size() > 8192)
        return result;
    const v3s16 bp(block_pos.x, block_pos.y, block_pos.z);
    if (bp.X < getNodeBlockPos(v3s16(x0, bottom, z0)).X ||
            bp.X > getNodeBlockPos(v3s16(x1, y, z1)).X ||
            bp.Z < getNodeBlockPos(v3s16(x0, bottom, z0)).Z ||
            bp.Z > getNodeBlockPos(v3s16(x1, y, z1)).Z ||
            bp.Y < getNodeBlockPos(v3s16(x0, bottom, z0)).Y ||
            bp.Y > getNodeBlockPos(v3s16(x1, y, z1)).Y)
        return result;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    std::vector<MapNode> nodes{MapNode(CONTENT_AIR), MapNode(CONTENT_AIR)};
    for (int i = 0; i < palette.size(); ++i) {
        const Dictionary entry = palette[i];
        const String name = entry.get("name", "");
        const content_t id = m_session->nodeDefs()->getId(name.utf8().get_data());
        nodes.emplace_back(id, 0, (u8)(int)entry.get("param2", 0));
    }
    MeshGrid grid{1};
    MeshMakeData data(m_session->nodeDefs(), MAP_BLOCKSIZE, grid);
    data.fillBlockDataBegin(bp);
    auto &vm = data.m_vmanip;
    for (u32 i = 0; i < vm.m_area.getVolume(); ++i) {
        vm.m_data[i] = MapNode(CONTENT_AIR);
        vm.m_flags[i] = 0;
    }
    for (int z = z0; z <= z1; ++z) {
        for (int x = x0; x <= x1; ++x) {
            const int i = (z - z0) * width + x - x0;
            bool supplied = true;
            for (int d = 0; d < (int)levels.size(); ++d) {
                const int c = levels[d][i];
                if (c < 0 || c >= (int)nodes.size()) return result;
                supplied = supplied && c > 0;
                const v3s16 at(x, y - d, z);
                if (supplied && vm.m_area.contains(at))
                    vm.m_data[vm.m_area.index(at)] = nodes[c];
            }
        }
    }
    // Separate known shaft walls can sit beneath a capped solid column.
    // Never gather their geometry from the ordinary client's map cache.
    for (int d = 0; d < below.size(); ++d) {
        const Dictionary slice = below[d];
        const Array walls = slice.get("walls", Array());
        if (walls.is_empty()) continue;
        if (walls.size() != cells.size()) return result;
        for (int i = 0; i < walls.size(); ++i) {
            const int code = walls[i];
            if (code == 0) continue;
            if (code < 2 || code >= (int)nodes.size()) return result;
            const v3s16 at(x0 + i % width, y - d - 1, z0 + i / width);
            if (vm.m_area.contains(at)) vm.m_data[vm.m_area.index(at)] = nodes[code];
        }
    }
    struct Plant { v3s16 pos; MapNode node; };
    std::vector<Plant> plants;
    for (int z = z0; z <= z1; ++z) for (int x = x0; x <= x1; ++x)
        for (int py = bottom; py <= y; ++py) {
            const v3s16 at(x, py, z);
            if (!vm.m_area.contains(at)) continue;
            const MapNode n = vm.m_data[vm.m_area.index(at)];
            if (m_session->nodeDefs()->get(n).drawtype != NDT_PLANTLIKE) continue;
            if (getNodeBlockPos(at) == bp) plants.push_back({at, n});
            vm.m_data[vm.m_area.index(at)] = MapNode(CONTENT_AIR);
        }
    // No gatherMeshData/meshGathered: those also read live map/carve state.
    MapBlockMesh built(m_session->meshClient(), &data);
    buildFakeLiquidTextures();
    std::map<uint64_t, NearSurface> groups;
    struct Vertex {
        Vector3 p, n;
        Vector2 uv, uv2;
        Color c;
        Vertex mix(const Vertex &b, float t) const {
            return {p.lerp(b.p, t), n.lerp(b.n, t), uv.lerp(b.uv, t),
                    uv2.lerp(b.uv2, t), c.lerp(b.c, t)};
        }
    };
    const Vector3 lo(x0 - 0.5f, bottom - 0.5f, -z1 - 0.5f);
    const Vector3 hi(x1 + 0.5f, y + 0.5f, -z0 + 0.5f);
    for (int tile_layer = 0; tile_layer < MAX_TILE_LAYERS; ++tile_layer) {
        scene::IMesh *mesh = built.getMesh(tile_layer);
        if (!mesh) continue;
        for (u32 b = 0; b < mesh->getMeshBufferCount(); ++b) {
            scene::IMeshBuffer *buf = mesh->getMeshBuffer(b);
            if (!buf || buf->getVertexType() != video::EVT_STANDARD || !buf->getVertexCount()) continue;
            const auto *v = (const video::S3DVertex *)buf->getVertices();
            const auto *indices = (const u16 *)buf->getIndices();
            u16 base = 0;
            MaterialKey key = keyForIrr(buf->getMaterial(), v[0].Aux & GOANNA_VERTEX_TEXTURE_MASK, &base);
            auto *source = dynamic_cast<GoannaTexture *>(buf->getMaterial().getTexture(0));
            auto *array = key.array_texture ? m_session->tsrc()->goannaTexture(key.texture_id) : nullptr;
            for (u32 t = 0; t + 2 < buf->getIndexCount(); t += 3) {
                MaterialKey own = key;
                const u16 tex_layer = (v[indices[t]].Aux & GOANNA_VERTEX_TEXTURE_MASK) + base;
                if (array) {
                    own = arrayTileKey(key, array, tex_layer);
                    const u32 special = specialLayer(array, tex_layer);
                    if (special) { own.array_texture = false; own.texture_id = special; }
                } else if (source && source->isArray() && tex_layer < source->layerNames().size()) {
                    own.texture_id = m_session->tsrc()->getTextureId(source->layerNames()[tex_layer]);
                }
                std::vector<Vertex> polygon;
                for (int k = 0; k < 3; ++k) {
                    const auto &a = v[indices[t + k]];
                    polygon.push_back({Vector3(a.Pos.X / BS + bp.X * MAP_BLOCKSIZE,
                            a.Pos.Y / BS + bp.Y * MAP_BLOCKSIZE, -(a.Pos.Z / BS + bp.Z * MAP_BLOCKSIZE)),
                            Vector3(a.Normal.X, a.Normal.Y, -a.Normal.Z),
                            Vector2(a.TCoords.X, a.TCoords.Y),
                            Vector2(own.array_texture ? (a.Aux & GOANNA_VERTEX_TEXTURE_MASK) + base : 0, 0),
                            Color(a.Color.getRed() / 255.f, a.Color.getGreen() / 255.f,
                                    a.Color.getBlue() / 255.f, a.Color.getAlpha() / 255.f)});
                }
                // Clip genuine triangles, including nodeboxes and mesh nodes
                // that extend beyond their cell, to the selected slice.
                for (int axis = 0; axis < 3; ++axis) {
                    for (int side = 0; side < 2 && !polygon.empty(); ++side) {
                        std::vector<Vertex> clipped;
                        const float bound = side ? hi[axis] : lo[axis];
                        auto distance = [&](const Vertex &a) { return side ? bound - a.p[axis] : a.p[axis] - bound; };
                        Vertex a = polygon.back();
                        float da = distance(a);
                        for (const Vertex &b : polygon) {
                            const float db = distance(b);
                            if ((da >= 0) != (db >= 0)) clipped.push_back(a.mix(b, da / (da - db)));
                            if (db >= 0) clipped.push_back(b);
                            a = b; da = db;
                        }
                        polygon = std::move(clipped);
                    }
                }
                if (polygon.size() < 3) continue;
                NearSurface &acc = groups[own.hash()];
                acc.key = own;
                const int offset = acc.verts.size();
                for (const auto &a : polygon) {
                    acc.verts.push_back(a.p); acc.norms.push_back(a.n.normalized());
                    acc.uvs.push_back(a.uv); acc.uv2s.push_back(a.uv2); acc.cols.push_back(a.c);
                    // Neutral light attributes; the isolated scene supplies
                    // lighting, never the hidden map's light/occlusion field.
                    acc.custom0.push_back(0); acc.custom0.push_back(255);
                    acc.custom0.push_back(255); acc.custom0.push_back(255);
                }
                for (int k = 1; k + 1 < (int)polygon.size(); ++k) {
                    acc.idx.push_back(offset); acc.idx.push_back(offset + k); acc.idx.push_back(offset + k + 1);
                }
            }
        }
    }
    for (const Plant &plant : plants) {
        const auto &f = m_session->nodeDefs()->get(plant.node);
        if (!f.visuals) continue;
        // Keep the real node's texture, animation and colour. Only crossed
        // plantlike cards are flattened; modelled plants keep their mesh.
        for (int layer_index = 0; layer_index < MAX_TILE_LAYERS; ++layer_index) {
            const TileLayer &tile = f.visuals->tiles[0].layers[layer_index];
            if (tile.empty()) continue;
            video::SMaterial material;
            material.MaterialType = m_session->shsrc().getShaderInfo(tile.shader_id).material;
            tile.applyMaterialOptions(material, layer_index);
            material.setTexture(0, tile.texture);
            MaterialKey key = keyForIrr(material, tile.texture_layer_idx);
            key.backface_culling = false;
            NearSurface &acc = groups[key.hash()];
            acc.key = key;
            const auto tint = tile.has_color ? tile.color : f.visuals->getColor(f, plant.node.param2);
            const Color colour(tint.getRed()/255.f, tint.getGreen()/255.f, tint.getBlue()/255.f, 1);
            const float half = std::min(0.5f, 0.5f * f.visual_scale);
            const Vector3 centre(plant.pos.X, plant.pos.Y + 0.05f + layer_index * 0.002f, -plant.pos.Z);
            const int offset = acc.verts.size();
            for (const Vector2 uv : {Vector2(0,0), Vector2(1,0), Vector2(1,1), Vector2(0,1)}) {
                acc.verts.push_back(centre + Vector3((uv.x-.5f)*2*half, 0, (uv.y-.5f)*2*half));
                acc.norms.push_back(Vector3(0,1,0)); acc.uvs.push_back(uv);
                acc.uv2s.push_back(Vector2(key.array_texture ? tile.texture_layer_idx : 0, 0));
                acc.cols.push_back(colour);
                acc.custom0.push_back(0); acc.custom0.push_back(255);
                acc.custom0.push_back(255); acc.custom0.push_back(255);
            }
            for (int i : {0,1,2,0,2,3}) acc.idx.push_back(offset+i);
        }
    }
    result.instantiate();
    for (auto &entry : groups) {
        auto &acc = entry.second;
        Array arrays;
        arrays.resize(Mesh::ARRAY_MAX);
        arrays[Mesh::ARRAY_VERTEX] = acc.verts; arrays[Mesh::ARRAY_NORMAL] = acc.norms;
        arrays[Mesh::ARRAY_TANGENT] = node_tangents(acc.verts, acc.norms, acc.uvs, acc.idx);
        arrays[Mesh::ARRAY_TEX_UV] = acc.uvs; arrays[Mesh::ARRAY_TEX_UV2] = acc.uv2s;
        arrays[Mesh::ARRAY_COLOR] = acc.cols; arrays[Mesh::ARRAY_CUSTOM0] = acc.custom0;
        arrays[Mesh::ARRAY_INDEX] = acc.idx;
        uint64_t flags = kNodeSurfaceFlags;
        if (m_lava_tex.count(acc.key.texture_id)) {
            prepareLavaSurface(arrays, *m_session, &vm);
            flags |= uint64_t(Mesh::ARRAY_CUSTOM_RGB_FLOAT) << Mesh::ARRAY_FORMAT_CUSTOM1_SHIFT;
        }
        result->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, Array(), Dictionary(), flags);
        result->surface_set_material(result->get_surface_count() - 1, materialFor(acc.key));
    }
    return result;
}

void GoannaClient::overseer_entities(Node3D *parent, const Dictionary &layer) {
    ensureEntityRenderer();
    m_entities->setOverseer(parent, layer);
}

bool GoannaClient::overseer_channel(const String &channel) {
    return m_session && m_session->setOverseerChannel(channel.utf8().get_data());
}

void GoannaClient::overseer_send(const String &message) {
    if (m_session) m_session->sendOverseer(message.utf8().get_data());
}

Array GoannaClient::overseer_take() {
    Array out;
    if (m_session)
        for (const auto &message : m_session->takeOverseer())
            out.push_back(String::utf8(message.c_str()));
    return out;
}

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
        h["hideable"] = e.hideable;
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

// What to hand item_icon() for this stack: its name, or, when its metadata
// can change the picture (the colour and palette index keys drawItemStack
// reads, and the inventory image and overlay keys ItemStack reads), the item
// string with that metadata, so tinted candles and the like are told apart.
// Count and wear never change an icon and are left out.
static String iconItemString(const ItemStack &st) {
    const ItemStackMetadata &m = st.metadata;
    if (m.getString("color").empty() && m.getString("palette_index").empty() &&
            m.getString("inventory_image").empty() && m.getString("inventory_overlay").empty())
        return String::utf8(st.name.c_str());
    ItemStack one = st;
    one.count = 1;
    one.wear = 0;
    return String::utf8(one.getItemString().c_str());
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
                // The stack's own description when its metadata sets one
                // (a named or enchanted item), as GUIInventoryList's tooltip
                // reads it.
                it["description"] = String::utf8(st.getDescription(idef).c_str());
                it["inventory_image"] = String::utf8(def.inventory_image.name.c_str());
                it["icon_item"] = iconItemString(st);
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

String GoannaClient::item_description(const String &item_string) {
    if (!m_session)
        return String();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    IItemDefManager *idef = m_session->getItemDefManager();
    ItemStack stack;
    stack.deSerialize(item_string.utf8().get_data(), idef);
    if (stack.name.empty())
        return String();
    return String::utf8(stack.getDefinition(idef).description.c_str());
}

Ref<Texture2D> GoannaClient::item_icon(const String &item_name) {
    if (!m_session)
        return Ref<Texture2D>();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    IItemDefManager *idef = m_session->getItemDefManager();
    // A bare name or a whole item string; the metadata of the latter can
    // carry a colour, which the node item icon below honours.
    ItemStack stack;
    try {
        stack.deSerialize(item_name.utf8().get_data(), idef);
    } catch (std::exception &) {
        return Ref<Texture2D>();
    }
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
        // A node item with no inventory image: drawItemStack draws its item
        // mesh, and so does this, whatever its drawtype. Folding tiles into
        // an [inventorycube read a mesh node's texture atlas as cube faces
        // (Mineclonia's chest came out as a see-through box), took a faced
        // node's side where upstream shows its front, and lost overlay tiles
        // and colours; a plain cube drawn both ways differs too (the mesh is
        // drawn smaller, with its own shading), which is why cubes come this
        // way as well.
        return m_item_icons.icon(*m_session, stack);
    }
    u32 id = m_session->tsrc()->getTextureId(tex);
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(id);
    if (!gt)
        return Ref<Texture2D>();
    return gt->godotTexture();
}

void GoannaClient::flush_item_icons() {
    m_item_icons.flush();
}

Dictionary GoannaClient::item_icon_stats() const {
    return m_item_icons.stats();
}

void GoannaClient::_on_frame_pre_draw() {
    // Size icons for the slot a formspec lays out on this window, then draw
    // whatever was asked for since the last frame, so a form built this
    // frame is drawn complete.
    const auto t0 = std::chrono::steady_clock::now();
    if (is_inside_tree()) {
        Vector2 vs = get_viewport()->get_visible_rect().size;
        m_item_icons.setSize(goanna::itemIconSizeFor(std::min(vs.x, vs.y)));
    }
    m_item_icons.flush();
    m_item_icons.countFrame(std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count());
}

void GoannaClient::_notification(int p_what) {
    RenderingServer *rs = RenderingServer::get_singleton();
    if (!rs)
        return;
    Callable cb = callable_mp(this, &GoannaClient::_on_frame_pre_draw);
    if (p_what == NOTIFICATION_ENTER_TREE) {
        if (!rs->is_connected("frame_pre_draw", cb))
            rs->connect("frame_pre_draw", cb);
    } else if (p_what == NOTIFICATION_EXIT_TREE) {
        if (rs->is_connected("frame_pre_draw", cb))
            rs->disconnect("frame_pre_draw", cb);
    }
}

String GoannaClient::inventory_formspec() const {
    return m_session ? String::utf8(m_session->inventoryFormspec().c_str()) : String();
}

String GoannaClient::formspec_prepend() const {
    return m_session ? String::utf8(m_session->formspecPrepend().c_str()) : String();
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
        d["kind"] = String::utf8(ev.kind.c_str());
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
        d["normal"] = gv(e.normal);
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

PackedStringArray GoannaClient::announced_media_names() {
    PackedStringArray out;
    if (!m_session)
        return out;
    for (const auto &n : m_session->announcedMediaNames())
        out.push_back(String::utf8(n.c_str()));
    return out;
}

// NodeMetadataFormSource::resolveText for a node's own form: a whole
// "${key}" becomes that key's value in the node's metadata, which is how an
// MTG sign's field shows the sign's current text. `context` is the form's
// "nodemeta:x,y,z" in Luanti coordinates; any other text or context comes
// back unchanged.
String GoannaClient::resolve_nodemeta_text(const String &context, const String &text) {
    if (!m_session || !context.begins_with("nodemeta:"))
        return text;
    PackedStringArray p = context.substr(9).split(",");
    if (p.size() != 3)
        return text;
    v3s16 np((s16)p[0].to_int(), (s16)p[1].to_int(), (s16)p[2].to_int());
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    NodeMetadata *meta = m_session->map().getNodeMetadata(np);
    if (!meta)
        return text;
    return String::utf8(meta->resolveString(text.utf8().get_data()).c_str());
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
    int near_dirty = 0, near_building = 0;
    int occluder_regions = 0, occluder_triangles = 0;
    for (const auto &kv : m_near_regions) {
        near_surfaces += kv.second.surfaces;
        near_dirty += kv.second.dirty;
        near_building += kv.second.building;
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
    d["near_regions_dirty"] = near_dirty;
    d["near_regions_building"] = near_building;
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
    int active_lights = 0, shadow_lights = 0;
    for (const auto *light : m_light_pool) {
        if (!light->is_visible()) continue;
        ++active_lights;
        if (light->has_shadow()) ++shadow_lights;
    }
    d["active_lights"] = active_lights;
    d["shadow_lights"] = shadow_lights;
    d["light_churn"] = m_light_churn;
    d["mote_pool"] = (int)m_mote_pool.size();
    // Far tiers: how many blocks each tier draws, how many region meshes,
    // and what the merge achieved. The per tier readout docs/systems/far-rendering.md
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
    const auto storage = m_lod_storage.stats();
    d["lod_storage_hits"] = (int64_t)storage.hits;
    d["lod_storage_misses"] = (int64_t)storage.misses;
    d["lod_summary_cache_hits"] = (int64_t)storage.summary_hits;
    d["lod_summary_cache_writes"] = (int64_t)storage.summary_writes;
    d["lod_storage_built"] = (int64_t)storage.built;
    d["lod_storage_errors"] = (int64_t)storage.errors;
    d["lod_storage_rejected"] = (int64_t)storage.rejected;
    d["lod_storage_queued"] = storage.queued;
    d["lod_storage_ready"] = storage.ready;
    d["lod_storage_active"] = storage.active;
    d["lod_storage_pending"] = (int64_t)m_lod_loads.size();
    d["fine_candidates"] = (int64_t)m_fine_states.size();
    d["fine_pending"]=(int64_t)m_fine_pending.size();
    // Last completed bounded sweep, rather than another whole-world walk
    // every time the HUD or recorder asks for statistics.
    d["fine_ready"]=m_fine_ready_sample;
    d["fine_scan_ms"]=m_ms_fine_scan;
    d["fine_scan_entries"]=m_fine_scan_entries;
    d["near_ready"]=(int64_t)m_near_ready.size();
    d["surface_waiting"]=(int64_t)m_surface_waiting.size();
    d["lod_storage_retry_regions"] = (int64_t)m_lod_chain_retry_regions.size();
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
    d["shared_lod_hits_process"] = (int64_t)sharedLodHits();
    d["lamp_occlusion_ms"] = m_ms_lamp_occlusion;
    d["shared_upload_hits"] = (int64_t)m_shared_upload_hits;
    d["shared_near_hits"] = (int64_t)m_shared_near_hits;
    d["shared_near_builds"] = (int64_t)m_shared_near_misses;
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
    d["surface_offered"] = surfaceOffered();
    d["surface_tiles"] = (int)m_surface_tiles.size();
    d["surface_received"] = m_surface_received;
    d["surface_wanted"] = m_surface_wanted;
    d["surface_inflight"] = (int)m_surface_pending.size();
    d["surface_reach"] = m_surface_published ? m_surface_reach : 0;
    d["surface_cells"] = m_surface_cells;
    d["surface_covered"] = m_surface_covered;
    d["surface_quads"] = m_surface_quads;
    d["surface_forest_quads"] = m_surface_forest_quads;
    d["surface_forest_columns"] = m_surface_forest_columns;
    d["surface_uploads"] = (int)m_surface_uploads.size();
    d["surface_retired"] = (int)m_surface_retired.size();
    d["surface_building"] = m_surface_building;
    d["surface_first_ms"] = m_surface_first_ms;
    d["surface_overview_ms"] = m_surface_overview_ms;
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

void GoannaClient::_bind_methods() {
    ClassDB::bind_method(D_METHOD("enable_render_scope"), &GoannaClient::enable_render_scope);
    ClassDB::bind_method(D_METHOD("load_view_shader", "path"), &GoannaClient::load_view_shader);
    ClassDB::bind_method(D_METHOD("set_view_shader_parameter", "name", "value"), &GoannaClient::set_view_shader_parameter);
    ClassDB::bind_method(D_METHOD("view_shader_parameter_name", "name"), &GoannaClient::view_shader_parameter_name);
    ClassDB::bind_method(D_METHOD("set_poll_budget_ms", "budget"), &GoannaClient::set_poll_budget_ms);
    ClassDB::bind_method(D_METHOD("hello"), &GoannaClient::hello);
    ClassDB::bind_method(D_METHOD("luanti_version"), &GoannaClient::luanti_version);
    ClassDB::bind_method(D_METHOD("set_material_strength", "channel", "value"), &GoannaClient::set_material_strength);
    ClassDB::bind_method(D_METHOD("material_strength", "channel"), &GoannaClient::material_strength);
    ClassDB::bind_method(D_METHOD("server_options"), &GoannaClient::server_options);
    ClassDB::bind_method(D_METHOD("set_solid_ice", "on"), &GoannaClient::set_solid_ice);
    ClassDB::bind_method(D_METHOD("solid_ice"), &GoannaClient::solid_ice);
    ClassDB::bind_method(D_METHOD("set_flame_material", "on"), &GoannaClient::set_flame_material);
    ClassDB::bind_method(D_METHOD("flame_material"), &GoannaClient::flame_material);
    ClassDB::bind_method(D_METHOD("set_texture_map", "csv"), &GoannaClient::set_texture_map);
    ClassDB::bind_method(D_METHOD("set_texture_path", "path"), &GoannaClient::set_texture_path);
    ClassDB::bind_method(D_METHOD("set_content_hold", "on"), &GoannaClient::set_content_hold);
    ClassDB::bind_method(D_METHOD("texture_path"), &GoannaClient::texture_path);
    ClassDB::bind_method(D_METHOD("set_texture_size", "size"), &GoannaClient::set_texture_size);
    ClassDB::bind_method(D_METHOD("texture_size"), &GoannaClient::texture_size);
    ClassDB::bind_method(D_METHOD("texture_size_applied"), &GoannaClient::texture_size_applied);
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
    ClassDB::bind_method(D_METHOD("announced_media_names"), &GoannaClient::announced_media_names);
    ClassDB::bind_method(D_METHOD("take_particle_spawners"), &GoannaClient::take_particle_spawners);
    ClassDB::bind_method(D_METHOD("take_deleted_spawners"), &GoannaClient::take_deleted_spawners);
    ClassDB::bind_method(D_METHOD("take_dug_nodes"), &GoannaClient::take_dug_nodes);
    ClassDB::bind_method(D_METHOD("take_particles"), &GoannaClient::take_particles);
    ClassDB::bind_method(D_METHOD("node_name_at", "pos"), &GoannaClient::node_name_at);
    ClassDB::bind_method(D_METHOD("top_surface_at", "pos"), &GoannaClient::top_surface_at);
    ClassDB::bind_method(D_METHOD("resolve_nodemeta_text", "context", "text"),
            &GoannaClient::resolve_nodemeta_text);
    ClassDB::bind_method(D_METHOD("ground_albedo", "center"), &GoannaClient::ground_albedo);
    ClassDB::bind_method(D_METHOD("ground_height", "center"), &GoannaClient::ground_height);
    ClassDB::bind_method(D_METHOD("rain_cover_rows", "x0", "z0", "width", "rows", "y_top", "y_bottom"),
            &GoannaClient::rain_cover_rows);
    ClassDB::bind_method(D_METHOD("node_sound", "node_name", "kind"), &GoannaClient::node_sound);
    ClassDB::bind_method(D_METHOD("sky_state"), &GoannaClient::sky_state);
    ClassDB::bind_method(D_METHOD("horizon_bake_request", "origin", "r0", "r1"),
            &GoannaClient::horizon_bake_request);
    ClassDB::bind_method(D_METHOD("horizon_bake_poll"), &GoannaClient::horizon_bake_poll);
    ClassDB::bind_method(D_METHOD("perf_worst_take"), &GoannaClient::perf_worst_take);
    ClassDB::bind_method(D_METHOD("update_lights", "around", "max_lights"), &GoannaClient::update_lights);
    ClassDB::bind_method(D_METHOD("set_lamp_occlusion", "enabled"), &GoannaClient::set_lamp_occlusion);
    ClassDB::bind_method(D_METHOD("lamp_occlusion"), &GoannaClient::lamp_occlusion);
    ClassDB::bind_method(D_METHOD("set_shadow_lamps", "n"), &GoannaClient::set_shadow_lamps);
    ClassDB::bind_method(D_METHOD("shadow_lamps"), &GoannaClient::shadow_lamps);
    ClassDB::bind_method(D_METHOD("set_lamp_shadow_distance", "distance"), &GoannaClient::set_lamp_shadow_distance);
    ClassDB::bind_method(D_METHOD("lamp_shadow_distance"), &GoannaClient::lamp_shadow_distance);
    ClassDB::bind_method(D_METHOD("set_light_flicker", "on"), &GoannaClient::set_light_flicker);
    ClassDB::bind_method(D_METHOD("light_flicker"), &GoannaClient::light_flicker);
    ClassDB::bind_method(D_METHOD("set_motes", "density"), &GoannaClient::set_motes);
    ClassDB::bind_method(D_METHOD("motes"), &GoannaClient::motes);
    ClassDB::bind_method(D_METHOD("update_motes", "around", "max_emitters"), &GoannaClient::update_motes);
    ClassDB::bind_method(D_METHOD("sync_entities", "dt"), &GoannaClient::sync_entities);
    ClassDB::bind_method(D_METHOD("step_node_animation", "dt"), &GoannaClient::step_node_animation);
    ClassDB::bind_method(D_METHOD("set_node_animation_time", "seconds"),
            &GoannaClient::set_node_animation_time);
    ClassDB::bind_method(D_METHOD("node_animation"), &GoannaClient::node_animation);
    ClassDB::bind_method(D_METHOD("set_node_animation_enabled", "on"),
            &GoannaClient::set_node_animation_enabled);
    ClassDB::bind_method(D_METHOD("node_animation_enabled"), &GoannaClient::node_animation_enabled);
    ClassDB::bind_method(D_METHOD("take_chat"), &GoannaClient::take_chat);
    ClassDB::bind_method(D_METHOD("send_chat", "message"), &GoannaClient::send_chat);
    ClassDB::bind_method(D_METHOD("hp"), &GoannaClient::hp);
    ClassDB::bind_method(D_METHOD("breath"), &GoannaClient::breath);
    ClassDB::bind_method(D_METHOD("hud_state"), &GoannaClient::hud_state);
    ClassDB::bind_method(D_METHOD("overseer_channel", "channel"), &GoannaClient::overseer_channel);
    ClassDB::bind_method(D_METHOD("overseer_send", "message"), &GoannaClient::overseer_send);
    ClassDB::bind_method(D_METHOD("overseer_take"), &GoannaClient::overseer_take);
    ClassDB::bind_method(D_METHOD("overseer_mesh", "layer", "block_pos"), &GoannaClient::overseer_mesh);
    ClassDB::bind_method(D_METHOD("overseer_entities", "parent", "layer"), &GoannaClient::overseer_entities);
    ClassDB::bind_method(D_METHOD("inventory_state"), &GoannaClient::inventory_state);
    ClassDB::bind_method(D_METHOD("inventory_state_at", "location"), &GoannaClient::inventory_state_at);
    ClassDB::bind_method(D_METHOD("detached_inventory_names"), &GoannaClient::detached_inventory_names);
    ClassDB::bind_method(D_METHOD("respawn"), &GoannaClient::respawn);
    ClassDB::bind_method(D_METHOD("texture", "name"), &GoannaClient::texture);
    ClassDB::bind_method(D_METHOD("item_icon", "item_name"), &GoannaClient::item_icon);
    ClassDB::bind_method(D_METHOD("flush_item_icons"), &GoannaClient::flush_item_icons);
    ClassDB::bind_method(D_METHOD("item_icon_stats"), &GoannaClient::item_icon_stats);
    ClassDB::bind_method(D_METHOD("item_description", "item_string"),
            &GoannaClient::item_description);
    ClassDB::bind_method(D_METHOD("inventory_formspec"), &GoannaClient::inventory_formspec);
    ClassDB::bind_method(D_METHOD("formspec_prepend"), &GoannaClient::formspec_prepend);
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
    ClassDB::bind_method(D_METHOD("take_stroke_events"), &GoannaClient::take_stroke_events);
    ClassDB::bind_method(D_METHOD("entity_animation", "id"), &GoannaClient::entity_animation);
    ClassDB::bind_method(D_METHOD("entity_anchor", "id"), &GoannaClient::entity_anchor);
    ClassDB::bind_method(D_METHOD("render_stats"), &GoannaClient::render_stats);
    ClassDB::bind_method(D_METHOD("set_show_body", "show"), &GoannaClient::set_show_body);
    ClassDB::bind_method(D_METHOD("set_view_offset", "offset"), &GoannaClient::set_view_offset);
    ClassDB::bind_method(D_METHOD("set_third_person", "on"), &GoannaClient::set_third_person);
    ClassDB::bind_method(D_METHOD("node_walkable_at", "pos"), &GoannaClient::node_walkable_at);
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
    ClassDB::bind_method(D_METHOD("set_procedural_grass", "enabled"), &GoannaClient::set_procedural_grass);
    ClassDB::bind_method(D_METHOD("procedural_grass"), &GoannaClient::procedural_grass);
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
