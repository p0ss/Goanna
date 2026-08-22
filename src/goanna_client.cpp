// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_client.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh.hpp>
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
        for (auto &kv : m_block_nodes)
            m_session->requeueBlock(kv.first);
    }
}

float GoannaClient::bevel() const { return g_goanna_bevel; }

int GoannaClient::prune_blocks(int radius) {
    if (!m_session)
        return 0;
    int dropped = m_session->pruneDistantBlocks(radius);
    if (dropped > 0) {
        // forget the meshes for anything that is gone
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto it = m_block_nodes.begin(); it != m_block_nodes.end();) {
            if (!m_session->getBlock(it->first)) {
                if (it->second)
                    it->second->queue_free();
                m_block_lights.erase(it->first);
                it = m_block_nodes.erase(it);
            } else {
                ++it;
            }
        }
        // And the far tiers: a region whose members are gone rebuilds empty
        // and frees its mesh on the next poll. Far blocks are not live and
        // stay; a pruned live block is in the store now and comes back as a
        // far block on the next scan.
        for (auto it = m_block_tier.begin(); it != m_block_tier.end();) {
            if (!m_far_blocks.count(it->first) && !m_session->getBlock(it->first)) {
                lodForget(it->first);
                it = m_block_tier.erase(it);
            } else {
                ++it;
            }
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
void GoannaClient::set_view_fov(float degrees) {
    if (m_session)
        m_session->cameraFov = degrees;
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
        for (auto &kv : m_block_nodes)
            m_session->requeueBlock(kv.first);
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
        for (auto &kv : m_block_nodes)
            m_session->requeueBlock(kv.first);
    }
}
bool GoannaClient::solid_ice() const { return m_solid_ice; }

GoannaClient::~GoannaClient() {}

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

void GoannaClient::connect_to(const String &host, int port, const String &player_name,
        const String &password) {
    // Luanti's base texture pack lives in the luanti/ checkout next to project/.
    String share = ProjectSettings::get_singleton()->globalize_path("res://../luanti");
    GoannaSession::setSharePath(share.utf8().get_data());
    m_session = std::make_unique<GoannaSession>();
    if (m_session->tsrc())
        m_session->tsrc()->setInferredReliefStrength(m_auto_bump);
    if (!m_store_root.is_empty())
        m_session->setStoreRoot(std::string(m_store_root.utf8().get_data()));
    m_far_blocks.clear();
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
    m_lod_chain_missing.clear();
    m_lod_tiles.entries.clear();
    m_lod_water.clear();
    m_fades.clear();
    if (!m_texture_map.is_empty())
        m_session->setTextureMap(std::string(m_texture_map.utf8().get_data()));
    // GoannaSession's constructor is what creates g_settings; set_texture_path
    // could only remember the value, not apply it, if called first as
    // documented. Apply it now, before start() begins requesting textures.
    if (!m_texture_path.is_empty() && g_settings)
        g_settings->set("texture_path", std::string(m_texture_path.utf8().get_data()));
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
    d["resident_blocks"] = m_session ? (int)m_session->residentBlocks() : 0;
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
    m_session->setPlayerPose(luanti, pitch_deg, yaw_deg);
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

// Every node surface declares CUSTOM0 as four unsigned bytes: block light,
// sky light, ambient occlusion, spare. RGBA8_UNORM happens to be format 0, so
// this constant is zero today; it is written out rather than assumed, because
// the day the packing changes a silent 0 would be very hard to find.
static const uint64_t kNodeSurfaceFlags =
        (uint64_t)Mesh::ARRAY_CUSTOM_RGBA8_UNORM << Mesh::ARRAY_FORMAT_CUSTOM0_SHIFT;

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
        // Only commit to the array path if the Godot array actually built:
        // otherwise the key would name a texture with no 2D image behind it
        // and the tile would render untextured white.
        bool array_ready = m.BackfaceCulling && !cracked &&
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
            Ref<Texture2DArray> nrm = getenv("GOANNA_NO_NORMAL")
                    ? Ref<Texture2DArray>()
                    : agt->godotArraySuffixed(*m_session->tsrc(), "_n");
            Ref<Texture2DArray> spc = agt->godotArraySuffixed(*m_session->tsrc(), "_s");
            for (const auto &d : kMatStrengthDefaults)
                sm->set_shader_parameter(String(d.first.c_str()) + String("_strength"),
                        material_strength(String(d.first.c_str())));
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
            // light-emitting node: glow with its own texture; SDFGI picks this
            // up. Quadratic in the light level, so a dim source (firefly bush,
            // light_source 2) barely glows instead of rendering as a white
            // fullbright plant, while torches and glowstone stay bright.
            float lvl = emissive / 14.0f;
            mat->set_feature(BaseMaterial3D::FEATURE_EMISSION, true);
            mat->set_texture(BaseMaterial3D::TEXTURE_EMISSION, tex);
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

Dictionary GoannaClient::render_stats() {
    Dictionary d;
    d["mesh_ms"] = m_ms_mesh;
    d["upload_ms"] = m_ms_upload;
    d["lights_ms"] = m_ms_lights;
    d["motes_ms"] = m_ms_motes;
    d["entities_ms"] = m_ms_entities;
    d["blocks_meshed_last"] = m_last_meshed;
    d["blocks_queued"] = m_last_queue;
    d["block_meshes"] = (int)m_block_nodes.size();
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
    d["poll_max_ms"] = std::max(m_ms_poll_max, m_ms_poll_max_last);
    d["lod_regions_built_last"] = m_lod_last_built;
    int lod_regions = 0, lod_faces = 0, lod_quads = 0, lod_surfaces = 0, lod_dirty = 0;
    for (auto &kv : m_lod_regions) {
        if (kv.second.node)
            ++lod_regions;
        lod_faces += kv.second.faces;
        lod_quads += kv.second.quads;
        lod_surfaces += kv.second.surfaces;
        if (kv.second.dirty)
            ++lod_dirty;
    }
    d["lod_regions"] = lod_regions;
    d["lod_regions_dirty"] = lod_dirty;
    d["lod_faces"] = lod_faces;
    d["lod_quads"] = lod_quads;
    d["lod_surfaces"] = lod_surfaces;
    d["lod_chains"] = (int)m_lod_chains.size();
    d["lod_chain_queue"] = (int)m_lod_chain_queue.size();
    d["far_blocks"] = (int)m_far_blocks.size();
    d["far_remote"] = (int)m_far_remote.size();
    d["far_grant"] = m_session ? m_session->farRenderingGrant() : 0;
    d["far_extent"] = m_far_extent;
    if (m_session && m_session->store()) {
        d["store_blocks"] = (int64_t)m_session->store()->blocksKnown();
        d["store_mb"] = (double)m_session->store()->bytes() / (1024.0 * 1024.0);
    }
    Dictionary tiers;
    for (auto &kv : m_block_tier) {
        Variant cur = tiers.get(kv.second, 0);
        tiers[kv.second] = (int)cur + 1;
    }
    d["lod_tiers"] = tiers;
    RenderingServer *rs = RenderingServer::get_singleton();
    if (rs) {
        d["draw_calls"] = (int)rs->get_rendering_info(RenderingServer::RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME);
        d["primitives"] = (int64_t)rs->get_rendering_info(RenderingServer::RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME);
        d["objects"] = (int)rs->get_rendering_info(RenderingServer::RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME);
        d["video_mem_mb"] = (double)rs->get_rendering_info(RenderingServer::RENDERING_INFO_VIDEO_MEM_USED) / (1024.0 * 1024.0);
    }
    return d;
}

Array GoannaClient::entity_list() {
    if (!m_session || !m_entities)
        return Array();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->list(*m_session);
}

// The render layer that light emitting node faces are drawn on. Node lights
// are told not to accept shadow casters from it; the sun still does.
static const uint32_t GLOW_LAYER = 1u << 1;

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

    for (size_t s = 0; s < slots; ++s) {
        OmniLight3D *ol = m_light_pool[s];
        LightSlot &slot = m_light_slot[s];
        const Cand *c = holder[s];
        if (c) {
            if (slot.key != c->key) {
                ++m_light_churn;
                slot.key = c->key;
                slot.fade = 0.0f;
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

        // Only write when something actually differs. Re-setting a light's
        // transform every frame is not free: it dirties the shadow map for a
        // lamp that has not moved since it was placed.
        const float want_range = range_of(slot.level);
        const float want_energy = energy_of(slot.level) * slot.fade;
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
    if (m_session) { // every block may change tier
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_block_tier)
            m_session->requeueBlock(kv.first);
    }
}

void GoannaClient::set_lod_cell(int nodes) {
    // A chain level: 2, 4, 8 or 16, rounded down.
    int cell = 2;
    while (cell * 2 <= nodes && cell * 2 <= MAP_BLOCKSIZE)
        cell *= 2;
    if (cell == m_lod_cell)
        return;
    m_lod_cell = cell;
    lodReset();
}

// --- far rendering: tiers and regions (docs/far-rendering.md rungs 2, 3) ---

// Tier 0 is Luanti's full detail mesh. Tier t draws cells of
// lod_cell * 2^(t - 1) nodes, up to a whole block, from the block's chain.
int GoannaClient::lodTierCount() const {
    int tiers = 0;
    for (int c = m_lod_cell; c <= MAP_BLOCKSIZE; c *= 2)
        ++tiers;
    return tiers;
}

int GoannaClient::lodCellFor(int tier) const {
    int c = m_lod_cell;
    for (int t = 1; t < tier; ++t)
        c *= 2;
    return std::min(c, MAP_BLOCKSIZE);
}

// Region edge, in blocks. The cell size, so a region is 16 cells an axis
// whatever the tier: a rebuild costs about the same at every tier, a coarse
// tier covers proportionally more ground per draw call, and a near tier
// arrives in 64 node pieces rather than 128, which is what stops it coming
// in as a wall.
int GoannaClient::lodRegionBlocks(int tier) const {
    return std::clamp(lodCellFor(tier), 4, 16);
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
int GoannaClient::lodTierFor(const v3s16 &bp, const Vector3 &around) const {
    if (m_lod_distance <= 0)
        return 0;
    Vector3 centre((bp.X + 0.5f) * MAP_BLOCKSIZE, (bp.Y + 0.5f) * MAP_BLOCKSIZE,
            -(bp.Z + 0.5f) * MAP_BLOCKSIZE);
    const float d = Vector2(centre.x - around.x, centre.z - around.z).length();
    auto cur = m_block_tier.find(bp);
    const int current = cur == m_block_tier.end() ? 0 : cur->second;
    const int tiers = lodTierCount();
    auto threshold = [&](int t) {
        return (float)m_lod_distance * MAP_BLOCKSIZE * (float)(1 << (t - 1));
    };
    int desired = 0;
    for (int t = 1; t <= tiers; ++t)
        if (d > threshold(t))
            desired = t;
    if (desired < current && current >= 1 && d > threshold(current) * 0.85f)
        return current;
    return desired;
}

const BlockLodChain *GoannaClient::lodChain(v3s16 bp) {
    auto it = m_lod_chains.find(bp);
    if (it != m_lod_chains.end())
        return &it->second;
    if (!m_session)
        return nullptr;
    MapBlock *b = m_session->getBlock(bp);
    if (b) {
        BlockLodChain &ch = m_lod_chains[bp];
        buildLodChain(m_session->nodeDefs(), b, ch, BlockLodChain::levelForCell(m_lod_cell));
        return &ch;
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
    BlockLodChain &ch = m_lod_chains[bp];
    buildLodChain(m_session->nodeDefs(), stored.get(), ch, BlockLodChain::levelForCell(m_lod_cell));
    ch.stored = true;
    return &ch;
}

void GoannaClient::set_store_path(const String &root) {
    m_store_root = root;
}

void GoannaClient::set_far_distance(int nodes) {
    m_far_distance = std::clamp(nodes, 0, 4096);
    m_far_distance_explicit = true;
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
    const v3s16 centre((s16)std::floor(around.x / MAP_BLOCKSIZE), (s16)std::floor(around.y / MAP_BLOCKSIZE),
            (s16)std::floor(-around.z / MAP_BLOCKSIZE));
    if (!m_far_dirty && centre == m_far_centre && ms_since(m_far_last) < 2000.0)
        return;
    m_far_dirty = false;
    m_far_centre = centre;
    m_far_last = clock_t_::now();
    // out of range, or now live: let go
    for (auto it = m_far_blocks.begin(); it != m_far_blocks.end();) {
        const v3s16 d = *it - centre;
        const bool out = std::abs(d.X) > radius + 1 || std::abs(d.Y) > radius + 1 || std::abs(d.Z) > radius + 1;
        if (out || m_session->getBlock(*it)) {
            if (out) {
                lodForget(*it);
                m_block_tier.erase(*it);
            }
            m_far_remote.erase(*it);
            it = m_far_blocks.erase(it);
        } else {
            ++it;
        }
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
    // in range, in the store, not live, not yet drawn: assign
    std::vector<uint8_t> bits;
    const int R = BlockStore::kRegionBlocks;
    auto fdiv = [](int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    const v3s16 lo(fdiv(centre.X - radius, R), fdiv(centre.Y - radius, R), fdiv(centre.Z - radius, R));
    const v3s16 hi(fdiv(centre.X + radius, R), fdiv(centre.Y + radius, R), fdiv(centre.Z + radius, R));
    int added = 0;
    for (int rz = lo.Z; rz <= hi.Z; ++rz)
        for (int ry = lo.Y; ry <= hi.Y; ++ry)
            for (int rx = lo.X; rx <= hi.X; ++rx) {
                if (!m_session->storedRegionMask(v3s16(rx, ry, rz), bits))
                    continue;
                for (int i = 0; i < BlockStore::kSlots; ++i) {
                    if (!(bits[i >> 3] & (1u << (i & 7))))
                        continue;
                    const v3s16 bp(rx * R + (i % R), ry * R + ((i / R) % R), rz * R + (i / (R * R)));
                    const v3s16 d = bp - centre;
                    if (std::abs(d.X) > radius || std::abs(d.Y) > radius || std::abs(d.Z) > radius)
                        continue;
                    if (m_far_blocks.count(bp) || m_session->getBlock(bp))
                        continue;
                    const int tier = lodTierFor(bp, around);
                    if (tier < 1)
                        continue; // inside the live range: the server will send it
                    m_lod_chain_missing.erase(bp);
                    lodAssign(bp, tier);
                    m_block_tier[bp] = tier;
                    m_far_blocks.insert(bp);
                    ++added;
                }
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
        constexpr int kSectors = 8;
        constexpr float kPi = 3.14159265f;
        const size_t nrings = (size_t)radius + 2;
        std::vector<int> rings((size_t)kSectors * nrings, 0);
        std::vector<size_t> totals((size_t)kSectors, 0);
        for (const v3s16 &bp : m_far_blocks) {
            const v3s16 d = bp - centre;
            const int r = std::max(std::abs(d.X), std::abs(d.Z));
            if (r < 0 || r >= (int)nrings)
                continue;
            const float a = std::atan2((float)d.Z, (float)d.X); // -pi to pi
            int s = (int)std::floor((a + kPi) / (2.0f * kPi) * (float)kSectors);
            s = std::clamp(s, 0, kSectors - 1);
            ++rings[(size_t)s * nrings + (size_t)r];
            ++totals[(size_t)s];
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
        } else {
            std::sort(reach.begin(), reach.end());
            m_far_extent = reach[reach.size() / 4] * MAP_BLOCKSIZE;
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
    // How long to leave a partly generated area alone before asking again.
    // Long enough that a server generating steadily is not asked the same
    // question every second, short enough that a player standing still sees
    // the gaps close rather than waiting out the session.
    constexpr double kFarRetryMs = 20000.0;
    // The server refuses silently: an area outside its grant, a full queue,
    // a player it cannot find. Without an expiry, four such refusals would
    // stall every later request for the rest of the session. The areas stay
    // in m_far_requested, so an expired one is not asked again here.
    if (m_far_inflight > 0 && ms_since(m_far_asked) > 15000.0)
        m_far_inflight = 0;
    if (m_far_inflight >= 4)
        return;
    auto fdiv = [](int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
    const v3s16 ac(fdiv(centre.X, kEdge), fdiv(centre.Y, kEdge), fdiv(centre.Z, kEdge));
    const int aradius = radius / kEdge;
    // Vertical window: real terrain is nowhere near as tall as the horizontal
    // grant is wide, but a fixed one area either side (docs/far-rendering.md's
    // "seam" defect) was too narrow for a hill or a valley near the player.
    // Capped rather than matched to aradius, or a large grant turns this into
    // a scan of mostly sky and stone with nothing to summarise.
    const int varadius = std::min(aradius, 4);
    // Nearest unrequested area that is not entirely live and not entirely
    // known already. Both conditions used to be centre-of-area tests, which
    // left a band unasked: an area whose centre sat just past the live range
    // but whose near edge was still inside it, and an area where a single
    // sampled cell happened to be known. lodTakeSummaries already keeps only
    // the blocks that are neither live nor chained (a request for an area we
    // partly know just re-describes the part we already have), so asking
    // liberally here costs bandwidth, not correctness.
    v3s16 best(32767, 32767, 32767);
    int best_d = 1 << 30;
    for (int az = ac.Z - aradius; az <= ac.Z + aradius; ++az)
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
                if (ask != m_far_requested.end() &&
                        (ask->second.complete || ms_since(ask->second.asked) < kFarRetryMs))
                    continue;
                const int dx = (ax * kEdge + kEdge / 2) - centre.X;
                const int dz = (az * kEdge + kEdge / 2) - centre.Z;
                const int d2 = dx * dx + dz * dz;
                if (d2 >= best_d)
                    continue;
                // Skip an area only when the server would already be sending
                // every block in it: the live range reaches to its farthest
                // corner, not just its centre.
                const int live = m_session->wantedRange + 2;
                if (std::abs(dx) + kEdge / 2 < live && std::abs(dz) + kEdge / 2 < live)
                    continue;
                // Skip only once every sampled cell is already known, so a
                // corner the player has crossed does not hide the rest of the
                // area from ever being asked about.
                //
                // This is a shortcut for areas the store already covers, so it
                // must not apply to one the server has told us is only partly
                // generated. Those are the areas that never filled in: the
                // blocks the server did have made the sample look known, and
                // the area was skipped for the rest of the session, so the
                // ungenerated part stayed a gap no matter how long anyone
                // stood and watched. An incomplete answer beats a known
                // looking sample, and the retry delay above is what keeps it
                // from being asked constantly.
                const bool incomplete = ask != m_far_requested.end() && !ask->second.complete;
                bool fully_known = !incomplete;
                for (int b = 0; b < kEdge && fully_known; ++b)
                    fully_known = m_lod_chains.count(origin + v3s16(b, 0, b)) ||
                            m_far_blocks.count(origin + v3s16(b, 0, b));
                if (fully_known)
                    continue;
                best = origin;
                best_d = d2;
            }
    if (best_d == 1 << 30)
        return;
    m_far_requested[best].asked = clock_t_::now();
    if (m_far_inflight == 0)
        m_far_asked = clock_t_::now();
    ++m_far_inflight;
    m_session->requestFarSummary(best, kEdge, 16);
    if (getenv("GOANNA_DEBUG_LOD"))
        UtilityFunctions::print("LOD far: asked for area ", best.X, ",", best.Y, ",", best.Z);
}

// Parse "farsum <who> <ver> <cell> <ox> <oy> <oz> <edge> <names,csv>|<base64>"
// into coarse chains. Version 2: the per-block record is 21 bytes, a 4 by 4
// grid of surface heights (one byte each, 0 to 16) rather than one height for
// the whole block, so a slope reads as a slope instead of a stepped box; see
// the matching comment in goanna_server_mod/init.lua. Caller holds the map
// lock.
void GoannaClient::lodTakeSummaries() {
    if (!m_session)
        return;
    static const int kRecordSize = 21;
    for (const std::string &msg : m_session->takeFarSummaries()) {
        if (m_far_inflight > 0)
            --m_far_inflight;
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
        if (got != 7 || ver != 2) {
            UtilityFunctions::push_error("goanna_server_mod's far summary reply does not match "
                    "protocol version 2 (a v1 mod?); update goanna_server_mod. Message: ",
                    String(msg.substr(0, 80).c_str()));
            continue;
        }
        if (cell != 16 || edge <= 0 || edge > 16)
            continue;
        const size_t bar = msg.find('|', off);
        if (bar == std::string::npos)
            continue;
        // names
        std::vector<content_t> ids;
        ids.push_back(CONTENT_AIR); // index 0: none
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
        // generated means the area is done and never needs asking again;
        // anything less leaves it due for a retry, since the missing part is
        // terrain that does not exist yet rather than terrain we failed to
        // read.
        size_t known_records = 0;
        for (size_t i = 0; i < total; ++i)
            if (((const uint8_t *)blob.data())[i * kRecordSize] & 16)
                ++known_records;
        FarAsk &ask = m_far_requested[v3s16(ox, oy, oz)];
        ask.asked = clock_t_::now();
        ask.complete = known_records == total;
        // The wire record is a 4 by 4 grid of 4 node cells, the finest tier
        // this client's own lod_cell setting can use is not necessarily that
        // fine, so build at whichever tier's cell is the smallest one at
        // least that fine, grouping the wire cells up to it. At the default
        // lod_cell (4) that tier is 1 and the grouping is 1 for 1.
        int tier = 1;
        while (tier < lodTierCount() && lodCellFor(tier) < 4)
            ++tier;
        const int build_cell = lodCellFor(tier);
        const int group = std::max(1, build_cell / 4);
        const int n = std::max(1, MAP_BLOCKSIZE / build_cell);
        const int level = BlockLodChain::levelForCell(build_cell);
        int taken = 0;
        for (size_t i = 0; i < total; ++i) {
            const uint8_t *r = (const uint8_t *)blob.data() + i * kRecordSize;
            if (!(r[0] & 16))
                continue; // not generated: stays a hole, never invented
            const v3s16 bp(ox + (int)(i % edge), oy + (int)((i / edge) % edge),
                    oz + (int)(i / (edge * edge)));
            if (m_session->getBlock(bp) || m_lod_chains.count(bp))
                continue; // live or already known better
            const content_t top_c = r[17] < ids.size() ? ids[r[17]] : CONTENT_AIR;
            const content_t side_c = r[18] < ids.size() ? ids[r[18]] : top_c;
            const content_t side = side_c != CONTENT_AIR ? side_c : top_c;
            // LIGHT_SUN, not LIGHT_MAX. The wire carries Luanti's raw 0 to 15,
            // and 15 is what an open sky column holds; clamping to 14 first
            // put a summarised hillside at decode_light(14), 234, where the
            // same ground meshed live or read back from the store carries
            // decode_light(15), 255. That is a 7 per cent step in sky
            // visibility with no cause in the world, between two halves of the
            // same far field, and it survived into the sky fill and the
            // ambient term (docs/launch-target.md, R1). decode_light clamps to
            // LIGHT_SUN itself, so nothing here has to.
            const uint8_t day = decode_light(r[19]);
            const uint8_t night = decode_light(r[20]);
            const uint8_t cflags = LodLevel::kKnown | ((r[0] & 2) ? LodLevel::kOccludes : 0) |
                    ((r[0] & 4) ? LodLevel::kLit : 0);
            BlockLodChain &ch = m_lod_chains[bp];
            LodLevel &lv = ch.level[level];
            lv.cell = build_cell;
            lv.n = n;
            lv.cells.assign((size_t)n * n * n, LodLevel::Cell());
            bool any_filled = false;
            for (int tz = 0; tz < n; ++tz)
                for (int tx = 0; tx < n; ++tx) {
                    int h = 0; // tallest of the wire cells this tier's cell groups
                    for (int gz = 0; gz < group; ++gz)
                        for (int gx = 0; gx < group; ++gx) {
                            const int fx = tx * group + gx, fz = tz * group + gz;
                            if (fx < 4 && fz < 4)
                                h = std::max(h, (int)r[1 + fz * 4 + fx]);
                        }
                    // -1 where the column is empty all the way down, so the
                    // filled loop does nothing and the known-air loop below
                    // covers the whole column.
                    const int filled_below = h > 0 ? (h - 1) / build_cell : -1;
                    const int top_frac = h - filled_below * build_cell; // 1..build_cell
                    if (h > 0)
                        any_filled = true;
                    for (int ty = 0; ty <= filled_below && ty < n; ++ty) {
                        LodLevel::Cell &c = lv.cells[((size_t)tz * n + ty) * n + tx];
                        c.face[1] = side;
                        for (int d = 2; d < 6; ++d)
                            c.face[d] = side;
                        const bool is_top = ty == filled_below;
                        c.face[0] = is_top ? top_c : side; // buried tops are culled by the cell above anyway
                        c.top = is_top ? (uint8_t)top_frac : 0; // 0 reads as a full cell, see height_of()
                        c.day = day;
                        c.night = night;
                        c.flags = cflags | LodLevel::kFilled;
                    }
                    // Everything above the column's surface is air we know
                    // about, because the server generated this block to
                    // answer for it, so say so. Left at the default flags it
                    // read as "never seen", and "Unknown is not air" then
                    // culled every side face against it: a summarised hillside
                    // drew one cell of skirt at a step of any height and
                    // nothing below it, so the far field came out as floating
                    // tops with daylight through them.
                    //
                    // kLit only where the block reported light. A block that
                    // is all air has no surface column to read light above, so
                    // the record's day is 0 and its lit bit is clear; marking
                    // its cells lit anyway would hand 0 to every top face
                    // under it and paint that terrain black, which is what the
                    // first version of this did.
                    for (int ty = std::max(0, filled_below + 1); ty < n; ++ty) {
                        LodLevel::Cell &c = lv.cells[((size_t)tz * n + ty) * n + tx];
                        // Known and possibly lit, never occluding: the
                        // occludes bit is the block's, and air does not
                        // block the tier's own occlusion trace.
                        c.flags = LodLevel::kKnown | (cflags & LodLevel::kLit);
                        if (cflags & LodLevel::kLit) {
                            c.day = day;
                            c.night = night;
                        }
                    }
                }
            // Not stored: a summary is what the server holds now, not a
            // memory of what it once sent, so it is not marked stale
            // (docs/launch-target.md, R1). The chain is still known.
            ch.stored = false;
            m_lod_chain_missing.erase(bp);
            if (any_filled) {
                lodAssign(bp, tier);
                m_block_tier[bp] = tier;
                m_far_blocks.insert(bp);
                m_far_remote.insert(bp);
                ++taken;
            }
        }
        if (getenv("GOANNA_DEBUG_LOD"))
            UtilityFunctions::print("LOD far: summary area ", ox, ",", oy, ",", oz, " gave ", taken,
                    " blocks");
    }
}

void GoannaClient::lodMarkDirty(const LodRegionKey &key) {
    LodRegion &r = m_lod_regions[key];
    if (!r.dirty) {
        r.dirty = true;
        r.dirty_at = clock_t_::now();
    }
}

// A block changing moves the faces its six neighbours cull against it, so
// the regions drawing those neighbours are rebuilt too. The region the block
// itself belongs to is passed as `except` when the caller has already done it.
void GoannaClient::lodDirtyAround(const v3s16 &bp, const LodRegionKey *except) {
    static const v3s16 around[6] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
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
    if (m_lod_chains.count(bp) || m_lod_chain_missing.count(bp) || !m_lod_chain_queued.insert(bp).second)
        return;
    m_lod_chain_queue.push_back(bp);
}

void GoannaClient::lodAssign(const v3s16 &bp, int tier) {
    auto old = m_lod_member.find(bp);
    if (tier <= 0) {
        if (old != m_lod_member.end()) {
            LodRegion &r = m_lod_regions[old->second];
            r.members.erase(bp);
            lodMarkDirty(old->second);
            m_lod_member.erase(old);
        }
        lodDirtyAround(bp, nullptr);
        return;
    }
    const LodRegionKey key = lodRegionFor(tier, bp);
    if (old != m_lod_member.end() && old->second != key) {
        LodRegion &r = m_lod_regions[old->second];
        r.members.erase(bp);
        lodMarkDirty(old->second);
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

void GoannaClient::lodForget(const v3s16 &bp) {
    m_lod_chains.erase(bp);
    lodAssign(bp, 0);
}

void GoannaClient::lodBuildRegion(const LodRegionKey &key, LodRegion &r) {
    r.dirty = false;
    if (r.members.empty() || !m_session) {
        if (r.node) {
            r.node->queue_free();
            r.node = nullptr;
        }
        r.faces = r.quads = r.surfaces = 0;
        return;
    }
    auto t0 = clock_t_::now();
    static const bool no_vertex_light = getenv("GOANNA_NO_VERTEX_LIGHT") != nullptr;
    const int rb = lodRegionBlocks(key.tier);
    LodRegionSpec spec;
    spec.origin = key.pos * rb;
    spec.blocks = rb;
    spec.cell = lodCellFor(key.tier);
    // The far field radius grows with the cell, docs/far-rendering.md: from
    // the near field's reach at the finest tier to about 64 nodes at the
    // coarsest.
    spec.ao_radius = no_vertex_light ? 0.0f : std::clamp(6.0f * spec.cell, 8.0f, 64.0f);
    spec.member = [&](v3s16 bp) {
        auto it = m_lod_member.find(bp);
        return it != m_lod_member.end() && it->second == key;
    };
    spec.chain = [&](v3s16 bp) -> const BlockLodChain * {
        auto it = m_lod_chains.find(bp);
        if (it != m_lod_chains.end())
            return &it->second;
        // Not built yet: ask for it, and come back to this region when it is.
        lodEnqueueChain(bp);
        if (m_lod_chain_queued.count(bp))
            m_lod_chain_waiters[bp].insert(key);
        return nullptr;
    };
    LodRegionMesh lm = meshLodRegion(spec, m_session->nodeDefs(), m_session->tsrc(),
            &m_session->materialTable(), m_lod_tiles);
    r.faces = lm.faces;
    r.quads = lm.quads;
    r.surfaces = (int)lm.surfaces.size();
    // GOANNA_DEBUG_LOD=1: what each region build produced, per surface, so a
    // tier that lands on the flat colour fallback instead of the array shader
    // says so in the log rather than only in a screenshot.
    static const bool debug_lod = getenv("GOANNA_DEBUG_LOD") != nullptr;
    if (debug_lod) {
        String line = String("LOD region tier ") + String::num_int64(key.tier) + " at " +
                String::num_int64(key.pos.X) + "," + String::num_int64(key.pos.Y) + "," +
                String::num_int64(key.pos.Z) + " cell " + String::num_int64(spec.cell) +
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
        ema(m_ms_lod, ms_since(t0));
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
            // shader as the near mesh, on the liquid's own tile, so the sea
            // reads as sea at the horizon with its specular and fresnel. A
            // tier's own quad is one flat plane per cell, so there is nothing
            // at that scale for a per node wave to ripple, and its UV aliases
            // the same way a solid tile's does; waving is off and the sampled
            // colour blends toward the tile's own average with distance, same
            // as the array shader (docs/far-rendering.md, "Shade the far
            // field as a far field").
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
                    wm->set_shader_parameter("waving", false);
                    // sRGB average into a linear shader colour, as for the
                    // node materials above.
                    const Color avg = toColor(
                            m_session->tsrc()->getTextureAverageColor(m_session->tsrc()->getTextureName(sf.texture_id)))
                            .srgb_to_linear();
                    wm->set_shader_parameter("lod_avg_colour", Vector3(avg.r, avg.g, avg.b));
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
    const bool fresh_node = !r.node;
    if (!r.node) {
        r.node = memnew(MeshInstance3D);
        add_child(r.node);
    }
    r.node->set_mesh(mesh);
    if (fresh_node)
        startFade(r.node);
    ema(m_ms_lod, ms_since(t0));
}

// A mesh that has just appeared opens through the dither in the node
// shaders over a third of a second (the `fade` instance uniform), so far
// terrain stops arriving as a wall. Rebuilds of an existing mesh do not
// fade, or a dug node would flicker its whole block.
void GoannaClient::startFade(MeshInstance3D *mi) {
    if (!mi)
        return;
    mi->set_instance_shader_parameter("fade", 0.0f);
    m_fades.emplace_back(mi->get_instance_id(), clock_t_::now());
}

void GoannaClient::advanceFades() {
    const double kFadeMs = 350.0;
    for (size_t i = 0; i < m_fades.size();) {
        Object *o = ObjectDB::get_instance(m_fades[i].first);
        MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(o);
        const double t = ms_since(m_fades[i].second) / kFadeMs;
        if (!mi || t >= 1.0) {
            if (mi)
                mi->set_instance_shader_parameter("fade", 1.0f);
            m_fades[i] = m_fades.back();
            m_fades.pop_back();
            continue;
        }
        mi->set_instance_shader_parameter("fade", (float)t);
        ++i;
    }
}

// Rebuild dirty regions, oldest first, inside a time budget. A region that
// already has a mesh waits a moment after it is first dirtied, so one
// rebuild covers the many blocks that stream into it in that time.
void GoannaClient::lodRebuild(double budget_ms) {
    m_lod_last_built = 0;
    auto t0 = clock_t_::now();
    // Chains first, inside half the budget. A chain that a region was
    // waiting on dirties that region again.
    while (!m_lod_chain_queue.empty() && ms_since(t0) < budget_ms * 0.5) {
        const v3s16 bp = m_lod_chain_queue.front();
        m_lod_chain_queue.pop_front();
        m_lod_chain_queued.erase(bp);
        // Only blocks that matter to a region: a neighbour of nothing drawn
        // is a chain no one reads, and the store could supply millions.
        const bool wanted = m_lod_member.count(bp) || m_lod_chain_waiters.count(bp) ||
                (m_session && m_session->getBlock(bp));
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
    std::vector<std::pair<clock_t_::time_point, LodRegionKey>> dirty;
    for (auto &kv : m_lod_regions)
        if (kv.second.dirty)
            dirty.push_back({kv.second.dirty_at, kv.first});
    std::sort(dirty.begin(), dirty.end(),
            [](const auto &a, const auto &b) { return a.first < b.first; });
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
        if (r.members.empty())
            m_lod_regions.erase(it);
    }
}

// Drop every region and chain and requeue every block: the tier layout
// changed under them.
void GoannaClient::lodReset() {
    for (auto &kv : m_lod_regions)
        if (kv.second.node)
            kv.second.node->queue_free();
    m_lod_regions.clear();
    m_lod_member.clear();
    m_lod_chains.clear();
    m_lod_tiles.entries.clear();
    for (const v3s16 &bp : m_far_blocks)
        m_block_tier.erase(bp);
    m_far_blocks.clear();
    m_far_dirty = true;
    m_lod_chain_queue.clear();
    m_lod_chain_queued.clear();
    m_lod_chain_waiters.clear();
    m_lod_chain_missing.clear();
    m_far_remote.clear();
    m_far_requested.clear();
    m_far_inflight = 0;
    if (m_session) {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        for (auto &kv : m_block_tier)
            m_session->requeueBlock(kv.first);
    }
}

int GoannaClient::update_lod(const Vector3 &around, int max_rebuild) {
    m_lod_centre = around; // poll_blocks tiers new blocks against this too
    advanceFades();
    if (!m_session || m_lod_distance <= 0)
        return 0;
    std::vector<v3s16> changed;
    for (auto &kv : m_block_tier) {
        if (lodTierFor(kv.first, around) != kv.second) {
            changed.push_back(kv.first);
            if ((int)changed.size() >= max_rebuild)
                break;
        }
    }
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    lodTakeSummaries();
    for (const v3s16 &bp : changed) {
        if (m_far_remote.count(bp))
            continue; // summary blocks are coarse only and stay at the top tier
        if (m_far_blocks.count(bp)) {
            // No live block to requeue: apply the new tier here.
            const int tier = lodTierFor(bp, around);
            if (tier < 1) {
                lodForget(bp);
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
    lodUpdateFar(around);
    return (int)changed.size();
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
    auto t_poll = clock_t_::now();
    // A time budget as well as a count: a full detail block costs about 5 ms
    // to mesh and upload, so 24 of them in one poll was a 120 ms frame, which
    // is what the arrival of a new area felt like. What does not fit is
    // requeued and comes next frame. GOANNA_POLL_MS overrides the budget.
    static const double poll_budget_ms = [] {
        const char *v = getenv("GOANNA_POLL_MS");
        return v ? std::max(1.0, atof(v)) : 6.0;
    }();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    // Mesh nearest-first so a backlog does not leave the block right ahead of
    // the player unmeshed (visible pop-in) while distant ones mesh in arrival
    // order.
    if (LocalPlayer *pl = m_session->player()) {
        v3f pp = pl->getPosition() * (1.0f / BS);
        v3f pb(pp.X / MAP_BLOCKSIZE, pp.Y / MAP_BLOCKSIZE, pp.Z / MAP_BLOCKSIZE);
        std::sort(fresh.begin(), fresh.end(), [&](const v3s16 &a, const v3s16 &b) {
            return v3f::from(a).getDistanceFromSQ(pb) < v3f::from(b).getDistanceFromSQ(pb);
        });
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
        int tier = lodTierFor(bp, m_lod_centre);
        // The block's data is fresh, so any coarse summary of it is stale.
        m_lod_chains.erase(bp);
        m_lod_chain_missing.erase(bp);
        m_far_blocks.erase(bp); // live now, whatever the store said
        if (tier >= 1) {
            auto lit2 = m_block_nodes.find(bp);
            if (lit2 != m_block_nodes.end()) {
                lit2->second->queue_free();
                m_block_nodes.erase(lit2);
            }
            lodAssign(bp, tier);
            m_block_tier[bp] = tier;
            ++done;
            continue;
        }
        // Full detail: leave any region it was in, and let the regions next
        // to it cull against its new contents.
        lodAssign(bp, 0);
        auto t_mesh = clock_t_::now();
        std::unique_ptr<MapBlockMesh> bm = meshBlock(*m_session, block);
        // Luanti's own light never reaches the vertices (g_goanna_no_light,
        // see goanna_mesh_flags.h), so it is read here instead, from the same
        // nodes, along with the occlusion trace. docs/mesh-attributes.md.
        BlockLightField lightfield;
        lightfield.build(*m_session, bp);
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
        MeshInstance3D *mi = nullptr;
        auto it = m_block_nodes.find(bp);
        if (it != m_block_nodes.end())
            mi = it->second;
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
                        const VertexLight vl = no_vertex_light ? VertexLight() : lightfield.sample(
                                v3f(v[sv].Pos.X / BS + bp.X * MAP_BLOCKSIZE,
                                        v[sv].Pos.Y / BS + bp.Y * MAP_BLOCKSIZE,
                                        v[sv].Pos.Z / BS + bp.Z * MAP_BLOCKSIZE),
                                v3f(v[sv].Normal.X, v[sv].Normal.Y, v[sv].Normal.Z));
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
        for (auto &kv : groups) {
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
            Array arrays;
            arrays.resize(Mesh::ARRAY_MAX);
            arrays[Mesh::ARRAY_VERTEX] = acc.verts;
            arrays[Mesh::ARRAY_NORMAL] = acc.norms;
            arrays[Mesh::ARRAY_TEX_UV] = acc.uvs;
            arrays[Mesh::ARRAY_COLOR] = acc.cols;
            arrays[Mesh::ARRAY_TEX_UV2] = acc.uv2s;
            arrays[Mesh::ARRAY_CUSTOM0] = acc.custom0;
            arrays[Mesh::ARRAY_INDEX] = acc.idx;
            gmesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, TypedArray<Array>(),
                    Dictionary(), kNodeSurfaceFlags);
            gmesh->surface_set_material(gsi++, materialFor(acc.key));
        }
        // A block of nothing but lamps still has geometry, so both have to be
        // empty before it is thrown away.
        if (si == 0 && gsi == 0) {
            if (mi) {
                if (getenv("GOANNA_DEBUG_BLOCKS"))
                    UtilityFunctions::print("block FREED (empty mesh): ", bp.X, ",", bp.Y, ",", bp.Z);
                mi->queue_free();
                m_block_nodes.erase(bp);
            }
            ++done;
            continue;
        }
        if (getenv("GOANNA_DEBUG_BLOCKS") && mi)
            UtilityFunctions::print("block re-meshed: ", bp.X, ",", bp.Y, ",", bp.Z, " surfaces ", si);
        const bool fresh_block = !mi;
        if (!mi) {
            mi = memnew(MeshInstance3D);
            add_child(mi);
            m_block_nodes[bp] = mi;
        }
        mi->set_mesh(mesh);
        if (fresh_block)
            startFade(mi);
        // The glow mesh hangs off the block mesh rather than being tracked
        // beside it, so every place that frees a block frees this too and none
        // of them had to learn about it.
        MeshInstance3D *gmi = nullptr;
        for (int ci = 0; ci < mi->get_child_count(); ++ci) {
            MeshInstance3D *cand = Object::cast_to<MeshInstance3D>(mi->get_child(ci));
            if (cand && !cand->is_queued_for_deletion()) {
                gmi = cand;
                break;
            }
        }
        if (gsi > 0) {
            if (!gmi) {
                gmi = memnew(MeshInstance3D);
                gmi->set_layer_mask(GLOW_LAYER);
                mi->add_child(gmi);
            }
            gmi->set_mesh(gmesh);
        } else if (gmi) {
            mi->remove_child(gmi);
            gmi->queue_free();
        }
        if (debug_light && dl_n > 0)
            UtilityFunctions::print("LIGHT block ", bp.X, ",", bp.Y, ",", bp.Z, " verts ", (int)dl_n,
                    " block ", (int)(dl_block / dl_n), " sky ", (int)(dl_sky / dl_n),
                    " (", dl_sky_min, "..", dl_sky_max, ")",
                    " ao ", (int)(dl_ao / dl_n), " (", dl_ao_min, "..", dl_ao_max, ")",
                    " skybright ", (int)(100 * dl_sky_bright / dl_n), "% skydark ",
                    (int)(100 * dl_sky_dark / dl_n), "%");
        m_block_tier[bp] = 0;
        ema(m_ms_upload, ms_since(t_upload));
        ++done;
    }
    m_last_meshed = done;
    m_last_queue = (int)fresh.size() - done;
    advanceFades(); // blocks start fading here, so advance here too
    // Regions dirtied above, and any still waiting from earlier polls, in
    // what is left of the budget plus a little, so a quiet frame still
    // advances the far tiers.
    lodRebuild(std::max(2.0, poll_budget_ms - ms_since(t_poll)));
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
    ClassDB::bind_method(D_METHOD("node_sound", "node_name", "kind"), &GoannaClient::node_sound);
    ClassDB::bind_method(D_METHOD("sky_state"), &GoannaClient::sky_state);
    ClassDB::bind_method(D_METHOD("update_lights", "around", "max_lights"), &GoannaClient::update_lights);
    ClassDB::bind_method(D_METHOD("set_shadow_lamps", "n"), &GoannaClient::set_shadow_lamps);
    ClassDB::bind_method(D_METHOD("shadow_lamps"), &GoannaClient::shadow_lamps);
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
    ClassDB::bind_method(D_METHOD("wield_info"), &GoannaClient::wield_info);
    ClassDB::bind_method(D_METHOD("item_mesh", "item_name"), &GoannaClient::item_mesh);
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
    ClassDB::bind_method(D_METHOD("lod_cell"), &GoannaClient::lod_cell);
    ClassDB::bind_method(D_METHOD("update_lod", "around", "max_rebuild"), &GoannaClient::update_lod);
    ClassDB::bind_method(D_METHOD("set_store_path", "root"), &GoannaClient::set_store_path);
    ClassDB::bind_method(D_METHOD("store_path"), &GoannaClient::store_path);
    ClassDB::bind_method(D_METHOD("set_far_distance", "nodes"), &GoannaClient::set_far_distance);
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
