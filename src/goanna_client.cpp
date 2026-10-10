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

bool GoannaClient::procedural_grass() const {
    return get_meta("goanna_grass_enabled", false);
}

bool GoannaClient::grassSubmerged(int x, float root_boundary, int z, bool live) const {
    const int y = (int)std::floor(root_boundary + 0.0001f);
    if (x < -32768 || x > 32767 || y < -32768 || y > 32767 || z < -32768 || z > 32767)
        return false;
    const v3s16 pos(x, y, z);
    if (live && m_session && m_session->nodeDefs()) {
        const MapNode node = m_session->map().getNode(pos);
        if (node.getContent() != CONTENT_IGNORE)
            return m_session->nodeDefs()->get(node).isLiquid();
    }
    const v3s16 bp = getNodeBlockPos(pos);
    auto it = m_lod_chains.find(bp);
    if (it == m_lod_chains.end()) return false;
    const int lx = x - bp.X * MAP_BLOCKSIZE;
    const int ly = y - bp.Y * MAP_BLOCKSIZE;
    const int lz = z - bp.Z * MAP_BLOCKSIZE;
    for (int cell = 1; cell <= MAP_BLOCKSIZE; cell *= 2) {
        const auto *c = it->second->cellAt(cell, lx/cell, ly/cell, lz/cell);
        if (!c) continue;
        const float top = bp.Y * MAP_BLOCKSIZE + (ly/cell)*cell +
                (c->liquid_top ? c->liquid_top : cell);
        return (c->flags & LodLevel::kLiquid) && top > root_boundary + 0.0001f;
    }
    return false;
}

void GoannaClient::set_procedural_grass(bool enabled) {
    if (enabled == procedural_grass()) return;
    set_meta("goanna_grass_enabled", enabled);
    std::unique_lock<std::mutex> map_lock;
    if (enabled && m_session) map_lock = std::unique_lock<std::mutex>(m_session->mapLock());
    // Terrain mesh uploads are main-thread operations. Update the published
    // meshes directly; future near/LOD/baked uploads read the same switch.
    // Removing the surface also removes its rendering cost when switched off.
    for (int i = 0; i < get_child_count(); ++i) {
        auto *instance = Object::cast_to<MeshInstance3D>(get_child(i));
        if (!instance) continue;
        Ref<ArrayMesh> mesh = instance->get_mesh();
        if (mesh.is_null()) continue;
        // A shared buffer is immutable. A tier change rebuilds this view's
        // region with its grass instead of changing another player's mesh.
        if (mesh->has_meta("goanna_shared_terrain")) continue;
        if (!mesh->has_meta("goanna_grass_lod")) continue;
        for (int s = mesh->get_surface_count() - 1; s >= 0; --s) {
            Ref<Material> material = mesh->surface_get_material(s);
            if (material.is_valid() && material->has_meta("goanna_grass_volume"))
                mesh->surface_remove(s);
        }
        if (enabled) {
            const bool lod = mesh->get_meta("goanna_grass_lod");
            goanna::append_grass(mesh, lod, this, [this, lod](int x, float y, int z) {
                return grassSubmerged(x, y, z, !lod);
            });
        }
    }
    for (auto &entry : m_near_regions)
        nearMarkDirty(entry.second);

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

void GoannaClient::set_auto_bump(float strength) {
    // The environment wins over a saved profile: a run with
    // GOANNA_AUTO_BUMP=0 had the profile's 0.95 put back at start, so an
    // A/B of entities with and without inferred relief compared nothing.
    if (m_auto_bump_pinned)
        return;
    if (strength < 0.0f)
        strength = 0.0f;
    if (strength == m_auto_bump)
        return;
    m_auto_bump = strength;
    clearMaterials();
    // Mobs and players infer the same relief; without this the setting only
    // reached an EntityRenderer created after it, so a profile or slider
    // change never reached entities once any had been drawn.
    if (m_entities)
        m_entities->setAutoBump(strength);
    // The array path infers the same relief for layers with no authored _n
    // (docs/design/pbr-plan.md, "Current implementation"), and its
    // companions are cached per texture.
    if (m_session && m_session->tsrc())
        m_session->tsrc()->setInferredReliefStrength(strength);
    // Re-request the loaded blocks so their meshes pick up the new materials.
    if (m_session) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_near_blocks)
            m_session->invalidateBlock(kv.first);
    }
}
void GoannaClient::set_shadow_lamps(int n) {
    m_shadow_lamps = std::max(0, std::min(64, n));
}

// Keep the frosted material in both modes; this only changes transmission.
void GoannaClient::set_solid_ice(bool on) {
    if (on == m_solid_ice)
        return;
    m_solid_ice = on;
    clearMaterials();
    if (m_session) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_near_blocks)
            m_session->invalidateBlock(kv.first);
    }
}
bool GoannaClient::solid_ice() const { return m_solid_ice; }

void GoannaClient::set_flame_material(bool on) {
    if (on == m_flame_material)
        return;
    m_flame_material = on;
    if (m_entities)
        m_entities->setFlameMaterial(on);
    clearMaterials();
    if (m_session) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_near_blocks)
            m_session->invalidateBlock(kv.first);
    }
}

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

