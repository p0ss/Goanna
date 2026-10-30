// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// GoannaClient (goanna_client.h): making and destroying it, the connection
// (connect_to, disconnect_from_server, status), the plain settings GDScript
// sets, the render scope, render_stats and perf_worst_take, and
// _bind_methods, which registers every method GDScript can call. The rest of
// the class is in one file per area:
//
//   goanna_client_near.cpp       near meshing: poll_blocks, regional batches
//   goanna_client_jobs.cpp       the mesh jobs, submitting and collecting them
//   goanna_client_lod.cpp        far tiers and regions: update_lod, publishing
//   goanna_client_far.cpp        stored blocks, server summaries, the horizon
//   goanna_client_surface.cpp    baked surface tiles
//   goanna_client_fine.cpp       fine node data
//   goanna_client_materials.cpp  materials, textures and node animation
//   goanna_client_light.cpp      node lights, motes and the sky
//   goanna_client_player.cpp     the player, entities and map queries
//   goanna_client_interface.cpp  chat, HUD, inventory, forms, sounds, overseer
//
// goanna_client_internal.h holds the includes and helpers they share.
//
// Threads: every GoannaClient method runs on Godot's main thread. The
// exceptions are the mesh jobs' run() in goanna_client_jobs.cpp, which
// executes on a MeshPool worker, and the horizon bake thread started in
// goanna_client_far.cpp. docs/develop/architecture.md, "Threads and the
// handoff", and "The life of a session" walk through the order things
// happen in.

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
        m_session->wantedRange.store(m_view_range, std::memory_order_relaxed);
}
int GoannaClient::view_range() const { return m_session ? m_session->wantedRange.load(std::memory_order_relaxed) : m_view_range; }
// The camera's enclosing circular field of view, in degrees. Not the vertical
// angle Godot's Camera3D carries: the server culls against a circular cone, so
// it has to reach the window corners. main.gd works it out because the
// viewport's shape is not visible here. See writePlayerPosTo for the wire.
void GoannaClient::set_view_fov(float degrees) {
    m_view_fov = std::clamp(degrees, 1.0f, 179.0f);
    if (m_session)
        m_session->cameraFov.store(m_view_fov, std::memory_order_relaxed);
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
    if (m_climate_thread.joinable())
        m_climate_thread.join();
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
    m_mesh_pool.stop(); // the outgoing session owns what any job is reading
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
    m_session = std::make_unique<GoannaSession>();
    m_session->setMediaCacheRoot(std::string(OS::get_singleton()->get_user_data_dir()
            .path_join("cache/media").utf8().get_data()));
    // The camera is created before connect_to(), so _report_fov() normally
    // arrives before the session. Apply the retained cone before the first
    // player-position packet or the server streams only its 70 degree
    // default and cuts vertical wedges from a wide viewport.
    m_session->cameraFov.store(m_view_fov, std::memory_order_relaxed);
    // Likewise the view range: the settings are applied before the session
    // exists, and the session's own default is 12 whatever the tier said.
    m_session->wantedRange.store(m_view_range, std::memory_order_relaxed);
    if (m_session->tsrc()) {
        m_session->tsrc()->setInferredReliefStrength(m_auto_bump);
        m_session->tsrc()->setTextureSize((u32)m_texture_size);
    }
    if (!m_store_root.is_empty())
        m_session->setStoreRoot(std::string(m_store_root.utf8().get_data()));
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
    d["media_cached"] = (int)s.media_cached;
    d["media_downloaded"] = (int)s.media_downloaded;
    d["media_cache_checked"] = s.media_cache_checked;
    d["preparation_stage"] = String::utf8(s.preparation_stage.c_str());
    d["preparation_done"] = (int64_t)s.preparation_done;
    d["preparation_total"] = (int64_t)s.preparation_total;
    d["materials"] = m_materials.size();
    d["camera_fov"] = m_session->cameraFov.load(std::memory_order_relaxed);
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
    d["material_warm_complete"] = m_material_warm_node > 0xffff;
    d["lod_material_cold_builds"] = (int64_t)m_lod_material_cold_builds;
    d["lod_liquid_materials"] = (int64_t)m_lod_water.size();
    d["lod_surfaces_uploaded"] = (int64_t)m_lod_surfaces_uploaded;
    d["lod_uploads_cancelled"] = (int64_t)m_lod_uploads_cancelled;
    int uploading = 0;
    for (const auto &entry : m_lod_regions)
        if (entry.second.upload_mesh.is_valid()) ++uploading;
    d["lod_uploading"] = uploading;
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
    d["light_hue_ms"] = m_ms_light_hue;
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
    d["far_dark_air"] = (int)m_lod_dark_air.size();
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
    d["far_summaries_reused"] = (int64_t)m_far_summaries_reused;
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
    ClassDB::bind_method(D_METHOD("set_soft_texture_filtering", "enabled"), &GoannaClient::set_soft_texture_filtering);
    ClassDB::bind_method(D_METHOD("soft_texture_filtering"), &GoannaClient::soft_texture_filtering);
    ClassDB::bind_method(D_METHOD("server_options"), &GoannaClient::server_options);
    ClassDB::bind_method(D_METHOD("set_solid_ice", "on"), &GoannaClient::set_solid_ice);
    ClassDB::bind_method(D_METHOD("solid_ice"), &GoannaClient::solid_ice);
    ClassDB::bind_method(D_METHOD("set_flame_material", "on"), &GoannaClient::set_flame_material);
    ClassDB::bind_method(D_METHOD("set_iris_gbuffers", "gbuffers"), &GoannaClient::set_iris_gbuffers);
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
    ClassDB::bind_method(D_METHOD("lod_uploads"), &GoannaClient::lod_uploads);
    ClassDB::bind_method(D_METHOD("material_diagnostics", "texture_name"),
            &GoannaClient::material_diagnostics, DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("set_player_pose", "pos", "pitch_deg", "yaw_deg"),
            &GoannaClient::set_player_pose);
    ClassDB::bind_method(D_METHOD("server_player_position"), &GoannaClient::server_player_position);
    ClassDB::bind_method(D_METHOD("step_player", "dt", "keys", "pitch_deg", "yaw_deg"), &GoannaClient::step_player);
    ClassDB::bind_method(D_METHOD("toggle_free_move"), &GoannaClient::toggle_free_move);
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
    ClassDB::bind_method(D_METHOD("shader_pack_light_at", "pos"), &GoannaClient::shader_pack_light_at);
    ClassDB::bind_method(D_METHOD("top_surface_at", "pos"), &GoannaClient::top_surface_at);
    ClassDB::bind_method(D_METHOD("resolve_nodemeta_text", "context", "text"),
            &GoannaClient::resolve_nodemeta_text);
    ClassDB::bind_method(D_METHOD("ground_albedo", "center"), &GoannaClient::ground_albedo);
    ClassDB::bind_method(D_METHOD("ground_dust", "center", "wide"), &GoannaClient::ground_dust);
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
    ClassDB::bind_method(D_METHOD("set_light_colour", "enabled"), &GoannaClient::set_light_colour);
    ClassDB::bind_method(D_METHOD("light_colour"), &GoannaClient::light_colour);
    ClassDB::bind_method(D_METHOD("set_light_colour_fill", "fill"), &GoannaClient::set_light_colour_fill);
    ClassDB::bind_method(D_METHOD("light_colour_fill"), &GoannaClient::light_colour_fill);
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
    ClassDB::bind_method(D_METHOD("climate_inject", "message"), &GoannaClient::climate_inject);
    ClassDB::bind_method(D_METHOD("climate_stats"), &GoannaClient::climate_stats);
    ClassDB::bind_method(D_METHOD("climate_at", "world"), &GoannaClient::climate_at);
    ClassDB::bind_method(D_METHOD("set_climate_enabled", "enabled"), &GoannaClient::set_climate_enabled);
    ClassDB::bind_method(D_METHOD("climate_enabled"), &GoannaClient::climate_enabled);
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
