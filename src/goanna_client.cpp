// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_client.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
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
#include "util/string.h"
#include "translation.h"
#include "transplant/localplayer.h"
#include "client/mapblock_mesh.h"
#include "client/tile.h"
#include "client/node_visuals.h"
#include "nodedef.h"
#include <SMesh.h>
#include <CMeshBuffer.h>
#include <SMaterial.h>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstdlib>
#include <algorithm>
#include <set>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace goanna {
struct MaterialKey {
    u32 texture_id = 0;
    u32 shader_id = 0;       // Goanna shader source id (carries Luanti's material type)
    bool backface_culling = true;
    uint64_t hash() const {
        return ((uint64_t)texture_id << 24) | ((uint64_t)(shader_id & 0xffff) << 1) | (backface_culling ? 1 : 0);
    }
};
}
#include "mapblock.h"
#include "version.h"

using namespace godot;

namespace goanna {

GoannaClient::GoannaClient() {}
GoannaClient::~GoannaClient() {}

String GoannaClient::hello() const {
    return "goanna: extension loaded";
}

String GoannaClient::luanti_version() const {
    return String("luanti core ") + g_version_hash;
}

void GoannaClient::connect_to(const String &host, int port, const String &player_name,
        const String &password) {
    // Luanti's base texture pack lives in the luanti/ checkout next to project/.
    String share = ProjectSettings::get_singleton()->globalize_path("res://../luanti");
    GoannaSession::setSharePath(share.utf8().get_data());
    m_session = std::make_unique<GoannaSession>();
    m_session->start(host.utf8().get_data(), (uint16_t)port, player_name.utf8().get_data(),
            password.utf8().get_data());
}

void GoannaClient::disconnect_from_server() {
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
    d["blocks_meshed"] = (int)m_block_nodes.size();
    d["entities"] = m_entities ? m_entities->count() : 0;
    d["media_received"] = (int)s.media_received;
    d["materials"] = m_materials.size();
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

void GoannaClient::set_player_pose(const Vector3 &pos, float pitch_deg, float yaw_deg) {
    if (!m_session)
        return;
    m_session->setPlayerPose(v3f(pos.x, pos.y, -pos.z), pitch_deg, yaw_deg);
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

Dictionary GoannaClient::inventory_state() {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    Inventory *inv = m_session->inventory();
    d["version"] = (int)m_session->inventoryVersion();
    Dictionary lists;
    if (inv) {
        IItemDefManager *idef = m_session->getItemDefManager();
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
    }
    d["lists"] = lists;
    return d;
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

String GoannaClient::inventory_formspec() const {
    return m_session ? String::utf8(m_session->inventoryFormspec().c_str()) : String();
}

Array GoannaClient::take_shown_formspecs() {
    Array out;
    if (!m_session)
        return out;
    for (auto &fs : m_session->takeShownFormspecs()) {
        Dictionary d;
        d["formspec"] = String::utf8(fs.first.c_str());
        d["formname"] = String::utf8(fs.second.c_str());
        out.push_back(d);
    }
    return out;
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

Dictionary GoannaClient::step_interact(double dt, bool dig, bool place, bool place_pressed) {
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

void GoannaClient::set_time_of_day_override(float tod) {
    if (m_session)
        m_session->setTimeOfDayOverride(tod);
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
    c.jump = keys.get("jump", false);
    c.sneak = keys.get("sneak", false);
    c.aux1 = keys.get("aux1", false);
    c.pitch = -pitch_deg;
    c.yaw = yaw_deg;
    c.setMovementFromKeys();

    if (dt > 0.1) dt = 0.1;
    if (dt > 0)
        m_session->stepPlayer((float)dt);

    v3f pos = p->getPosition();
    v3f eye = pos + p->getEyeOffset();
    // report to server (nodes)
    m_session->setPlayerPose(pos / BS, p->getPitch(), p->getYaw());
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
    }
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(key.texture_id);
    Ref<ImageTexture> tex = gt ? gt->godotTexture() : Ref<ImageTexture>();
    MaterialType mtype = m_session->shsrc().materialType(key.shader_id);
    video::E_MATERIAL_TYPE base = m_session->shsrc().baseMaterial(key.shader_id);
    u8 emissive = m_session->emissiveLevel(key.texture_id);
    if (getenv("GOANNA_DEBUG_MATERIALS")) {
        UtilityFunctions::print("goanna material: tex=", key.texture_id, " '",
                String(m_session->tsrc()->getTextureName(key.texture_id).c_str()),
                "' shader=", key.shader_id, " mtype=", (int)mtype, " base=", (int)base,
                " emissive=", (int)emissive, " cull=", key.backface_culling);
    }

    // --- shader variants by Luanti material type ---
    Ref<Shader> sh;
    switch (mtype) {
    case TILE_MATERIAL_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_TRANSPARENT:
    case TILE_MATERIAL_WAVING_LIQUID_BASIC:
        sh = m_sh_water; break;
    case TILE_MATERIAL_WAVING_LEAVES:
        sh = m_sh_leaves; break;
    case TILE_MATERIAL_WAVING_PLANTS:
        sh = m_sh_plants; break;
    case TILE_MATERIAL_ALPHA:
    case TILE_MATERIAL_PLAIN_ALPHA:
        sh = m_sh_glass; break;
    default:
        break;
    }
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
            mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
            mat->set_depth_draw_mode(BaseMaterial3D::DEPTH_DRAW_ALWAYS);
        } else if (base == video::EMT_TRANSPARENT_ALPHA_CHANNEL_REF || (gt && gt->hasAlpha())) {
            mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR);
            mat->set_alpha_scissor_threshold(0.5f);
        }
        if (mtype == TILE_MATERIAL_LIQUID_OPAQUE || mtype == TILE_MATERIAL_WAVING_LIQUID_OPAQUE)
            mat->set_roughness(0.35f); // lava-like
        if (emissive > 0) {
            // light-emitting node: glow with its own texture; SDFGI picks this up
            mat->set_feature(BaseMaterial3D::FEATURE_EMISSION, true);
            mat->set_texture(BaseMaterial3D::TEXTURE_EMISSION, tex);
            mat->set_emission(Color(1, 1, 1));
            mat->set_emission_energy_multiplier(0.6f + 2.4f * (emissive / 14.0f));
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
        if (f.light_source < 6)
            continue;
        NodeLight l;
        l.pos = Vector3(bp.X * MAP_BLOCKSIZE + x, bp.Y * MAP_BLOCKSIZE + y, -(bp.Z * MAP_BLOCKSIZE + z));
        l.level = f.light_source / 14.0f;
        // colour from the node's first tile (torch textures average to warm orange)
        video::SColor c(255, 255, 220, 160);
        if (f.visuals && f.visuals->tiles[0].layers[0].texture_id) {
            std::string tname = m_session->tsrc()->getTextureName(f.visuals->tiles[0].layers[0].texture_id);
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
    if (!m_entities)
        m_entities = std::make_unique<EntityRenderer>(this);
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    if (dt > 0.1) dt = 0.1;
    m_session->stepObjects((float)dt);
    m_entities->sync(*m_session, (float)dt, Vector3());
}

Array GoannaClient::entity_list() {
    if (!m_session || !m_entities)
        return Array();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->list(*m_session);
}

void GoannaClient::update_lights(const Vector3 &around, int max_lights) {
    std::vector<const NodeLight *> all;
    for (auto &kv : m_block_lights)
        for (auto &l : kv.second)
            if (l.pos.distance_squared_to(around) < 64.0f * 64.0f)
                all.push_back(&l);
    std::sort(all.begin(), all.end(), [&](const NodeLight *a, const NodeLight *b) {
        return a->pos.distance_squared_to(around) < b->pos.distance_squared_to(around);
    });
    if ((int)all.size() > max_lights)
        all.resize(max_lights);
    while ((int)m_light_pool.size() < max_lights) {
        OmniLight3D *ol = memnew(OmniLight3D);
        ol->set_shadow(false);
        ol->set_visible(false);
        add_child(ol);
        m_light_pool.push_back(ol);
    }
    for (size_t i = 0; i < m_light_pool.size(); ++i) {
        OmniLight3D *ol = m_light_pool[i];
        if (i < all.size()) {
            const NodeLight *l = all[i];
            // Shadows on the nearest few only: omni shadows are cube maps and
            // each costs six depth passes.
            ol->set_shadow(i < 8);
            ol->set_position(l->pos + Vector3(0.5f, 0.5f, -0.5f) * 0.0f);
            ol->set_color(l->color);
            ol->set_param(Light3D::PARAM_RANGE, 4.0f + 10.0f * l->level);
            ol->set_param(Light3D::PARAM_ENERGY, 1.5f + 4.0f * l->level);
            ol->set_param(Light3D::PARAM_ATTENUATION, 1.5f);
            ol->set_visible(true);
        } else {
            ol->set_visible(false);
        }
    }
}

int GoannaClient::poll_blocks(int max_blocks) {
    if (!m_session)
        return 0;
    if (m_session->prepareContentIfReady())
        return 0;
    std::vector<v3s16> fresh_raw = m_session->takeNewBlocks();
    std::vector<v3s16> fresh;
    {
        std::set<v3s16> seen;
        for (const v3s16 &bp : fresh_raw)
            if (seen.insert(bp).second)
                fresh.push_back(bp);
    }
    int done = 0;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    for (const v3s16 &bp : fresh) {
        if (done >= max_blocks) {
            m_session->requeueBlock(bp);
            continue;
        }
        MapBlock *block = m_session->getBlock(bp);
        if (!block)
            continue;
        std::unique_ptr<MapBlockMesh> bm = meshBlock(*m_session, block);
        harvestLights(bp, block);
        MeshInstance3D *mi = nullptr;
        auto it = m_block_nodes.find(bp);
        if (it != m_block_nodes.end())
            mi = it->second;
        Ref<ArrayMesh> mesh;
        mesh.instantiate();
        int si = 0;
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
                PackedVector3Array verts, norms;
                PackedVector2Array uvs;
                PackedColorArray cols;
                PackedInt32Array idx;
                verts.resize(nv); norms.resize(nv); uvs.resize(nv); cols.resize(nv);
                for (u32 i = 0; i < nv; ++i) {
                    // Luanti mesh space (BS units, block-local) -> Godot nodes; z mirrored
                    verts[i] = Vector3(v[i].Pos.X / BS + bp.X * MAP_BLOCKSIZE,
                            v[i].Pos.Y / BS + bp.Y * MAP_BLOCKSIZE,
                            -(v[i].Pos.Z / BS + bp.Z * MAP_BLOCKSIZE));
                    norms[i] = Vector3(v[i].Normal.X, v[i].Normal.Y, -v[i].Normal.Z);
                    uvs[i] = Vector2(v[i].TCoords.X, v[i].TCoords.Y);
                    cols[i] = Color(v[i].Color.getRed() / 255.0f, v[i].Color.getGreen() / 255.0f,
                            v[i].Color.getBlue() / 255.0f, v[i].Color.getAlpha() / 255.0f);
                }
                // Irrlicht (left-handed) front faces are counter-clockwise as
                // stored; mirroring z makes them clockwise, which is Godot's
                // front-face winding, so the index order is kept as is.
                idx.resize(ni);
                for (u32 i = 0; i < ni; ++i)
                    idx[i] = idx16[i];
                Array arrays;
                arrays.resize(Mesh::ARRAY_MAX);
                arrays[Mesh::ARRAY_VERTEX] = verts;
                arrays[Mesh::ARRAY_NORMAL] = norms;
                arrays[Mesh::ARRAY_TEX_UV] = uvs;
                arrays[Mesh::ARRAY_COLOR] = cols;
                arrays[Mesh::ARRAY_INDEX] = idx;
                mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
                const video::SMaterial &m = buf->getMaterial();
                MaterialKey key;
                GoannaTexture *gt = dynamic_cast<GoannaTexture *>(m.getTexture(0));
                key.texture_id = gt ? gt->id() : 0;
                key.shader_id = GoannaShaderSource::isShaderMaterial(m.MaterialType)
                        ? GoannaShaderSource::shaderIdFromMaterial(m.MaterialType) : 0;
                key.backface_culling = m.BackfaceCulling;
                mesh->surface_set_material(si++, materialFor(key));
            }
        }
        if (si == 0) {
            if (mi) {
                mi->queue_free();
                m_block_nodes.erase(bp);
            }
            ++done;
            continue;
        }
        if (!mi) {
            mi = memnew(MeshInstance3D);
            add_child(mi);
            m_block_nodes[bp] = mi;
        }
        mi->set_mesh(mesh);
        ++done;
    }
    return done;
}

void GoannaClient::_bind_methods() {
    ClassDB::bind_method(D_METHOD("hello"), &GoannaClient::hello);
    ClassDB::bind_method(D_METHOD("luanti_version"), &GoannaClient::luanti_version);
    ClassDB::bind_method(D_METHOD("connect_to", "host", "port", "player_name", "password"),
            &GoannaClient::connect_to);
    ClassDB::bind_method(D_METHOD("disconnect_from_server"), &GoannaClient::disconnect_from_server);
    ClassDB::bind_method(D_METHOD("status"), &GoannaClient::status);
    ClassDB::bind_method(D_METHOD("poll_blocks", "max_blocks"), &GoannaClient::poll_blocks);
    ClassDB::bind_method(D_METHOD("block_mesh_count"), &GoannaClient::block_mesh_count);
    ClassDB::bind_method(D_METHOD("material_count"), &GoannaClient::material_count);
    ClassDB::bind_method(D_METHOD("set_player_pose", "pos", "pitch_deg", "yaw_deg"),
            &GoannaClient::set_player_pose);
    ClassDB::bind_method(D_METHOD("server_player_position"), &GoannaClient::server_player_position);
    ClassDB::bind_method(D_METHOD("step_player", "dt", "keys", "pitch_deg", "yaw_deg"), &GoannaClient::step_player);
    ClassDB::bind_method(D_METHOD("sky_state"), &GoannaClient::sky_state);
    ClassDB::bind_method(D_METHOD("update_lights", "around", "max_lights"), &GoannaClient::update_lights);
    ClassDB::bind_method(D_METHOD("sync_entities", "dt"), &GoannaClient::sync_entities);
    ClassDB::bind_method(D_METHOD("take_chat"), &GoannaClient::take_chat);
    ClassDB::bind_method(D_METHOD("send_chat", "message"), &GoannaClient::send_chat);
    ClassDB::bind_method(D_METHOD("hp"), &GoannaClient::hp);
    ClassDB::bind_method(D_METHOD("breath"), &GoannaClient::breath);
    ClassDB::bind_method(D_METHOD("hud_state"), &GoannaClient::hud_state);
    ClassDB::bind_method(D_METHOD("inventory_state"), &GoannaClient::inventory_state);
    ClassDB::bind_method(D_METHOD("texture", "name"), &GoannaClient::texture);
    ClassDB::bind_method(D_METHOD("inventory_formspec"), &GoannaClient::inventory_formspec);
    ClassDB::bind_method(D_METHOD("take_shown_formspecs"), &GoannaClient::take_shown_formspecs);
    ClassDB::bind_method(D_METHOD("send_inventory_fields", "formname", "fields"), &GoannaClient::send_inventory_fields);
    ClassDB::bind_method(D_METHOD("set_wield_index", "index"), &GoannaClient::set_wield_index);
    ClassDB::bind_method(D_METHOD("wield_index"), &GoannaClient::wield_index);
    ClassDB::bind_method(D_METHOD("inventory_action", "action"), &GoannaClient::inventory_action);
    ClassDB::bind_method(D_METHOD("step_interact", "dt", "dig", "place", "place_pressed"), &GoannaClient::step_interact);
    ClassDB::bind_method(D_METHOD("entity_count"), &GoannaClient::entity_count);
    ClassDB::bind_method(D_METHOD("entity_positions"), &GoannaClient::entity_positions);
    ClassDB::bind_method(D_METHOD("entity_list"), &GoannaClient::entity_list);
    ClassDB::bind_method(D_METHOD("set_time_of_day_override", "tod"), &GoannaClient::set_time_of_day_override);
}

} // namespace goanna
