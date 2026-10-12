// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// GoannaClient's world materials. keyForIrr turns a Luanti material into a
// MaterialKey, and materialFor builds and caches the Godot material for one
// from the shaders in project/shaders/. Also here: the flame and crack
// overlay materials and the fake liquid textures; animated node tiles
// (step_node_animation and the frames it shows); and the settings that change
// materials (the per channel strengths, the texture path, size and map, auto
// bump, solid ice, the flame material and procedural grass), with
// material_diagnostics to check what was bound.
//
// Threads: Godot's main thread only. A setting that changes materials asks
// the session to mesh the loaded blocks again, under its map lock.

#include "goanna_client_internal.h"

using namespace godot;

namespace goanna {

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
    // (docs/design/pbr-plan.md, "A material for every node"), and its
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

void GoannaClient::set_iris_gbuffers(const Ref<GoannaIrisGbuffers> &gbuffers) {
    m_iris_gbuffers = gbuffers;
    m_iris_block_ids = PackedInt32Array();
    m_iris_block_names = 0;
    clearMaterials();
}

bool GoannaClient::applyIrisGbuffers(const Ref<ShaderMaterial> &sm, int surface) {
    if (m_iris_gbuffers.is_null())
        return false;
    Ref<Shader> sh = m_iris_gbuffers->shader(surface);
    if (sh.is_null())
        return false;
    sm->set_shader(sh);
    if (surface == GoannaIrisGbuffers::SURFACE_WATER) {
        // Every water surface is the one block; Mineclonia's water has no
        // entry in the texture map the block table is built from.
        sm->set_shader_parameter("goanna_iris_entity_override", m_iris_gbuffers->block_id("water"));
        return true;
    }
    const auto &names = m_session->materialTable().block_names;
    if (m_iris_block_ids.is_empty() || m_iris_block_names != names.size()) {
        PackedStringArray pn;
        for (const auto &n : names)
            pn.push_back(String(n.c_str()));
        m_iris_block_ids = m_iris_gbuffers->block_ids(pn);
        m_iris_block_names = names.size();
    }
    sm->set_shader_parameter("goanna_iris_block_ids", m_iris_block_ids);
    return true;
}

Ref<Material> GoannaClient::irisShadowMaterial(const Ref<Material> &base) {
    Ref<ShaderMaterial> sm = base;
    const uint64_t id = base.is_valid() ? base->get_instance_id() : 0;
    auto it = m_iris_shadow_mats.find(id);
    if (it != m_iris_shadow_mats.end())
        return it->second;
    Ref<Shader> shadow;
    if (sm.is_valid() && sm->get_shader().is_valid()) {
        // Which of the pack's surfaces the base is, by its shader; the
        // shadow program was translated for each of them.
        for (int s : {GoannaIrisGbuffers::SURFACE_TERRAIN, GoannaIrisGbuffers::SURFACE_CUTOUT,
                     GoannaIrisGbuffers::SURFACE_FOLIAGE})
            if (sm->get_shader() == m_iris_gbuffers->shader(s)) {
                shadow = m_iris_gbuffers->shadow_shader(s);
                break;
            }
    }
    Ref<Material> out;
    if (shadow.is_valid()) {
        Ref<ShaderMaterial> m;
        m.instantiate();
        m->set_shader(shadow);
        // Its uniforms are the shell's, which the base already has set: the
        // texture array or texture, the animation table, the block numbers.
        TypedArray<Dictionary> uniforms = shadow->get_shader_uniform_list();
        for (int i = 0; i < uniforms.size(); ++i) {
            StringName name = Dictionary(uniforms[i])["name"];
            Variant v = sm->get_shader_parameter(name);
            if (v.get_type() != Variant::NIL)
                m->set_shader_parameter(name, v);
        }
        out = m;
    } else {
        if (m_iris_shadow_none.is_null()) {
            Ref<Shader> none;
            none.instantiate();
            none->set_code("shader_type spatial;\nrender_mode unshaded, cull_disabled;\n"
                           "void vertex() { POSITION = vec4(2.0, 2.0, 2.0, 1.0); }\n"
                           "void fragment() { ALBEDO = vec3(1.0); }\n");
            Ref<ShaderMaterial> m;
            m.instantiate();
            m->set_shader(none);
            m_iris_shadow_none = m;
        }
        out = m_iris_shadow_none;
    }
    m_iris_shadow_mats[id] = out;
    return out;
}

void GoannaClient::irisShadowTwin(MeshInstance3D *node) {
    if (!node || m_iris_gbuffers.is_null() || !m_iris_gbuffers->has_shadow())
        return;
    MeshInstance3D *twin = Object::cast_to<MeshInstance3D>(node->get_node_or_null(NodePath("iris_shadow")));
    Ref<Mesh> mesh = node->get_mesh();
    if (mesh.is_null() || mesh->get_surface_count() == 0) {
        if (twin)
            twin->set_mesh(Ref<Mesh>());
        return;
    }
    if (!twin) {
        twin = memnew(MeshInstance3D);
        twin->set_name("iris_shadow");
        // The shadow layer alone: only main.gd's shadow camera sees it, and
        // it casts nothing into Godot's own shadow maps or GI.
        twin->set_layer_mask(GoannaIrisGbuffers::SHADOW_LAYER);
        twin->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
        twin->set_gi_mode(GeometryInstance3D::GI_MODE_DISABLED);
        node->add_child(twin);
    }
    twin->set_custom_aabb(node->get_custom_aabb());
    twin->set_extra_cull_margin(node->get_extra_cull_margin());
    twin->set_mesh(mesh);
    for (int i = 0; i < mesh->get_surface_count(); ++i)
        twin->set_surface_override_material(i, irisShadowMaterial(node->get_active_material(i)));
}

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

// The shader uniform names are the channel names; the defaults here must match
// the shaders' own, because a material built before any slider moves gets
// whatever the shader declares.
static const std::map<std::string, float> kMatStrengthDefaults = {
    {"normal", 1.0f}, {"ao", 1.0f}, {"roughness", 1.0f},
    {"specular", 1.0f}, {"emission", 4.0f}, {"sss", 1.0f},
    // Per vertex node light and occlusion, docs/systems/mesh-attributes.md. Here
    // rather than as fixed uniforms so they can be swept at runtime, which is
    // the only way to A/B them without the world streaming differently between
    // two runs and swamping the difference being measured. vertex_ao_light
    // is how much the traced occlusion may touch direct light: 0.3, so the
    // corners still read under the sun (nodes_array_common.gdshaderinc says
    // why). The shader moved to 0.3 on 2026-08-24 but this table kept 0
    // until 2026-10-11, and since it is set on every material, play ran at
    // 0 on every tier (docs/perf/vertex-ao-2026-10-11).
    {"sky_light", 1.0f}, {"vertex_ao", 1.0f}, {"vertex_ao_light", 0.3f},
    // stale is 0: pulling remembered terrain toward grey is a per tier
    // signal painted into the frame, and the far field is judged by there
    // being none (docs/develop/launch-target.md, "Rendering acceptance":
    // near and far share one colour and light path). The channel stays so
    // the signal can be turned on to see what is remembered.
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
            // A shader pack's terrain program, when one is loaded; the
            // uniforms below are the same either way.
            applyIrisGbuffers(sm, scissor ? GoannaIrisGbuffers::SURFACE_CUTOUT
                                          : GoannaIrisGbuffers::SURFACE_TERRAIN);
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
        if (sh == m_sh_water)
            applyIrisGbuffers(sm, GoannaIrisGbuffers::SURFACE_WATER);
        else if (sh == m_sh_leaves || sh == m_sh_plants)
            applyIrisGbuffers(sm, GoannaIrisGbuffers::SURFACE_FOLIAGE);
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

} // namespace goanna