// The shader uniform names are the channel names; the defaults here must match
// the shaders' own, because a material built before any slider moves gets
// whatever the shader declares.
static const std::map<std::string, float> kMatStrengthDefaults = {
    {"normal", 1.0f}, {"ao", 1.0f}, {"roughness", 1.0f},
    {"specular", 1.0f}, {"emission", 4.0f}, {"sss", 1.0f},
    // Per vertex node light and occlusion, docs/systems/mesh-attributes.md. Here
    // rather than as fixed uniforms so they can be swept at runtime, which is
    // the only way to A/B them without the world streaming differently between
    // two runs and swamping the difference being measured.
    {"sky_light", 1.0f}, {"vertex_ao", 1.0f}, {"vertex_ao_light", 0.0f},
    // stale is 0: pulling remembered terrain toward grey is a per tier
    // signal painted into the frame, and the far field is judged by there
    // being none (docs/develop/launch-target.md, "one light, one air"). The channel
    // stays so the signal can be turned on to see what is remembered.
    {"sky_fill", 1.0f}, {"stale", 0.0f}, {"debug_nodelight", 0.0f},
    // Per class surface treatment, the stochastic tiling in
    // nodes_array_common.gdshaderinc. It is the one channel here that costs
    // frames rather than only changing a look, which is why it is a slider
    // and not a constant: 0 is the plain single sample.
    {"detail", 1.0f},
    // The parallax march through an authored pack's height
    // (nodes_array.gdshader skips it entirely at 0), and through a mob's
    // (entity_common.gdshaderinc, EntityRenderer::setParallax). The other channel that
    // costs frames: the Lowest graphics profile turns it off, and Low runs
    // the short march (parallax_short below).
    {"parallax", 1.0f},
    // Which march: 0 the full one, 1 the short one for the handheld tiers
    // (nodes_array_common.gdshaderinc, entity_common.gdshaderinc).
    {"parallax_short", 0.0f},
    // Micro shadowing from the pack's occlusion in light()
    // (direct_light.gdshaderinc), on nodes, foliage and mobs. On in every
    // profile: its cost did not show above the noise on the GPU
    // (docs/systems/materials.md, "Micro shadows and the short march"). 0 for an A/B.
    {"micro_shadow", 1.0f},
    // The along the strand highlight on hair texels of a mob or player skin
    // (direct_light.gdshaderinc, EntityRenderer::setHair). 0 draws hair with
    // the isotropic lobe every other texel takes. Off by default until it
    // has been judged on the GPU (docs/perf/hair-aniso-2026-10-02).
    {"hair", 0.0f},
    // Hair drawn by the shader (hair_strands.gdshaderinc,
    // EntityRenderer::setHairShader): strands, ragged lock tips, the shadow
    // under a lock, per strand shine, a wrapped diffuse and the highlight
    // above, on the same hair texels. Off with no profile; the Low profiles
    // keep it off and the others turn it on (graphics_profiles.gd). A pack
    // without the hair mark draws no different either way.
    {"hair_shader", 0.0f},
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
    // Mobs march the same height fields, so they follow the same switch.
    if (k == "parallax" && m_entities)
        m_entities->setParallax(value);
    if (k == "hair" && m_entities)
        m_entities->setHair(value);
    if (k == "hair_shader" && m_entities)
        m_entities->setHairShader(value);
    if ((k == "micro_shadow" || k == "parallax_short") && m_entities)
        m_entities->setChannel(k, value);
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

void GoannaClient::set_content_hold(bool on) {
    m_content_hold = on;
    if (m_session)
        m_session->setContentHold(on);
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

void GoannaClient::set_texture_size(int size) {
    if (m_texture_size_pinned)
        return;
    // The tiers are 128, 256 and 512; anything else snaps to the nearest,
    // and 0 or less is no cap.
    if (size > 0)
        size = size < 192 ? 128 : size < 384 ? 256 : 512;
    else
        size = 0;
    m_texture_size = size;
    // A session whose content is not prepared yet takes it now; one already
    // drawing keeps what it loaded until the next join.
    if (m_session && m_session->tsrc() && !m_session->contentPrepared())
        m_session->tsrc()->setTextureSize((u32)size);
}

int GoannaClient::texture_size_applied() const {
    return m_session && m_session->contentPrepared() && m_session->tsrc()
            ? (int)m_session->tsrc()->textureSize() : 0;
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

Color toColor(const video::SColor &c) {
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
    // The same two buttons as the vanilla client's PlayerControl holds them,
    // which the local player's own dig animation reads.
    p->control.dig = dig;
    p->control.place = place;
    // Tell the server what is held, as a vanilla client does in every
    // position packet: step_player has already put the movement keys, jump,
    // aux1 and sneak into PlayerControl. Goanna sent dig and place alone
    // until 2026-09-29, so a game that picks the walk animation from the
    // keys (Mineclonia's mcl_player does) showed the body standing still
    // while it walked, which the third person camera made plain.
    m_session->setPlayerKeys(p->control.getKeysPressed());
    // From the rendered camera (see set_view_offset); Godot Z is Luanti -Z.
    in.eye_pos_bs = p->getPosition() + p->getEyeOffset()
            + v3f(m_view_offset.x, m_view_offset.y, -m_view_offset.z) * BS;
    // Luanti camera direction from pitch/yaw (Camera::update)
    float pitch = p->getPitch(), yaw = p->getYaw();
    v3f dir(0, 0, 1);
    dir.rotateYZBy(pitch);
    dir.rotateXZBy(yaw);
    in.look_dir = dir.normalize();
    m_session->stepInteract((float)dt, in);
    const auto &st = m_session->interactState();
    const PointedThing &pt = st.pointed;

    // Only contacts advance deformation; animation, sound and debris use the
    // same session clock. Skipped frames coalesce contacts without losing depth.
    if (st.crack_level >= 0 && pt.type == POINTEDTHING_NODE && g_goanna_carve_depth > 0) {
        if (st.crack_pos != m_carve_pos || st.impact_progress < m_carve.applied_progress) {
            m_carve = goanna::FormDig();
            m_carve_pos = st.crack_pos;
            // RESUME FROM THE DAMAGE ALREADY ON THE BLOCK. Starting pristine
            // threw away every earlier blow the moment a dig began: a block
            // left half mined went visibly whole again as soon as it was
            // struck, and only the blows from this dig showed. The stored
            // carve is the truth about the node; this dig continues it.
            m_session->carves().get(m_carve_pos.X, m_carve_pos.Y, m_carve_pos.Z, m_carve.damage);
            // The base shape this dig carves from: a plain cube for an
            // ordinary solid node, or the target's own resolved boxes for a
            // nodebox one. Live neighbour connections are NOT replicated
            // here (that scan lives in drawNodeboxNode); this is an
            // approximation for the PREDICTION only, while digging. The
            // stored carve, once meshed, always uses the true connected
            // shape.
            const MapNode target = m_session->map().getNode(m_carve_pos);
            const ContentFeatures &target_f = m_session->nodeDefs()->get(target);
            if (target_f.drawtype == NDT_NODEBOX) {
                std::vector<aabb3f> boxes;
                target.getNodeBoxes(m_session->nodeDefs(), &boxes, 0);
                std::vector<goanna::FormBox> local_boxes;
                local_boxes.reserve(boxes.size());
                for (const aabb3f &b : boxes) {
                    local_boxes.push_back({b.MinEdge.X / BS, b.MinEdge.Y / BS, b.MinEdge.Z / BS,
                            b.MaxEdge.X / BS, b.MaxEdge.Y / BS, b.MaxEdge.Z / BS});
                }
                m_carve.beginBoxes(local_boxes, 8);
            } else {
                m_carve.beginCube();
            }
        }
        const v3f hit = pt.intersection_point / BS
                - v3f((f32)m_carve_pos.X, (f32)m_carve_pos.Y, (f32)m_carve_pos.Z);
        const float progress = st.impact_progress;
        const v3f normal = pt.intersection_normal;
        if (st.dig_impact && m_carve.advance(progress, hit.X, hit.Y, hit.Z,
                normal.X, normal.Y, normal.Z))
            m_session->invalidateBlock(getNodeBlockPos(m_carve_pos));
        m_carve_active = true;
    } else if (m_carve_active) {
        // The dig is over, by breaking through or by letting go. Tell the
        // server what was carved before dropping it, so the other players keep
        // seeing it; a server without goanna_shared_dig_damage discards this
        // and nothing here depends on an answer.
        //
        // On the END of the dig rather than every step: a carve is reported
        // once, not sixteen times, and the only state worth sharing is the
        // state it was left in.
        const std::string bytes = goanna::encodeForm(m_carve.damage);
        if (!bytes.empty())
            m_session->reportCarve(m_carve_pos, bytes);
        // The same replacement removes both cut geometry and neighbour reveals.
        m_session->invalidateBlock(getNodeBlockPos(m_carve_pos));
        m_carve_active = false;
        m_carve = goanna::FormDig();
        m_carve_pos = v3s16(-32768, -32768, -32768);
    }
    if (pt.type == POINTEDTHING_NODE) {
        d["type"] = "node";
        d["node"] = Vector3(pt.node_undersurface.X, pt.node_undersurface.Y, -pt.node_undersurface.Z);
        d["above"] = Vector3(pt.node_abovesurface.X, pt.node_abovesurface.Y, -pt.node_abovesurface.Z);
        d["point"] = Vector3(pt.intersection_point.X / BS, pt.intersection_point.Y / BS, -pt.intersection_point.Z / BS);
        d["node_name"] = String::utf8(m_session->nodeDefs()->get(m_session->map().getNode(pt.node_undersurface)).name.c_str());
        // Game::handlePointingAtNode shows the node's "infotext" metadata in
        // the top left corner, raw, escapes and all, for the HUD to colour.
        if (NodeMetadata *meta = m_session->map().getNodeMetadata(pt.node_undersurface))
            d["infotext"] = String::utf8(meta->getString("infotext").c_str());
    } else if (pt.type == POINTEDTHING_OBJECT) {
        d["type"] = "object";
        d["object_id"] = (int)pt.object_id;
        auto it = m_session->objects().find(pt.object_id);
        if (it != m_session->objects().end()) {
            d["object_name"] = String::utf8(it->second->name().c_str());
            // Game::handlePointingAtObject: the object's own infotext.
            d["infotext"] = String::utf8(it->second->props().infotext.c_str());
        }
    }
    d["digging"] = st.digging;
    d["dig_impact"] = st.dig_impact;
    d["impact_progress"] = st.impact_progress;
    d["carve_volume"] = m_carve_active ? m_carve.remaining_volume :
            (st.dig_impact && st.impact_progress >= 1 ? 0.0f : 1.0f);
    d["mining_swing"] = (st.digging && st.dig_time_complete < 100000) || st.dig_impact;
    d["swing"] = st.swing;
    d["progress"] = st.dig_time_complete > 0 && st.dig_time_complete < 100000.0f
            ? std::min(1.0f, st.dig_time / st.dig_time_complete) : 0.0f;
    d["crack_level"] = st.crack_level;
    return d;
}

bool GoannaClient::is_underwater(const Vector3 &eye) {
    const bool under = isUnderwaterAt(eye);
    // The water shader drops back faces unless the eye is in the water, and
    // learns where the eye is from this global; main.gd asks every frame.
    set_view_shader_parameter("goanna_eye_underwater", under ? 1.0f : 0.0f);
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

String GoannaClient::node_name_at(const Vector3 &pos) {
    if (!m_session)
        return String();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    v3s16 np((s16)floorf(pos.x + 0.5f), (s16)floorf(pos.y + 0.5f), (s16)floorf(-pos.z + 0.5f));
    MapNode n = m_session->map().getNode(np);
    return String::utf8(m_session->nodeDefs()->get(n).name.c_str());
}

// The shader the near mesh would give the node's top face, by the same
// tests keyForIrr applies (arrayPathTile, the array having built) and the
// one arrayTileKey and materialFor make between the two array shaders: the
// face's own layer decides, not the array. Upstream bunches tiles into
// arrays by size alone, 256 at a time, so on a game with many cut-out
// textures (63 per cent of Mineclonia's 16 pixel ones) every bunch has one,
// and choosing by the array drew all the ground with the scissor shader,
// which has no parallax march. A live check reads this to know which
// shader it is looking at; array_alpha is still reported, because the far
// tiers do choose by the array.
Dictionary GoannaClient::top_surface_at(const Vector3 &pos) {
    Dictionary out;
    if (!m_session)
        return out;
    content_t c;
    {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        v3s16 np((s16)floorf(pos.x + 0.5f), (s16)floorf(pos.y + 0.5f), (s16)floorf(-pos.z + 0.5f));
        c = m_session->map().getNode(np).getContent();
    }
    const ContentFeatures &f = m_session->nodeDefs()->get(c);
    out["node"] = String::utf8(f.name.c_str());
    out["shader"] = "none";
    if (!f.visuals)
        return out;
    // Tile 0 is the top (+Y) face.
    const TileLayer &l = f.visuals->tiles[0].layers[0];
    const bool culled = (l.material_flags & MATERIAL_FLAG_BACKFACE_CULLING) != 0;
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(l.texture_id);
    const bool is_array = gt && gt->isArray();
    const bool array_path = arrayPathTile(l.material_type, culled) &&
            !specialLayer(gt, l.texture_layer_idx);
    out["texture"] = String::utf8(m_session->tsrc()->imageName(l.texture_id, l.texture_layer_idx).c_str());
    out["array"] = is_array;
    out["array_path"] = array_path;
    out["array_alpha"] = is_array && gt->hasAlpha();
    out["layer_alpha"] = is_array && gt->tileHasAlpha(l.texture_layer_idx);
    if (is_array && array_path && m_session->shsrc().usesArrayTexture(l.shader_id)
            && gt->godotArray().is_valid()) {
        MaterialKey k;
        k.texture_id = l.texture_id;
        k.array_texture = true;
        k = arrayTileKey(k, gt, l.texture_layer_idx);
        out["shader"] = gt->hasAlpha() && !k.opaque_tile ? "nodes_array_scissor" : "nodes_array";
    } else
        out["shader"] = "other";
    return out;
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

// The top face of the highest node that would stop rain, per column, for a
// band of `rows` rows of `width` columns starting at Godot (x0, z0), row
// major along x. Each column is scanned from y_top down to y_bottom; one
// with nothing in the way answers y_bottom - 0.5, which reads as open sky
// all the way down to the scan's floor. Unloaded blocks are skipped rather
// than treated as solid, so an edge of the loaded world never shelters
// anything. project/game/effects/rain_cover.gd calls this a band at a time, so one
// call holds the map lock for a few hundred columns and no more.
//
// What stops rain is what a player would see stop it: anything walkable
// (roofs, glass, leaves in every game checked) and liquids, whose surface is
// where rain lands. Plants, torches and other see-through, walk-through
// nodes do not, so rain reaches the ground in a meadow. Presentation only:
// it reads the map the client already holds and asks the server nothing.
PackedFloat32Array GoannaClient::rain_cover_rows(int x0, int z0, int width, int rows,
        int y_top, int y_bottom) {
    PackedFloat32Array out;
    if (width <= 0 || rows <= 0 || y_top < y_bottom)
        return out;
    out.resize(width * rows);
    const float open = (float)y_bottom - 0.5f;
    float *dst = out.ptrw();
    for (int i = 0; i < width * rows; ++i)
        dst[i] = open;
    if (!m_session)
        return out;
    const NodeDefManager *ndef = m_session->nodeDefs();
    // Per content answer, filled as contents turn up: 0 unknown, 1 open,
    // 2 blocks. A band meets a handful of contents, so this is a few lookups.
    std::vector<u8> blocks;
    auto stops_rain = [&](content_t c) -> bool {
        if (c >= blocks.size())
            blocks.resize((size_t)c + 1, 0);
        if (blocks[c] == 0) {
            const ContentFeatures &f = ndef->get(c);
            const bool stop = c != CONTENT_AIR && c != CONTENT_IGNORE
                    && (f.walkable || f.isLiquid()
                        || f.drawtype == NDT_ALLFACES_OPTIONAL);
            blocks[c] = stop ? 2 : 1;
        }
        return blocks[c] == 2;
    };
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    for (int j = 0; j < rows; ++j) {
        // Godot z runs the other way to Luanti's.
        const s16 lz = (s16)(-(z0 + j));
        for (int i = 0; i < width; ++i) {
            const s16 lx = (s16)(x0 + i);
            int y = y_top;
            while (y >= y_bottom) {
                const v3s16 np(lx, (s16)y, lz);
                const v3s16 bp = getNodeBlockPos(np);
                const v3s16 rel = np - bp * MAP_BLOCKSIZE;
                MapBlock *block = m_session->map().getBlockNoCreateNoEx(bp);
                // Walk down to the bottom of this block, or the scan's floor.
                const int stop_y = std::max(y_bottom, (int)bp.Y * MAP_BLOCKSIZE);
                if (!block) {
                    y = stop_y - 1;
                    continue;
                }
                bool found = false;
                for (int ry = rel.Y; y >= stop_y; --ry, --y) {
                    if (stops_rain(block->getNodeNoCheck(rel.X, ry, rel.Z).getContent())) {
                        found = true;
                        break;
                    }
                }
                if (found) {
                    dst[j * width + i] = (float)y + 0.5f;
                    break;
                }
            }
        }
    }
    return out;
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
        pc = f.visuals->getColor(f, s.param2);
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

// How far one movement direction is held, from 0 to 1. A key arrives as a
// bool; a controller stick (project/input/gamepad.gd) arrives as a float, already
// past its deadzone. The type is tested rather than converted, because a
// Variant holding an int or a bool does not convert to double reliably in
// godot-cpp.
static float movementAmount(const Dictionary &keys, const char *name) {
    Variant v = keys.get(name, false);
    float amount = 0.0f;
    switch (v.get_type()) {
    case Variant::BOOL:
        amount = (bool)v ? 1.0f : 0.0f;
        break;
    case Variant::INT:
        amount = (float)(int64_t)v;
        break;
    case Variant::FLOAT:
        amount = (float)(double)v;
        break;
    default:
        break;
    }
    return std::clamp(amount, 0.0f, 1.0f);
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
        // TOCLIENT_MOVE_PLAYER carries the look as well as the position, and
        // the vanilla client turns to it (Client::handleCommand_MovePlayer
        // hands it to the camera). set_look_horizontal and
        // set_look_vertical send nothing else. Until 2026-10-06 Goanna moved
        // and kept the caller's look, so a mod framing a view for the player
        // (DorfCraft's engraving scene) was ignored. The caller takes the
        // new look from "server_look" and keeps it from then on.
        pitch_deg = -spitch;
        yaw_deg = syaw;
        out["server_look"] = Vector2(pitch_deg, yaw_deg);
    }
    // Luanti: pitch positive = looking down; yaw matches Godot after z-mirror.
    PlayerControl &c = p->control;
    // Luanti 5.17 keeps each direction as an analogue amount; keys are 0 or 1
    // and a controller stick anything between, as upstream's getAxisValue
    // feeds PlayerControl.
    c.up = movementAmount(keys, "up");
    c.down = movementAmount(keys, "down");
    c.left = movementAmount(keys, "left");
    c.right = movementAmount(keys, "right");
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
    // leaving them untouched otherwise. Goanna's stick arrives through the
    // direction amounts above, which setMovementFromKeys turns into speed and
    // direction as it does for keys. Goanna also reuses the persistent
    // control, so without this reset the last movement_speed sticks
    // and the player keeps walking after the key is released.
    c.movement_speed = 0.0f;
    c.movement_direction = 0.0f;
    c.setMovementFromKeys();

    if (dt > 0.1) dt = 0.1;
    if (dt > 0)
        m_session->stepPlayer((float)dt);
    if (std::getenv("GOANNA_DEBUG_MANTLE")) {
        static int n = 0;
        if (dt > 0 && (c.getKeysPressed() & 0xf) != 0 && ++n % 20 == 0)
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

MaterialKey arrayTileKey(const MaterialKey &key, const GoannaTexture *array, u16 layer) {
    MaterialKey out = key;
    out.opaque_tile = key.array_texture && !key.crack_overlay && array && array->isArray()
            && array->hasAlpha() && !array->tileHasAlpha(layer);
    return out;
}

Ref<Material> GoannaClient::materialForIrr(const video::SMaterial &m, u16 layer) {
    return materialFor(keyForIrr(m, layer));
}

MaterialKey GoannaClient::keyForIrr(const video::SMaterial &m, u16 layer, u16 *layer_base,
        MaterialKey *crack_overlay) {
    if (layer_base)
        *layer_base = 0;
    MaterialKey key;
    GoannaTexture *gt = dynamic_cast<GoannaTexture *>(m.getTexture(0));
    key.texture_id = gt ? gt->id() : 0;
    // Mining crack: crack tiles carry crack_anylength.png at the crack layer
    // and their stage and tile scale in MaterialTypeParam (packed by
    // MapBlockMesh::animate for the live dig, or baked at mesh time for a
    // stored carve). A stage below zero has not been stamped yet and draws
    // no crack, as in upstream's shader.
    const bool cracked = m.getTexture(MapBlockMesh::TEXTURE_LAYER_CRACK) != nullptr;
    std::pair<int, u8> crack{-1, 1};
    if (gt && cracked)
        crack = MapBlockMesh::unpackCrackMaterialParam(m.MaterialTypeParam);
    key.shader_id = GoannaShaderSource::isShaderMaterial(m.MaterialType)
            ? GoannaShaderSource::shaderIdFromMaterial(m.MaterialType) : 0;
    key.backface_culling = m.BackfaceCulling;
    // The array path covers the common case: an opaque or alpha tested,
    // culled tile. Anything else (a special shader, a double-sided plant)
    // resolves back to its own single image, so it is never sampled as if it
    // were an array. A tile being dug stays on it when the caller can draw
    // the crack as a pass of its own: nothing about the surface under the
    // crack has changed, so it keeps the material its neighbours have, pack
    // companions and all.
    const bool overlay_ok = crack_overlay != nullptr;
    // Waving leaves are backface-culled (they are cube-shaped, unlike waving
    // plants), so culling alone does not rule them out, but
    // nodes_array.gdshader has no wind logic at all: routing them through it
    // silently drops the sway, which is how leaves ended up rendering still.
    // materialFor() below picks the special per-material shader (leaves,
    // plants, glass, water) whenever it is not an array, so arrayPathTile
    // keeps those material types off the array path too.
    const MaterialType mtype = m_session->shsrc().materialType(key.shader_id);
    buildFakeLiquidTextures();
    const bool array_tile = arrayPathTile(mtype, m.BackfaceCulling) &&
            !m_portal_tex.count(key.texture_id);
    // A flame keeps its single image, whose frames are swapped, so that it
    // can take the flame material: Mineclonia's candle and campfire flames
    // are culled mesh tiles, which would otherwise join an animation array.
    auto flameImage = [&](u32 id) {
        if (!m_flame_material)
            return false;
        buildFakeLiquidTextures();
        return m_flame_tex.count(id) > 0;
    };
    if (gt && gt->isArray()) {
        // Only commit to the array path if the Godot array actually built:
        // otherwise the key would name a texture with no 2D image behind it
        // and the tile would render untextured white.
        bool array_ready = array_tile && (!cracked || overlay_ok) &&
                m_session->shsrc().usesArrayTexture(key.shader_id) &&
                gt->godotArray().is_valid();
        if (array_ready) {
            key.array_texture = true;
        } else {
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
    } else if (gt && layer_base && (!cracked || overlay_ok) && array_tile &&
            !flameImage(gt->id())) {
        // An animated tile. Its buffers carry the first frame, a single
        // image, because upstream keeps animated tiles out of its arrays and
        // swaps the texture per frame. Draw it from the animation array
        // holding its frames instead, where the shader picks the frame, so
        // it merges with its neighbours and nothing changes per frame. Only
        // for a caller that takes layer_base: one that cannot move the
        // vertex layer keeps the single image, which animates by swapping.
        const NodeAnimation *anim = m_session->tsrc()->nodeAnimation(gt->id());
        GoannaTexture *agt = anim && anim->array_id
                ? m_session->tsrc()->goannaTexture(anim->array_id) : nullptr;
        if (agt && agt->godotArray().is_valid()) {
            key.texture_id = anim->array_id;
            key.array_texture = true;
            *layer_base = anim->base_layer;
        }
    }
    if (crack.first >= 0 && key.array_texture) {
        // The crack as a second pass over the same triangles, drawn by
        // crack_overlay.gdshader. One material per stage and scale, shared
        // by every cracked tile, except that an alpha tested array's holes
        // have to be cut out of the crack too, which needs that array bound,
        // so those take one per array as well.
        MaterialKey ov;
        ov.crack_overlay = true;
        ov.crack_level = (u8)std::min(crack.first, 255);
        ov.crack_scale = std::max<u8>(crack.second, 1);
        ov.backface_culling = key.backface_culling;
        GoannaTexture *agt = m_session->tsrc()->goannaTexture(key.texture_id);
        ov.texture_id = agt && agt->hasAlpha() ? key.texture_id : 0;
        *crack_overlay = ov;
    } else if (crack.first >= 0) {
        // The fallback, for a cracked tile the array path cannot take: a
        // special shader tile (glass, ice, leaves, plants, liquids), a double
        // sided one, one whose array did not build, or a caller with no
        // second pass. The crack frame is composited over the base through
        // the texture-modifier DSL and the tile takes the single image
        // material, so it loses any pack companions for the dig. An overlay
        // cannot replace this for the special shaders: it knows nothing of
        // a leaf's sway, a pane's refraction or a liquid's surface, so it
        // would not stay on them. The distinct texture id keys a distinct
        // cached material per level.
        //
        // [crack:<tiles>:<frame_count>:<progression>. frame_count is the
        // number of ANIMATION frames in the destination texture, not the
        // number of crack stages: the crack is scaled to one frame's
        // height and blitted into each. Passing the stage count squashed
        // the crack to a fraction of the node's height and repeated it,
        // which read as thin lines and made the early stages invisible.
        // Our per-level composite is a single-frame texture, so pass 1.
        std::string composite = m_session->tsrc()->imageName(gt->id(), layer) +
                "^[crack:" + std::to_string((int)crack.second) + ":1:" +
                std::to_string(crack.first);
        if (getenv("GOANNA_DEBUG_CRACK"))
            UtilityFunctions::print("crack: level ", crack.first, "/",
                    m_session->crackAnimationLength(), " tiles ", (int)crack.second,
                    " -> ", String(composite.c_str()));
        u32 cid = m_session->tsrc()->getTextureId(composite);
        if (cid != 0) {
            key.texture_id = cid;
            key.composited = true; // already a real image; do not resolve again
        }
    }
    if (getenv("GOANNA_DEBUG_CRACK") && cracked) {
        // the FINAL texture this material will use, after every fallback
        UtilityFunctions::print("crack final: ",
                String(m_session->tsrc()->getTextureName(key.texture_id).c_str()),
                " array=", key.array_texture,
                " overlay=", crack.first >= 0 && key.array_texture);
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
// off the water shader. The same scan records ice-group textures, including
// games whose transparent ice uses a glass drawtype, and the resolved visual
// tiles of luminous liquids for the lava shader.
void GoannaClient::buildFakeLiquidTextures() {
    if (m_fake_liquid_built || !m_session)
        return;
    const NodeDefManager *ndef = m_session->nodeDefs();
    if (!ndef)
        return;
    m_fake_liquid_built = true;
    // Textures a liquid shows without glowing. Light alone does not make
    // lava: Asuna's wielded_light swaps water for lit copies of itself, with
    // the same artwork, while a player carries a torch through it. Those
    // copies must not take every lake with them onto the lava shader.
    std::set<u32> calm;
    // NodeDefManager exposes no count, but get() is bounds safe and returns
    // the unknown feature past the end, so walk the whole content_t range once.
    for (u32 c = 0; c <= 0xffff; ++c) {
        const ContentFeatures &f = ndef->get((content_t)c);
        if (f.name.empty() || f.name == "unknown")
            continue;
        const bool fake_liquid = (f.drawtype == NDT_LIQUID || f.drawtype == NDT_FLOWINGLIQUID)
                && f.liquid_type == LIQUID_NONE;
        // Ice the game draws see-through: the ice group, or else a blended
        // (or fake liquid) block whose name or footstep says ice, which is
        // how Asuna's two thin_ice nodes say it. Opaque ice stays opaque and
        // takes the Ice class on the array path; making it see-through
        // would show what a vanilla client hides.
        const std::string &footstep = f.sound_footstep.name;
        const std::string ice_step = "_ice_footstep";
        const bool block_shape = f.drawtype == NDT_NORMAL || f.drawtype == NDT_NODEBOX ||
                f.drawtype == NDT_LIQUID || f.drawtype == NDT_GLASSLIKE ||
                f.drawtype == NDT_GLASSLIKE_FRAMED || f.drawtype == NDT_GLASSLIKE_FRAMED_OPTIONAL;
        const bool ice = itemgroup_get(f.groups, "ice") > 0 ||
                ((f.alpha == ALPHAMODE_BLEND || fake_liquid) && block_shape &&
                        (nameHasWord(f.name, "ice") || (footstep.size() > ice_step.size() &&
                                footstep.compare(footstep.size() - ice_step.size(), ice_step.size(),
                                        ice_step) == 0)));
        // Use the liquid definition and its light, never a texture filename.
        // Resolved visual tiles include pack overrides and extracted animation
        // frames; flowing tops/sides live in special_tiles, not tiledef.
        auto resolved_texture = [&](const TileLayer &layer) -> u32 {
            if (!layer.texture_id)
                return 0;
            const std::string name = m_session->tsrc()->imageName(
                    layer.texture_id, layer.texture_layer_idx);
            return name.empty() ? 0 : m_session->tsrc()->getTextureId(name);
        };
        auto each_texture = [&](const std::function<void(const TileLayer &, u32)> &fn) {
            for (const auto *tiles : {&f.visuals->tiles, &f.visuals->special_tiles})
                for (const auto &tile : *tiles)
                    for (const auto &layer : tile.layers) {
                        if (const u32 id = resolved_texture(layer))
                            fn(layer, id);
                        if (layer.frames)
                            for (const auto &frame : *layer.frames)
                                fn(layer, frame.texture_id);
                    }
        };
        // Only the two known portal definitions, and only their visible
        // faces. The remaining tiles are blank.png, shared by many nodes.
        // Identify by node, not artwork, so texture packs keep this routing.
        const int portal = f.name == "mcl_portals:portal" && f.alpha == ALPHAMODE_BLEND ? 1
                : f.name == "mcl_portals:portal_end" && f.alpha == ALPHAMODE_CLIP ? 2 : 0;
        if (portal && f.visuals && f.drawtype == NDT_NODEBOX) {
            const int first = portal == 1 ? 4 : 0;
            for (int face = first; face < first + 2; ++face) {
                for (const auto &layer : f.visuals->tiles[face].layers) {
                    GoannaTexture *texture = m_session->tsrc()->goannaTexture(layer.texture_id);
                    if (texture && texture->isArray())
                        m_portal_arrays.insert(layer.texture_id);
                    if (const u32 id = resolved_texture(layer))
                        m_portal_tex[id] = portal;
                    if (layer.frames)
                        for (const auto &frame : *layer.frames)
                            m_portal_tex[frame.texture_id] = portal;
                }
            }
        }
        if (f.isLiquid() && f.visuals && f.light_source < 6)
            each_texture([&](const TileLayer &, u32 id) { calm.insert(id); });
        // What may take the water shader. waving = 3 gives any node the
        // waving liquid material, and lily pads and hanging vines use it to
        // bob with the water; they are not water.
        if ((f.drawtype == NDT_LIQUID || f.drawtype == NDT_FLOWINGLIQUID) && f.visuals)
            each_texture([&](const TileLayer &, u32 id) { m_liquid_tex.insert(id); });
        if (f.isLiquid() && f.light_source >= 6 && f.visuals) {
            const auto &source = ndef->get(f.liquid_alternative_source_id);
            const u32 source_texture = source.visuals
                    ? resolved_texture(source.visuals->tiles[0].layers[0]) : 0;
            each_texture([&](const TileLayer &layer, u32 id) {
                const u32 own = resolved_texture(layer);
                m_lava_tex[id] = LavaTile{f.light_source,
                        source_texture ? source_texture : own};
            });
        }
        // Clear glass, which every game here draws cut out rather than
        // blended, so it would stay on the array path with no reflection at
        // all. What is clear stays clear: the glass shader only refracts and
        // reflects what a vanilla client already shows through the pane. The
        // glasslike drawtype is no evidence on its own (quicksand, mud,
        // clouds and spawners use it), and glowing nodes keep the emissive
        // path, so this asks for a glass group or the word in the name.
        if (f.visuals && f.alpha == ALPHAMODE_CLIP && f.light_source < 6 && !ice) {
            if (itemgroup_get(f.groups, "glass") > 0 || itemgroup_get(f.groups, "material_glass") > 0 ||
                    nameHasWord(f.name, "glass") || nameHasWord(f.name, "pane"))
                each_texture([&](const TileLayer &, u32 id) { m_clear_glass_tex.insert(id); });
        }
        // Flames, tile by tile (goanna_flame.h). Every frame of the tile is
        // recorded: the buffers carry the first, and the material swaps.
        if (f.visuals) {
            for (int i = 0; i < 6; ++i) {
                const TileDef &tdef = f.tiledef[i];
                if (!flameTile(f.drawtype, f.light_source, tdef.name,
                            tdef.animation.type != TAT_NONE))
                    continue;
                const TileLayer &layer = f.visuals->tiles[i].layers[0];
                auto note = [&](u32 id) {
                    if (!id)
                        return;
                    FlameTex &ft = m_flame_tex[id];
                    ft.level = std::max(ft.level, f.light_source);
                    ft.firelike = ft.firelike || f.drawtype == NDT_FIRELIKE;
                };
                note(layer.texture_id);
                note(resolved_texture(layer));
                if (layer.frames)
                    for (const auto &frame : *layer.frames)
                        note(frame.texture_id);
            }
        }
        if (!fake_liquid && !ice)
            continue;
        for (const auto &tdef : f.tiledef) {
            if (tdef.name.empty())
                continue;
            u32 id = m_session->tsrc()->getTextureId(tdef.name);
            if (id && fake_liquid)
                m_fake_liquid_tex.insert(id);
            if (id && ice)
                m_ice_tex.insert(id);
        }
    }
    for (u32 id : calm)
        m_lava_tex.erase(id);
    if (getenv("GOANNA_DEBUG_WHITE"))
        UtilityFunctions::print("fake liquids: ", (int)m_fake_liquid_tex.size(),
                " textures drawn as liquid that are not one");
}

// The single image of a glass or portal array layer, or 0. Each shares
// its upstream buffer, and its array, with every other cut-out tile, so this
// is asked per face (the mesh loop's tile_key), never per buffer.
u32 GoannaClient::specialLayer(GoannaTexture *gt, u16 layer) {
    if (!gt || !gt->isArray())
        return 0;
    buildFakeLiquidTextures();
    const auto &names = gt->layerNames();
    if (layer >= names.size())
        return 0;
    const u32 id = m_session->tsrc()->getTextureId(names[layer]);
    return m_clear_glass_tex.count(id) || m_portal_tex.count(id) ? id : 0;
}

Ref<Material> GoannaClient::materialFor(const MaterialKey &key) {
    auto it = m_materials.find(key.hash());
    if (it != m_materials.end())
        return it->second;
    if (!m_shaders_loaded) {
        m_shaders_loaded = true;
        m_sh_water = load_view_shader("res://shaders/water.gdshader");
        m_sh_lava = load_view_shader("res://shaders/lava.gdshader");
        m_sh_portal_nether = load_view_shader("res://shaders/portal_nether.gdshader");
        m_sh_portal_end = load_view_shader("res://shaders/portal_end.gdshader");
        m_sh_leaves = load_view_shader("res://shaders/waving_leaves.gdshader");
        m_sh_plants = load_view_shader("res://shaders/waving_plants.gdshader");
        m_sh_glass = load_view_shader("res://shaders/glass.gdshader");
        m_sh_glass_clear = load_view_shader("res://shaders/glass_clear.gdshader");
        m_sh_glass_double = load_view_shader("res://shaders/glass_double_sided.gdshader");
        m_sh_ice = load_view_shader("res://shaders/ice.gdshader");
        m_sh_array = load_view_shader("res://shaders/nodes_array.gdshader");
        m_sh_array_scissor = load_view_shader("res://shaders/nodes_array_scissor.gdshader");
        m_sh_crack = load_view_shader("res://shaders/crack_overlay.gdshader");
        m_sh_flame = load_view_shader("res://shaders/flame.gdshader");
        m_sh_flame_glow = load_view_shader("res://shaders/flame_glow.gdshader");
        m_sh_flame_shimmer = load_view_shader("res://shaders/flame_shimmer.gdshader");
    }
    if (key.crack_overlay)
        return crackOverlayMaterial(key);
    if (!key.array_texture && !key.composited && m_flame_material) {
        buildFakeLiquidTextures();
        const auto flame = m_flame_tex.find(key.texture_id);
        if (flame != m_flame_tex.end()) {
            Ref<Material> fm = flameMaterial(key, flame->second);
            if (fm.is_valid())
                return fm;
        }
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

    buildFakeLiquidTextures();
    const auto portal = m_portal_tex.find(key.texture_id);
    if (!key.array_texture && !key.composited && portal != m_portal_tex.end() && tex.is_valid()) {
        Ref<ShaderMaterial> sm;
        sm.instantiate();
        sm->set_shader(portal->second == 1 ? m_sh_portal_nether : m_sh_portal_end);
        sm->set_shader_parameter("albedo_tex", tex);
        m_materials[key.hash()] = sm;
        noteAnimatedMaterial(key, sm);
        return sm;
    }

    // --- array texture: one material for a whole bunch of tiles ---
    if (key.array_texture) {
        GoannaTexture *agt = m_session->tsrc()->goannaTexture(key.texture_id);
        Ref<Texture2DArray> arr = agt ? agt->godotArray() : Ref<Texture2DArray>();
        if (arr.is_valid()) {
            Ref<ShaderMaterial> sm;
            sm.instantiate();
            // Two shaders, not one with a scissor toggle: godotengine/godot#60388,
            // see nodes_array.gdshader. Chosen per tile where the mesh can
            // say (opaque_tile, from arrayTileKey), so sand and stone in an
            // array that also holds a leaf take the opaque shader and its
            // parallax. Where it cannot, the far tiers' merged surfaces and
            // materialForIrr, any alpha in the array means the scissor one.
            const bool scissor = agt->hasAlpha() && !key.opaque_tile;
            sm->set_shader(scissor ? m_sh_array_scissor : m_sh_array);
            // An overlay tile (Mineclonia's grass side over dirt) is the
            // same quad as its base, at the same depth, so whichever draws
            // last is what shows. While both came from one array they were
            // one surface, base first; split by shader they are two, and
            // Godot orders opaque draws by shader id unless told. Its
            // opaque pass sorts by render priority first (the top bits of
            // the Forward+ sort key), so every cut-out goes after every
            // opaque tile and an overlay lands on its base.
            if (scissor)
                sm->set_render_priority(1);
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
                PackedInt32Array classes, diamonds;
                PackedFloat32Array coarse, roughness_floor;
                Dictionary grass_layers;
                roughness_floor.resize((int)lnames.size());
                classes.resize((int)lnames.size());
                diamonds.resize((int)lnames.size());
                coarse.resize((int)lnames.size());
                for (size_t i = 0; i < lnames.size(); ++i) {
                    std::string plain = tileBaseName(lnames[i]);
                    if (plain.empty())
                        plain = lnames[i];
                    classes[(int)i] = (int)mtable.textureClass(plain);
                    diamonds[(int)i] = gemTextureCode(lnames[i]);
                    roughness_floor[(int)i] = mtable.bark_textures.count(plain) ? 0.82f : 0.0f;
                    coarse[(int)i] = m_session->tsrc()->textureCoarseness(lnames[i]);
                    // Ground top textures identified from normal soil nodes.
                    if (mtable.grass_top_textures.count(plain)) {
                        const auto avg = m_session->tsrc()->getTextureAverageColor(lnames[i]);
                        grass_layers[(int)i] = Color(avg.getRed()/255.0f,
                                avg.getGreen()/255.0f, avg.getBlue()/255.0f, 1.0f);
                    }
                }
                sm->set_meta("goanna_grass_layers", grass_layers);
                sm->set_shader_parameter("layer_class", classes);
                sm->set_shader_parameter("layer_diamond", diamonds);
                // An animation array's frame counts and lengths, which the
                // shader turns into the frame to draw. An ordinary array
                // leaves the uniform at zero and never animates.
                // Godot fills an ivec2 array uniform from flat pairs.
                const auto &lanim = agt->layerAnim();
                if (!lanim.empty()) {
                    PackedInt32Array anim;
                    anim.resize((int)lanim.size() * 2);
                    for (size_t i = 0; i < lanim.size(); ++i) {
                        anim[(int)i * 2] = lanim[i].frames;
                        anim[(int)i * 2 + 1] = lanim[i].frame_ms;
                    }
                    sm->set_shader_parameter("layer_anim", anim);
                }
                // Each map's own relief depth for the parallax march; a
                // layer without authored height stays at 0 and takes the
                // class table's depth in the shader.
                if (nrm.is_valid()) {
                    const auto &ld = agt->layerDepths();
                    PackedFloat32Array depths;
                    depths.resize((int)lnames.size());
                    for (size_t i = 0; i < lnames.size(); ++i)
                        depths[(int)i] = i < ld.size() ? ld[i] : 0.0f;
                    sm->set_shader_parameter("layer_depth", depths);
                }
                sm->set_shader_parameter("layer_coarse", coarse);
                sm->set_shader_parameter("layer_roughness_floor", roughness_floor);
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
            // (docs/history/far-rendering-log.md, "The launch target's four
            // defects, closed 2026-08-22", item 2c), so each layer's own
            // average colour rides along for the shader
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
                    // with distance (docs/develop/launch-target.md, R1).
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
    buildFakeLiquidTextures();
    Ref<Shader> sh;
    switch (mtype) {
    case TILE_MATERIAL_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_BASIC:
        // A solid using the liquid drawtype needs a frozen surface, not
        // water animation or glass's screen-space refraction. A node that
        // only waves like a liquid (a lily pad) is a plant.
        if (m_fake_liquid_tex.count(key.texture_id)) {
            if (m_ice_tex.count(key.texture_id))
                sh = m_sh_ice;
            else if (!m_solid_ice)
                sh = m_sh_glass;
        } else if (m_liquid_tex.count(key.texture_id)) {
            sh = m_sh_water;
        } else {
            sh = m_sh_plants;
        }
        break;
    case TILE_MATERIAL_WAVING_LEAVES:
        sh = m_sh_leaves; break;
    case TILE_MATERIAL_WAVING_PLANTS:
        sh = m_sh_plants; break;
    case TILE_MATERIAL_BASIC:
    case TILE_MATERIAL_PLAIN:
        // Double sided and not waving: sugar cane, saplings, crops,
        // mushrooms, ladders, rails. They took the standard material,
        // which has no sky fill, and the fill is most of the light at dusk
        // and all of it at night, so they drew black beside lit ground.
        // The plants shader with waving off lights them as the ground is.
        // Clear glass takes the glass shader either way; a door's glass is
        // one of the double sided tiles.
        if (m_clear_glass_tex.count(key.texture_id))
            sh = key.backface_culling ? m_sh_glass_clear : m_sh_glass_double;
        else if (!key.backface_culling)
            sh = m_sh_plants;
        break;
    case TILE_MATERIAL_ALPHA:
    case TILE_MATERIAL_PLAIN_ALPHA:
        // Refraction glass is only right for solid, backface-culled nodes
        // (glass, ice, stained glass). Double-sided alpha-blend tiles are
        // plants, leaves and the like: the glass shader's screen mix and
        // specular make them read white, so they take the standard path.
        if (m_ice_tex.count(key.texture_id))
            sh = m_sh_ice;
        else if (key.backface_culling)
            sh = m_sh_glass;
        break;
    default:
        break;
    }
    const bool liquid_material = mtype == TILE_MATERIAL_LIQUID_OPAQUE ||
            mtype == TILE_MATERIAL_LIQUID_TRANSPARENT ||
            mtype == TILE_MATERIAL_WAVING_LIQUID_OPAQUE ||
            mtype == TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT ||
            mtype == TILE_MATERIAL_WAVING_LIQUID_BASIC;
    if (liquid_material && m_lava_tex.count(key.texture_id))
        sh = m_sh_lava;
    if (getenv("GOANNA_DEBUG_WHITE") && sh.is_valid())
        UtilityFunctions::print((sh == m_sh_lava ? "LAVA " : sh == m_sh_ice ? "ICE " : sh == m_sh_glass || sh == m_sh_glass_clear || sh == m_sh_glass_double ? "GLASS " : sh == m_sh_plants ? "PLANTS " : sh == m_sh_leaves ? "LEAVES " : "WATER "),
                "'", String(m_session->tsrc()->getTextureName(key.texture_id).c_str()), "' mtype=", (int)mtype,
                " cull=", key.backface_culling, " texvalid=", tex.is_valid());
    if (sh.is_valid() && tex.is_valid() && (emissive == 0 || sh == m_sh_lava)) {
        Ref<ShaderMaterial> sm;
        sm.instantiate();
        sm->set_shader(sh);
        sm->set_shader_parameter("albedo_tex", tex);
        if (sh == m_sh_lava) {
            const LavaTile &lava = m_lava_tex.at(key.texture_id);
            GoannaTexture *surface = m_session->tsrc()->goannaTexture(lava.surface_texture);
            if (surface && surface->godotTexture().is_valid()) {
                sm->set_shader_parameter("albedo_tex", surface->godotTexture());
                configureLavaMaterial(sm, surface->image());
            }
            float level = lava.level / 14.0f;
            sm->set_shader_parameter("emission_energy", 4.8f * level * level);
            sm->set_shader_parameter("surface_geometry", true);
        }
        if (sh == m_sh_ice)
            sm->set_shader_parameter("solid", m_solid_ice);
        bool waving = (mtype == TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT ||
                mtype == TILE_MATERIAL_WAVING_LIQUID_BASIC || mtype == TILE_MATERIAL_WAVING_LEAVES ||
                mtype == TILE_MATERIAL_WAVING_PLANTS);
        // Plant sway is not the bob a liquid-waving node asks for, so a lily
        // pad on the plants shader keeps still.
        const bool liquid_waving = mtype == TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT ||
                mtype == TILE_MATERIAL_WAVING_LIQUID_BASIC;
        if (sh == m_sh_water || sh == m_sh_leaves || sh == m_sh_plants)
            sm->set_shader_parameter("waving", waving && !(sh == m_sh_plants && liquid_waving));
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
        if (sh == m_sh_glass || sh == m_sh_glass_clear || sh == m_sh_glass_double || sh == m_sh_ice ||
                sh == m_sh_leaves ||
                sh == m_sh_plants) {
            Ref<Texture2D> nrm_tex;
            Ref<Texture2D> spc_tex;
			const char *no_pbr_env = getenv("GOANNA_NO_PBR");
			if (!no_pbr_env || !*no_pbr_env) {
                nrm_tex = companionTexture(key.texture_id, "_n");
                spc_tex = companionTexture(key.texture_id, "_s");
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
            if (sh == m_sh_ice || sh == m_sh_leaves || sh == m_sh_plants) {
                for (const char *ch : {"normal", "ao", "roughness", "specular",
                                       "sss", "emission", "micro_shadow"})
                    sm->set_shader_parameter(String(ch) + String("_strength"),
                            material_strength(String(ch)));
            }
        }
        m_materials[key.hash()] = sm;
        // Water and lava animate themselves; see noteAnimatedMaterial.
        if (sh != m_sh_water && sh != m_sh_lava)
            noteAnimatedMaterial(key, sm);
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
    if (tex.is_valid())
        noteAnimatedMaterial(key, mat);
    return mat;
}

// A flame: the tile's own frame, measured for its ramp, drawn by
// flame.gdshader, then flame_glow.gdshader (the halo) and
// flame_shimmer.gdshader as next passes. Every pass carries albedo_tex,
// and showAnimationFrame moves each to the frame the clock names.
// docs/systems/fire-material.md.
Ref<Material> GoannaClient::flameMaterial(const MaterialKey &key, const FlameTex &flame) {
    GoannaTextureSource *tsrc = m_session->tsrc();
    GoannaTexture *gt = tsrc->goannaTexture(key.texture_id);
    Ref<ImageTexture> tex = gt ? gt->godotTexture() : Ref<ImageTexture>();
    if (tex.is_null() || m_sh_flame.is_null() || m_sh_flame_glow.is_null() ||
            m_sh_flame_shimmer.is_null())
        return Ref<Material>();
    std::vector<video::IImage *> frames;
    if (const NodeAnimation *anim = tsrc->nodeAnimation(key.texture_id))
        for (const auto &frame : anim->frames)
            if (GoannaTexture *fgt = tsrc->goannaTexture(frame.texture_id))
                frames.push_back(fgt->image());
    if (frames.empty())
        frames.push_back(gt->image());
    const FlameRamp ramp = measureFlameRamp(frames);
    Ref<ShaderMaterial> glow;
    glow.instantiate();
    glow->set_shader(m_sh_flame_glow);
    Ref<ShaderMaterial> shimmer;
    shimmer.instantiate();
    shimmer->set_shader(m_sh_flame_shimmer);
    Ref<ShaderMaterial> sm;
    sm.instantiate();
    sm->set_shader(m_sh_flame);
    for (const Ref<ShaderMaterial> &m : {sm, glow, shimmer}) {
        m->set_shader_parameter("albedo_tex", tex);
        configureFlameMaterial(m, ramp, (float)flame.level);
        // A culled mesh tile is drawn from its front only, as upstream does.
        m->set_shader_parameter("single_sided", key.backface_culling);
    }
    // A firelike frame spans its node, so its top edge can rise for the
    // shimmer above the flame without moving the art.
    shimmer->set_shader_parameter("shimmer_rise", flame.firelike ? 0.6f : 0.0f);
    glow->set_next_pass(shimmer);
    sm->set_next_pass(glow);
    if (getenv("GOANNA_DEBUG_FLAME"))
        UtilityFunctions::print("flame material: '", String(tsrc->getTextureName(key.texture_id).c_str()),
                "' level ", (int)flame.level, " firelike ", flame.firelike, " heat ",
                ramp.lum_low, "..", ramp.lum_high, " core ", Color(ramp.core[0], ramp.core[1], ramp.core[2]),
                " tip ", Color(ramp.tip[0], ramp.tip[1], ramp.tip[2]), " texels ", ramp.texels);
    m_materials[key.hash()] = sm;
    noteAnimatedMaterial(key, sm);
    return sm;
}

Ref<Material> GoannaClient::crackOverlayMaterial(const MaterialKey &key) {
    Ref<ShaderMaterial> sm;
    sm.instantiate();
    sm->set_shader(m_sh_crack);
    // The strip upstream's own shader reads: one square frame per stage,
    // stacked down the image, frame count from its proportions.
    GoannaTextureSource *tsrc = m_session->tsrc();
    GoannaTexture *cgt = tsrc->goannaTexture(tsrc->getTextureId("crack_anylength.png"));
    if (cgt && cgt->godotTexture().is_valid())
        sm->set_shader_parameter("crack_tex", cgt->godotTexture());
    const int frames = std::max(1, m_session->crackAnimationLength());
    // Upstream clamps a stage past the strip to its last frame.
    sm->set_shader_parameter("crack_frames", frames);
    sm->set_shader_parameter("crack_frame", std::min((int)key.crack_level, frames - 1));
    sm->set_shader_parameter("crack_scale", (float)key.crack_scale);
    // An alpha tested array: the crack is cut to the same holes the tile is.
    // Opaque tiles leave it unbound and share one material per stage.
    GoannaTexture *agt = key.texture_id ? tsrc->goannaTexture(key.texture_id) : nullptr;
    if (agt && agt->godotArray().is_valid()) {
        sm->set_shader_parameter("base_alpha_test", true);
        sm->set_shader_parameter("albedo_array", agt->godotArray());
        const auto &lanim = agt->layerAnim();
        if (!lanim.empty()) {
            PackedInt32Array anim;
            anim.resize((int)lanim.size() * 2);
            for (size_t i = 0; i < lanim.size(); ++i) {
                anim[(int)i * 2] = lanim[i].frames;
                anim[(int)i * 2 + 1] = lanim[i].frame_ms;
            }
            sm->set_shader_parameter("layer_anim", anim);
        }
    }
    // The same light channel strengths the surface under it has, so the
    // settings sliders move both (set_material_strength walks m_materials).
    for (const auto &d : kMatStrengthDefaults)
        sm->set_shader_parameter(String(d.first.c_str()) + String("_strength"),
                material_strength(String(d.first.c_str())));
    if (getenv("GOANNA_DEBUG_CRACK"))
        UtilityFunctions::print("crack overlay material: frame ", (int)key.crack_level, "/",
                frames, " scale ", (int)key.crack_scale, " alpha array ", (int)key.texture_id);
    m_materials[key.hash()] = sm;
    return sm;
}

// The texture of the frame a vanilla client draws for this tile at clock
// time t: upstream's own AnimationInfo::getTexture (client/tile.cpp), as
// MapBlockMesh::animate calls it. It takes a mutable pointer to the frames
// but only reads through it.
static u32 animationFrameAt(const NodeAnimation &anim, float t) {
    AnimationInfo info(const_cast<std::vector<FrameSpec> *>(&anim.frames), anim.frame_length_ms);
    GoannaTexture *now = dynamic_cast<GoannaTexture *>(info.getTexture(t));
    return now ? now->id() : 0;
}

Ref<Texture2D> GoannaClient::companionTexture(u32 texture_id, const char *suffix) {
    GoannaTextureSource *tsrc = m_session->tsrc();
    GoannaTexture *cgt = tsrc->tileCompanion(tsrc->getTextureName(texture_id), suffix);
    return cgt ? Ref<Texture2D>(cgt->godotTexture()) : Ref<Texture2D>();
}

void GoannaClient::noteAnimatedMaterial(const MaterialKey &key, const Ref<Material> &material) {
    // A material keyed by an animated tile's first frame, that is not drawn
    // from an animation array. A crack composite is a still image of one
    // frame, and every liquid is left to its own shader: lava deliberately
    // animates its source frame itself (docs/systems/lava-material.md), and the
    // water shader moves its own surface.
    if (key.array_texture || key.composited || !m_session || material.is_null())
        return;
    const NodeAnimation *anim = m_session->tsrc()->nodeAnimation(key.texture_id);
    if (!anim || anim->frames.size() < 2)
        return;
    switch (m_session->shsrc().materialType(key.shader_id)) {
    case TILE_MATERIAL_LIQUID_OPAQUE:
    case TILE_MATERIAL_WAVING_LIQUID_OPAQUE:
    case TILE_MATERIAL_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_BASIC:
        return;
    default:
        break;
    }
    AnimatedMaterial am;
    am.material = material;
    am.anim = anim;
    am.shown = key.texture_id;
    m_anim_materials.push_back(am);
    // Straight onto the frame the clock names, so a material built mid
    // animation does not show the first frame until the next change.
    const u32 now = animationFrameAt(*anim, m_node_anim_time);
    if (now && now != am.shown)
        showAnimationFrame(m_anim_materials.back(), now);
}

void GoannaClient::showAnimationFrame(AnimatedMaterial &am, u32 frame_texture) {
    GoannaTexture *fgt = m_session->tsrc()->goannaTexture(frame_texture);
    Ref<ImageTexture> albedo = fgt ? fgt->godotTexture() : Ref<ImageTexture>();
    if (albedo.is_null())
        return;
    am.shown = frame_texture;
    // The same textures materialFor derives from a tile, derived from this
    // frame instead: the colour, and for a standard material the inferred
    // relief and the emission mask, both of which are cut from the colour.
    if (StandardMaterial3D *std_mat = Object::cast_to<StandardMaterial3D>(am.material.ptr())) {
        std_mat->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, albedo);
        if (std_mat->get_feature(BaseMaterial3D::FEATURE_NORMAL_MAPPING)) {
            Ref<ImageTexture> nrm = fgt->godotNormal(m_auto_bump);
            if (nrm.is_valid())
                std_mat->set_texture(BaseMaterial3D::TEXTURE_NORMAL, nrm);
        }
        if (std_mat->get_feature(BaseMaterial3D::FEATURE_EMISSION)) {
            Ref<ImageTexture> glow = fgt->godotEmissionMask();
            std_mat->set_texture(BaseMaterial3D::TEXTURE_EMISSION,
                    glow.is_valid() ? glow : albedo);
        }
        return;
    }
    if (ShaderMaterial *sm = Object::cast_to<ShaderMaterial>(am.material.ptr())) {
        sm->set_shader_parameter("albedo_tex", albedo);
        // A flame's halo and shimmer passes read the same frame.
        for (Ref<ShaderMaterial> next = sm->get_next_pass(); next.is_valid();
                next = next->get_next_pass())
            next->set_shader_parameter("albedo_tex", albedo);
        // A companion follows the frame where the pack has one per frame;
        // where it has one still map, companionTexture returns that for
        // every frame and setting it again changes nothing.
        if ((bool)sm->get_shader_parameter("has_normal")) {
            Ref<Texture2D> nrm = companionTexture(frame_texture, "_n");
            if (nrm.is_valid())
                sm->set_shader_parameter("normal_tex", nrm);
        }
        if ((bool)sm->get_shader_parameter("has_spec")) {
            Ref<Texture2D> spc = companionTexture(frame_texture, "_s");
            if (spc.is_valid())
                sm->set_shader_parameter("spec_tex", spc);
        }
    }
}

void GoannaClient::step_node_animation(double dt) {
    // Client::step: dtime capped at DTIME_LIMIT, the clock kept in [0, 60).
    if (dt > DTIME_LIMIT)
        dt = DTIME_LIMIT;
    if (dt < 0.0)
        dt = 0.0;
    m_node_anim_time = m_node_anim_pinned >= 0.0f ? m_node_anim_pinned
            : fmodf(m_node_anim_time + (float)dt, 60.0f);
    set_view_shader_parameter(
            "goanna_node_anim_time", m_node_anim_time);
    // Keep the standalone shader clock usable by renderer fixtures, but
    // never dereference session-owned animation frames after disconnect.
    if (!m_session)
        return;
    for (AnimatedMaterial &am : m_anim_materials) {
        const u32 now = animationFrameAt(*am.anim, m_node_anim_time);
        if (now && now != am.shown)
            showAnimationFrame(am, now);
    }
}

void GoannaClient::set_node_animation_enabled(bool on) {
    m_shared_identity.clear();
    if (!m_session || !m_session->tsrc() || m_session->tsrc()->nodeAnimationEnabled() == on)
        return;
    m_session->tsrc()->setNodeAnimationEnabled(on);
    // Materials were built for one path or the other, and near meshes carry
    // the animation array's layers in UV2, so both are rebuilt, as
    // set_auto_bump rebuilds them. The far tiers resolve tiles through
    // their own cache: clearing it lets each region take the change when it
    // next rebuilds, without throwing the whole far field away for a switch.
    clearMaterials();
    {
        std::lock_guard<std::mutex> tile_lock(m_lod_tiles.mutex);
        m_lod_tiles.entries.clear();
    }
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    for (auto &kv : m_near_blocks)
        m_session->invalidateBlock(kv.first);
}

bool GoannaClient::node_animation_enabled() const {
    return m_session && m_session->tsrc() && m_session->tsrc()->nodeAnimationEnabled();
}

void GoannaClient::set_node_animation_time(double seconds) {
    m_node_anim_pinned = seconds < 0.0 ? -1.0f : fmodf((float)seconds, 60.0f);
    step_node_animation(0.0);
}

Dictionary GoannaClient::node_animation() {
    Dictionary out;
    out["time"] = m_node_anim_time;
    out["pinned"] = m_node_anim_pinned >= 0.0f;
    out["enabled"] = node_animation_enabled();
    if (!m_session)
        return out;
    GoannaTextureSource *tsrc = m_session->tsrc();
    const auto *table = tsrc->nodeAnimations();
    int in_arrays = 0;
    Array tiles;
    if (table) {
        for (const auto &kv : *table) {
            const NodeAnimation &a = kv.second;
            const u32 now = animationFrameAt(a, m_node_anim_time);
            int frame = 0;
            for (size_t i = 0; i < a.frames.size(); ++i)
                if (a.frames[i].texture_id == now)
                    frame = (int)i;
            Dictionary t;
            t["texture"] = String(tsrc->getTextureName(kv.first).c_str());
            t["frames"] = (int)a.frames.size();
            t["frame_ms"] = (int)a.frame_length_ms;
            t["frame"] = frame;
            t["array"] = (int64_t)a.array_id;
            t["base_layer"] = (int)a.base_layer;
            tiles.push_back(t);
            if (a.array_id)
                ++in_arrays;
        }
    }
    out["tiles"] = tiles;
    out["tile_count"] = tiles.size();
    out["in_arrays"] = in_arrays;
    Array mats;
    for (const AnimatedMaterial &am : m_anim_materials) {
        Dictionary m;
        m["first_frame"] = String(tsrc->getTextureName(am.anim->frames[0].texture_id).c_str());
        m["shown"] = String(tsrc->getTextureName(am.shown).c_str());
        m["class"] = am.material.is_valid() ? am.material->get_class() : String();
        mats.push_back(m);
    }
    out["single_materials"] = mats;
    return out;
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
        // Emissive geometry is excluded by the lamp shadow caster mask.
        // The old 0.6-node escape offset therefore detached the light from
        // its visible source for no benefit. Torches use the upper part of
        // their oriented selection box. A lantern uses its body box, keeping
        // the source inside its glass rather than at the node's origin/chain.
        l.node_pos = l.pos;
        l.liquid = f.isLiquid();
        if (l.liquid) {
            auto node_at = [&](v3s16 p) {
                v3s16 bpos = getNodeBlockPos(p);
                MapBlock *neighbour = m_session->getBlock(bpos);
                return neighbour ? neighbour->getNodeNoCheck(p - bpos * MAP_BLOCKSIZE)
                                 : MapNode(CONTENT_IGNORE);
            };
            const v3s16 p = bp * MAP_BLOCKSIZE + v3s16(x,y,z);
            auto exposed = [&](v3s16 offset) {
                MapNode other = node_at(p + offset);
                const auto &of = ndef->get(other);
                return other.getContent() != CONTENT_IGNORE && !of.walkable && !of.isLiquid();
            };
            // A lamp at the cell centre sits below the top of the bank.
            // Put it just outside an exposed emitting surface. Buried liquid
            // must not consume shadow slots or put lamps inside the terrain.
            if (exposed(v3s16(0,1,0))) {
                l.pos.y += 1.15f;
            } else {
                bool visible = false;
                for (const auto &side : {v3s16(1,0,0), v3s16(-1,0,0),
                        v3s16(0,0,1), v3s16(0,0,-1)}) {
                    if (!exposed(side))
                        continue;
                    l.pos += Vector3(side.X * 0.65f, 0.15f, -side.Z * 0.65f);
                    visible = true;
                    break;
                }
                if (!visible)
                    continue;
            }
        }
        auto torch = f.groups.find("torch");
        if (f.drawtype == NDT_TORCHLIKE ||
                (torch != f.groups.end() && torch->second > 0)) {
            std::vector<aabb3f> boxes;
            n.getSelectionBoxes(ndef, &boxes);
            if (!boxes.empty()) {
                aabb3f box = boxes[0];
                for (size_t i = 1; i < boxes.size(); ++i)
                    box.addInternalBox(boxes[i]);
                v3f tip = box.getCenter() / BS;
                tip.Y = (box.MaxEdge.Y - 0.12f * box.getExtent().Y) / BS;
                l.pos += Vector3(tip.X, tip.Y, -tip.Z);
            }
        } else if (itemgroup_get(f.groups, "lantern") > 0) {
            std::vector<aabb3f> boxes;
            n.getSelectionBoxes(ndef, &boxes);
            if (!boxes.empty()) {
                auto volume = [](const aabb3f &b) {
                    v3f e = b.getExtent();
                    return e.X * e.Y * e.Z;
                };
                const auto body = std::max_element(boxes.begin(), boxes.end(),
                        [&](const aabb3f &a, const aabb3f &b) { return volume(a) < volume(b); });
                v3f centre = body->getCenter() / BS;
                l.pos += Vector3(centre.X, centre.Y, -centre.Z);
            }
        }
        l.level = f.light_source / 14.0f;
        // colour from the node's first tile (torch textures average to warm orange)
        video::SColor c(255, 255, 220, 160);
        if (f.visuals) {
            const TileLayer &tl = f.drawtype == NDT_FLOWINGLIQUID
                    ? f.visuals->special_tiles[0].layers[0] : f.visuals->tiles[0].layers[0];
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

// The entity renderer, made on first use with every setting it mirrors. The
// held item, item previews and model previews can make it before the first
// entity sync, and those three set only parallax and hair, so a held item
// drawn first took EntityRenderer's own auto bump default, not the client's.
void GoannaClient::ensureEntityRenderer() {
    if (m_entities)
        return;
    m_entities = std::make_unique<EntityRenderer>(this);
    m_entities->setParallax(material_strength("parallax"));
    m_entities->setHair(material_strength("hair"));
    m_entities->setHairShader(material_strength("hair_shader"));
    m_entities->setChannel("micro_shadow", material_strength("micro_shadow"));
    m_entities->setChannel("parallax_short", material_strength("parallax_short"));
    m_entities->setShowBody(m_show_body);
    m_entities->setThirdPerson(m_third_person);
    m_entities->setAutoBump(m_auto_bump);
    m_entities->setFlameMaterial(m_flame_material);
}

void GoannaClient::sync_entities(double dt) {
    if (!m_session)
        return;
    auto t0 = clock_t_::now();
    ensureEntityRenderer();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    if (dt > 0.1) dt = 0.1;
    m_session->stepObjects((float)dt);
    m_entities->sync(*m_session, (float)dt, Vector3());
    if (procedural_grass() && has_meta("goanna_grass_material") &&
            (bool)get_meta("goanna_grass_interaction", true) &&
            (int)get_meta("goanna_grass_interactors", 8) > 0)
        goanna::update_grass_interactors(this,m_entities->grass_interactors(*m_session));
    ema(m_ms_entities, ms_since(t0));
}

void GoannaClient::set_arm_swing(float s) {
    m_arm_swing = std::clamp(s, 0.0f, 1.0f);
    if (m_entities)
        m_entities->setArmSwing(m_arm_swing);
}

void GoannaClient::set_third_person(bool on) {
    m_third_person = on;
    if (m_entities)
        m_entities->setThirdPerson(on);
}

bool GoannaClient::node_walkable_at(const Vector3 &pos) {
    if (!m_session)
        return false;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    const v3s16 p((s16)std::floor(pos.x + 0.5f), (s16)std::floor(pos.y + 0.5f),
            (s16)std::floor(-pos.z + 0.5f));
    const MapNode n = m_session->map().getNode(p);
    return m_session->nodeDefs()->get(n).walkable;
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
    ensureEntityRenderer();
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
// in the hand lights the way. Client side only: nothing is asked of the
// server and nothing shown that is not the player's own flame.
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
    ensureEntityRenderer();
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
    ensureEntityRenderer();
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

Array GoannaClient::entity_list() {
    if (!m_session || !m_entities)
        return Array();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->list(*m_session);
}

Dictionary GoannaClient::entity_anchor(int id) {
    if (!m_session || !m_entities || id <= 0 || id > 65535)
        return Dictionary();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->anchor(*m_session, (u16)id);
}

Dictionary GoannaClient::entity_animation(int id) {
    if (!m_session || !m_entities || id < 0 || id > 65535)
        return Dictionary();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->animation(*m_session, (u16)id);
}

void GoannaClient::updateLampOcclusion(const Vector3 &around) {
    const auto started = clock_t_::now();
    if (!m_lamp_occlusion || !m_session ||
            std::none_of(m_light_slot.begin(), m_light_slot.end(),
                    [](const auto &slot) { return slot.key != 0; })) {
        set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4());
        return;
    }
    // Changes are refreshed at most ten times a second, independently of
    // the player's frame rate. Static frames do not rebuild or upload data.
    if (m_lamp_occlusion_grid.is_valid() && ms_since(m_lamp_occlusion_updated) < 100.0) return;
    m_lamp_occlusion_updated = started;
    constexpr int edge = 64;
    const int ox = (int)std::floor(around.x / 16.0f) * 16 - edge / 2;
    const int oy = (int)std::floor(around.y / 16.0f) * 16 - edge / 2;
    const int oz = (int)std::floor(around.z / 16.0f) * 16 - edge / 2;
    const v3s16 low = getNodeBlockPos(v3s16(ox, oy, -(oz + edge - 1)));
    const v3s16 high = getNodeBlockPos(v3s16(ox + edge - 1, oy + edge - 1, -oz));
    std::unique_lock<std::mutex> lock(m_session->mapLock());
    std::string signature = m_session->terrainPeer() + ":" + std::to_string(m_session->terrainDefinitions()) + ":" +
            std::to_string(ox) + ":" + std::to_string(oy) + ":" + std::to_string(oz);
    // Include all boundary blocks, including absent ones. An arrival or edit
    // refreshes the grid even when neither the camera nor lamps moved.
    for (int z = low.Z; z <= high.Z; ++z)
        for (int y = low.Y; y <= high.Y; ++y)
            for (int x = low.X; x <= high.X; ++x)
                signature += m_session->blockContentDigest(v3s16(x, y, z)) + ":" +
                        std::to_string(m_session->blockRevision(v3s16(x, y, z)));
    PackedByteArray sources;
    sources.resize(std::max(1, (int)m_light_slot.size()) * 16);
    float *source = reinterpret_cast<float *>(sources.ptrw());
    for (size_t i = 0; i < m_light_slot.size(); ++i) {
        const auto &slot = m_light_slot[i];
        const Vector3 p = slot.pos;
        source[i * 4] = p.x; source[i * 4 + 1] = p.y; source[i * 4 + 2] = p.z;
        source[i * 4 + 3] = slot.key ? 1.0f : 0.0f;
    }
    signature.append((const char *)sources.ptr(), sources.size());
    signature = hashing::sha256(signature);
    if (signature == m_lamp_occlusion_signature) {
        set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4(ox - 0.5f, oy - 0.5f, oz - 0.5f, edge));
        ema(m_ms_lamp_occlusion, ms_since(started));
        return;
    }
    std::vector<float> cells(edge * edge * edge, 0.0f);
    // Full opaque cubes only. Partial nodes retain their shadow-map path;
    // treating a door or stair as a whole cube would close visible openings.
    MapBlock *last = nullptr;
    v3s16 last_bp(-32768, -32768, -32768);
    for (int z = 0; z < edge; ++z)
        for (int y = 0; y < edge; ++y)
            for (int x = 0; x < edge; ++x) {
                const v3s16 np(ox + x, oy + y, -(oz + z));
                const v3s16 bp = getNodeBlockPos(np);
                if (bp != last_bp) { last = m_session->getBlock(bp); last_bp = bp; }
                if (!last) continue;
                const MapNode node = last->getNodeNoCheck(np - bp * MAP_BLOCKSIZE);
                if (node.getContent() == CONTENT_IGNORE) continue;
                const auto &f = m_session->nodeDefs()->get(node);
                if (f.drawtype == NDT_NORMAL && !f.light_propagates && f.light_source == 0)
                    cells[(z * edge + y) * edge + x] = -1.0f;
            }
    if (!m_session->carves().empty()) {
        for (int z = low.Z; z <= high.Z; ++z)
            for (int y = low.Y; y <= high.Y; ++y)
                for (int x = low.X; x <= high.X; ++x) {
                    CarveSnapshot carves;
                    m_session->carves().snapshot(x * 16, y * 16, z * 16, carves);
                    for (const auto &entry : carves.entries) {
                        const int gx = x * 16 + entry.x - ox, gy = y * 16 + entry.y - oy, gz = -(z * 16 + entry.z) - oz;
                        if (gx >= 0 && gx < edge && gy >= 0 && gy < edge && gz >= 0 && gz < edge)
                            cells[(gz * edge + gy) * edge + gx] = 0;
                    }
                }
    }
    for (size_t i = 0; i < m_light_slot.size(); ++i) {
        if (!m_light_slot[i].key) continue;
        const Vector3 p = m_light_slot[i].pos;
        const int x = (int)std::floor(p.x + 0.5f) - ox;
        const int y = (int)std::floor(p.y + 0.5f) - oy;
        const int z = (int)std::floor(p.z + 0.5f) - oz;
        if (x >= 0 && x < edge && y >= 0 && y < edge && z >= 0 && z < edge)
            cells[(z * edge + y) * edge + x] = (float)(i + 1);
    }
    lock.unlock();
    TypedArray<Ref<Image>> slices;
    for (int z = 0; z < edge; ++z) {
        PackedByteArray bytes;
        bytes.resize(edge * edge * sizeof(float));
        std::memcpy(bytes.ptrw(), cells.data() + z * edge * edge, bytes.size());
        slices.push_back(Image::create_from_data(edge, edge, false, Image::FORMAT_RF, bytes));
    }
    if (m_lamp_occlusion_grid.is_null()) {
        m_lamp_occlusion_grid.instantiate();
        if (m_lamp_occlusion_grid->create(Image::FORMAT_RF, edge, edge, edge, false, slices) != OK) {
            m_lamp_occlusion_grid.unref();
            set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4());
            return;
        }
    } else m_lamp_occlusion_grid->update(slices);
    const auto source_image = Image::create_from_data(std::max(1, (int)m_light_slot.size()), 1,
            false, Image::FORMAT_RGBAF, sources);
    // Pool size can change with the tier; set_image permits a new width.
    if (m_lamp_occlusion_sources.is_null()) m_lamp_occlusion_sources.instantiate();
    m_lamp_occlusion_sources->set_image(source_image);
    m_lamp_occlusion_signature = signature;
    set_view_shader_parameter("goanna_lamp_occlusion_grid", m_lamp_occlusion_grid);
    set_view_shader_parameter("goanna_lamp_occlusion_sources", m_lamp_occlusion_sources);
    set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4(ox - 0.5f, oy - 0.5f, oz - 0.5f, edge));
    ema(m_ms_lamp_occlusion, ms_since(started));
}

void GoannaClient::update_lights(const Vector3 &around, int max_lights) {
    auto t0 = clock_t_::now();
    if (max_lights <= 0) {
        // No candidate traversal or ranking for the fallback path. Negative
        // reach makes the existing baked-light blend complete even nearby.
        for (auto *light : m_light_pool) {
            light->set_visible(false);
            light->queue_free();
        }
        m_light_pool.clear();
        m_light_slot.clear();
        set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4());
        m_lights_in_range = 0;
        m_light_churn = 0;
        set_view_shader_parameter("goanna_lamp_reach", -64.0f);
        ema(m_ms_lights, ms_since(t0));
        return;
    }
    static const bool no_light_shadows = getenv("GOANNA_NO_LIGHT_SHADOWS") != nullptr;
    const bool shadowed_pool = !no_light_shadows && m_shadow_lamps > 0;
    // Light admission is independent of shadow maps. Unselected lamps remain
    // lit; propagated node light supplies the world beyond the direct pool.

    // A lamp's identity is where it is. Node aligned positions make the
    // rounding exact, so this key is stable for as long as the lamp exists and
    // survives the pool being rebuilt.
    auto key_of = [](const NodeLight *l) {
        return ((int64_t)llroundf(l->node_pos.x) * 73856093LL) ^
                ((int64_t)llroundf(l->node_pos.y) * 19349663LL) ^
                ((int64_t)llroundf(l->node_pos.z) * 83492791LL);
    };
    // Steeper than linear so a level-2 firefly bush is a soft glow while a
    // level-14 torch gets the full calibrated energy.
    auto range_of = [](float level) { return 3.0f + 11.0f * level; };
    auto energy_of = [](float level) { return 4.0f * std::pow(level, 1.6f); };

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
            all.push_back({ &l, key_of(&l), score });
        }
    m_lights_in_range = (int)all.size();
    m_light_churn = 0;

    // Break ties on the key. A symmetrical build gives you equally ranked
    // lamps constantly, and without a tie-break their order comes from however
    // the block map happened to iterate, so they can swap between frames with
    // nothing having moved.
    std::sort(all.begin(), all.end(), [](const Cand &a, const Cand &b) {
        return a.key < b.key;
    });

    // A pool has hundreds of emitting cells. Sixteen adjacent lamps waste
    // the entire shadow budget on one small patch. Keep a spatially spread
    // subset of exposed liquid lamps. Choose in world-key order BEFORE
    // camera ranking/culling, or walking changes the emitting cells.
    std::vector<Cand> spread;
    std::map<v3s16, std::vector<Vector3>> liquid_cells;
    for (const Cand &candidate : all) {
        bool covered = false;
        if (candidate.l->liquid) {
            const Vector3 p = candidate.l->pos;
            const v3s16 cell((s16)std::floor(p.x/4), (s16)std::floor(p.y/4), (s16)std::floor(p.z/4));
            for (int z = -1; z <= 1 && !covered; ++z)
                for (int y = -1; y <= 1 && !covered; ++y)
                    for (int x = -1; x <= 1 && !covered; ++x) {
                        auto found = liquid_cells.find(cell + v3s16(x,y,z));
                        if (found == liquid_cells.end())
                            continue;
                        for (const Vector3 &kept : found->second)
                            if (p.distance_squared_to(kept) < 12.25f) {
                                covered = true;
                                break;
                            }
                    }
            if (!covered)
                liquid_cells[cell].push_back(p);
        }
        if (!covered)
            spread.push_back(candidate);
    }
    all.swap(spread);
    all.erase(std::remove_if(all.begin(), all.end(), [](const Cand &c) {
        return c.score >= 64.0f;
    }), all.end());
    m_lights_in_range = (int)all.size();
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
    set_view_shader_parameter(
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
            // Nearby samples of one broad liquid emitter should not trade
            // places for tiny camera-distance improvements. Keep ordinary
            // newly placed torches' immediate admission unchanged.
            if (all[i].l->liquid && holder[victim]->l->liquid &&
                    holder[victim]->score - all[i].score < 2.0f)
                continue;
            held.erase(holder[victim]->key);
            holder[victim] = &all[i];
            held.insert(all[i].key);
        }
    }

    // Rank shadow candidates separately, retaining current owners with a
    // two-node advantage. Distance and emitter reach determine importance;
    // the stable key breaks ties. Fading lights also consume their map slot.
    struct ShadowCandidate { size_t slot; float score; int64_t key; };
    std::vector<ShadowCandidate> shadow_candidates;
    if (shadowed_pool) {
        for (size_t s = 0; s < slots; ++s) {
            const auto *c = holder[s];
            const LightSlot &old = m_light_slot[s];
            if (!c && (!old.key || old.fade <= 0.15f)) continue;
            const Vector3 pos = c ? c->l->pos : old.pos;
            const int64_t key = c ? c->key : old.key;
            const bool retained = m_light_pool[s]->has_shadow() && key == old.key;
            const float distance = pos.distance_to(around);
            if (distance > m_lamp_shadow_distance + (retained ? 2.0f : 0.0f)) continue;
            const float level = c ? c->l->level : old.level;
            shadow_candidates.push_back({s, distance - range_of(level) -
                    (retained ? 2.0f : 0.0f), key});
        }
        std::sort(shadow_candidates.begin(), shadow_candidates.end(),
                [](const ShadowCandidate &a, const ShadowCandidate &b) {
                    return a.score != b.score ? a.score < b.score : a.key < b.key;
                });
    }
    std::vector<bool> selected_shadow(slots, false);
    for (size_t i = 0; i < shadow_candidates.size() && i < (size_t)m_shadow_lamps; ++i)
        selected_shadow[shadow_candidates[i].slot] = true;

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
            slot.liquid = c->l->liquid;
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
        // Each spaced liquid lamp represents a patch of glowing surface.
        // Compensate for the spacing so flat banks receive useful spill.
        const float want_energy = energy_of(slot.level) * slot.fade * flicker
                * (slot.liquid ? 2.5f : 1.0f);
        if (ol->get_position() != slot.pos)
            ol->set_position(slot.pos);
        if (ol->get_color() != slot.color)
            ol->set_color(slot.color);
        if (ol->get_param(Light3D::PARAM_RANGE) != want_range)
            ol->set_param(Light3D::PARAM_RANGE, want_range);
        if (ol->get_param(Light3D::PARAM_ENERGY) != want_energy)
            ol->set_param(Light3D::PARAM_ENERGY, want_energy);
        // A point lamp approximates a broad emitting patch. Its sharp
        // specular hotspot otherwise slides across the cave as the eye moves.
        const float want_specular = slot.liquid ? 0.0f : 1.0f;
        if (ol->get_param(Light3D::PARAM_SPECULAR) != want_specular)
            ol->set_param(Light3D::PARAM_SPECULAR, want_specular);
        // Keep pools of lamplight distinct. A shallower falloff fills the
        // dark gaps between sources and flattens the room's lighting.
        if (ol->get_param(Light3D::PARAM_ATTENUATION) != 1.5f)
            ol->set_param(Light3D::PARAM_ATTENUATION, 1.5f);
        if (!ol->is_visible())
            ol->set_visible(true);
        const bool want_shadow = selected_shadow[s];
        if (ol->has_shadow() != want_shadow)
            ol->set_shadow(want_shadow);
    }
    updateLampOcclusion(around);
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
            pc = f.visuals->getColor(f, n.getParam2());
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
