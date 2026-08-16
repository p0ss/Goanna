// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
//
// A Luanti client session, built on Luanti's own network layer, node and
// item definition managers and MapBlock code.
//
// Parts derive from Luanti 5.16.1, restructured rather than copied whole:
// the packet handlers follow Client::handleCommand_* in
// network/clientpackethandler.cpp; sendInit and startAuth follow
// Client::sendInit and Client::startAuth in client/client.cpp; stepPlayer
// is the local player half of ClientEnvironment::step. Each is marked at
// its definition.

#include "goanna_session.h"

#include "transplant/localplayer.h"
#include "goanna_luanti_client.h"
#include "goanna_raycast.h"
#include "client/node_visuals.h"
#include "client/item_visuals_manager.h"
#include "raycast.h"
#include "tool.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <set>
#include <cstring>
#include <sstream>

#include "constants.h"
#include "exceptions.h"
#include "content/mods.h"
#include "itemdef.h"
#include "log.h"
#include "mapblock.h"
#include "nodemetadata.h"
#include "network/address.h"
#include "network/networkpacket.h"
#include "network/socket.h"
#include "nodedef.h"
#include "porting.h"
#include "serialization.h"
#include "settings.h"
#include "util/auth.h"
#include "util/base64.h"
#include "util/serialize.h"
#include "util/srp.h"
#include "util/string.h"
#include "version.h"

namespace goanna {

const char *session_state_name(SessionState s) {
    switch (s) {
    case SessionState::Idle: return "idle";
    case SessionState::Connecting: return "connecting";
    case SessionState::Init: return "init";
    case SessionState::Auth: return "auth";
    case SessionState::Definitions: return "definitions";
    case SessionState::ContentReady: return "content-ready";
    case SessionState::Ready: return "ready";
    case SessionState::Denied: return "denied";
    case SessionState::Disconnected: return "disconnected";
    case SessionState::Error: return "error";
    }
    return "?";
}

// Luanti's engine code expects the global settings layers to exist. Goanna
// does not carry defaultsettings.cpp (it drags in the whole client), so the
// few keys the transplanted subsystems read are set here.
static void ensureSettings() {
    static bool done = false;
    if (done)
        return;
    done = true;
    Settings *defaults = Settings::createLayer(SL_DEFAULTS);
    defaults->setDefault("max_packets_per_iteration", "1024");
    defaults->setDefault("enable_ipv6", "true");
    defaults->setDefault("disallow_empty_password", "false");
    defaults->setDefault("default_password", "");
    defaults->setDefault("enable_mod_channels", "false");
    defaults->setDefault("time_speed", "72");
    defaults->setDefault("anticheat_flags", "");
    defaults->setDefault("debug_log_level", "action");
    // PlayerSettings (transplanted LocalPlayer) reads these.
    for (const char *k : {"free_move", "pitch_move", "fast_move", "continuous_forward",
                 "always_fly_fast", "aux1_descends", "noclip", "autojump"})
        defaults->setDefault(k, "false");
    defaults->setDefault("movement_speed_walk", "4.0");
    // TextureSettings / meshing (transplanted node_visuals, mapblock_mesh)
    defaults->setDefault("connected_glass", "true");
    defaults->setDefault("translucent_liquids", "true");
    defaults->setDefault("enable_minimap", "false");
    defaults->setDefault("texture_min_size", "0");
    defaults->setDefault("leaves_style", "fancy");
    defaults->setDefault("world_aligned_mode", "enable");
    defaults->setDefault("autoscale_mode", "disable");
    defaults->setDefault("smooth_lighting", "false");
    defaults->setDefault("ambient_occlusion_gamma", "1.8");
    defaults->setDefault("texture_path", "");
    defaults->setDefault("mip_map", "false");
    defaults->setDefault("trilinear_filter", "false");
    defaults->setDefault("bilinear_filter", "false");
    defaults->setDefault("anisotropic_filter", "false");
    defaults->setDefault("array_texture_max", "0");
    defaults->setDefault("enable_water_reflections", "false");
    defaults->setDefault("mesh_generation_interval", "0");
    g_settings = Settings::createLayer(SL_GLOBAL);
    sockets_init();
}

void GoannaSession::setSharePath(const std::string &path) {
    porting::path_share = path;
}

GoannaSession::GoannaSession() {
    ensureSettings();
    m_nodedef = createNodeDefManager();
    m_itemdef = createItemDefManager();
    m_map = std::make_unique<GoannaMap>(this);
    m_inventory = std::make_unique<Inventory>(m_itemdef);
    m_tsrc = std::make_unique<GoannaTextureSource>();
    m_models = std::make_unique<ModelCache>(
            [this](const std::string &name, std::string &out) { return getMedia(name, out); });
    m_item_visuals = std::make_unique<ItemVisualsManager>();
    m_mesh_client = std::make_unique<Client>(m_tsrc.get(), &m_shsrc, m_nodedef, m_itemdef,
            m_models.get(), m_item_visuals.get());
}

GoannaSession::~GoannaSession() {
    stop();
    if (m_srp)
        srp_user_delete(m_srp);
    delete m_nodedef;
    delete m_itemdef;
}

void GoannaSession::start(const std::string &host, uint16_t port, const std::string &player_name,
        const std::string &password) {
    stop();
    m_host = host;
    m_port = port;
    m_name = player_name;
    m_password = password;
    m_player = std::make_unique<LocalPlayer>(this, player_name);
    m_running = true;
    m_thread = std::thread(&GoannaSession::threadMain, this);
}

void GoannaSession::stop() {
    m_running = false;
    if (m_thread.joinable())
        m_thread.join();
    if (m_con) {
        m_con->Disconnect();
        m_con.reset();
    }
}

SessionStats GoannaSession::stats() const {
    std::lock_guard<std::mutex> lk(m_stats_mutex);
    return m_stats;
}

std::vector<v3s16> GoannaSession::takeNewBlocks() {
    std::lock_guard<std::mutex> lk(m_map_mutex);
    std::vector<v3s16> out;
    out.swap(m_new_blocks);
    return out;
}

void GoannaSession::requeueBlock(v3s16 pos) {
    m_new_blocks.push_back(pos);
}

MapBlock *GoannaSession::getBlock(v3s16 pos) {
    return m_map->getBlockNoCreateNoEx(pos);
}

// Transplanted from luanti/src/client/clientenvironment.cpp,
// ClientEnvironment::step (LGPL-2.1-or-later): the local-player part only.
// Fall damage is left out until HP is wired.
void GoannaSession::stepPlayer(float dtime) {
    LocalPlayer *lplayer = m_player.get();
    if (!lplayer)
        return;
    bool fly_allowed = lplayer->privileges.fly;
    bool free_move = fly_allowed && g_settings->getBool("free_move");
    Map *map = m_map.get();

    bool is_climbing = lplayer->is_climbing;
    f32 player_speed = lplayer->getSpeed().getLength();

    // Maximum position increment
    f32 position_max_increment = 0.1 * BS;
    // Maximum time increment (for collision detection etc)
    f32 dtime_max_increment = 1;
    if (player_speed > 0.001)
        dtime_max_increment = position_max_increment / player_speed;
    // Maximum time increment is 10ms or lower
    if (dtime_max_increment > 0.01)
        dtime_max_increment = 0.01;
    // Don't allow overly huge dtime
    if (dtime > DTIME_LIMIT)
        dtime = DTIME_LIMIT;

    u32 steps = std::ceil(dtime / dtime_max_increment);
    f32 dtime_part = dtime / steps;
    for (; steps > 0; --steps) {
        lplayer->applyControl(dtime_part, map);

        lplayer->gravity = 0;
        if (!free_move) {
            if (!is_climbing && !lplayer->in_liquid)
                // HACK the factor 2 for gravity is arbitrary and should be removed eventually
                lplayer->gravity = 2 * lplayer->movement_gravity * lplayer->physics_override.gravity;

            if (!is_climbing && lplayer->in_liquid && !lplayer->swimming_vertical &&
                    !lplayer->swimming_pitch)
                lplayer->gravity = 2 * lplayer->movement_liquid_sink * lplayer->physics_override.liquid_sink;

            if (lplayer->move_resistance > 0) {
                v3f speed = lplayer->getSpeed();
                static const f32 resistance_factor = 0.3f;
                float fluidity = lplayer->movement_liquid_fluidity;
                fluidity *= MYMAX(1.0f, lplayer->physics_override.liquid_fluidity);
                fluidity = MYMAX(0.001f, fluidity);
                float fluidity_smooth = lplayer->movement_liquid_fluidity_smooth;
                fluidity_smooth *= lplayer->physics_override.liquid_fluidity_smooth;
                fluidity_smooth = MYMAX(0.0f, fluidity_smooth);
                v3f d_wanted;
                bool in_liquid_stable = lplayer->in_liquid_stable || lplayer->in_liquid;
                if (in_liquid_stable)
                    d_wanted = -speed / fluidity;
                else
                    d_wanted = -speed / BS;
                f32 dl = d_wanted.getLength();
                if (in_liquid_stable)
                    dl = MYMIN(dl, fluidity_smooth);
                dl *= (lplayer->move_resistance * resistance_factor) + (1 - resistance_factor);
                v3f d = d_wanted.normalize() * (dl * dtime_part * 100.0f);
                speed += d;
                lplayer->setSpeed(speed);
            }
        }
        lplayer->move(dtime_part, map);
    }
}

// ---- in-game data: chat, HUD, inventory, formspecs (Client::handleCommand_* transplanted) ----

std::vector<GoannaSession::ChatLine> GoannaSession::takeChat() {
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    std::vector<ChatLine> out;
    out.swap(m_chat);
    return out;
}

void GoannaSession::sendChat(const std::wstring &message) {
    if (!m_con)
        return;
    NetworkPacket pkt(TOSERVER_CHAT_MESSAGE, 2 + message.size() * sizeof(u16));
    pkt << message;
    send(pkt);
}

void GoannaSession::sendInventoryAction(const std::string &action) {
    if (!m_con)
        return;
    NetworkPacket pkt(TOSERVER_INVENTORY_ACTION, action.size());
    pkt.putRawString(action.c_str(), action.size());
    send(pkt);
}

void GoannaSession::sendPlayerItem(u16 index) {
    if (!m_con)
        return;
    NetworkPacket pkt(TOSERVER_PLAYERITEM, 2);
    pkt << index;
    send(pkt);
}

void GoannaSession::sendInventoryFields(const std::string &formname,
        const std::map<std::string, std::string> &fields) {
    if (!m_con)
        return;
    NetworkPacket pkt(TOSERVER_INVENTORY_FIELDS, 0);
    pkt << formname << (u16)fields.size();
    for (auto &kv : fields) {
        pkt << kv.first;
        pkt.putLongString(kv.second);
    }
    send(pkt);
}

std::string GoannaSession::inventoryFormspec() const {
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    return m_inventory_formspec;
}
std::vector<GoannaSession::ShownFormspec> GoannaSession::takeShownFormspecs() {
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    std::vector<ShownFormspec> out;
    out.swap(m_shown_formspecs);
    return out;
}

void GoannaSession::sendNodemetaFields(v3s16 p, const std::string &formname,
        const std::map<std::string, std::string> &fields) {
    if (!m_con)
        return;
    NetworkPacket pkt(TOSERVER_NODEMETA_FIELDS, 0);
    pkt << p << formname << (u16)(fields.size() & 0xFFFF);
    for (auto &kv : fields) {
        pkt << kv.first;
        pkt.putLongString(kv.second);
    }
    send(pkt);
}

void GoannaSession::onChatMessage(NetworkPacket &pkt) {
    u8 version, message_type;
    pkt >> version >> message_type;
    if (version != 1)
        return;
    ChatLine line;
    line.type = message_type;
    u64 timestamp;
    pkt >> line.sender >> line.message >> timestamp;
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    m_chat.push_back(std::move(line));
}

void GoannaSession::onHP(NetworkPacket &pkt) {
    u16 hp;
    pkt >> hp;
    m_hp = hp;
    std::lock_guard<std::mutex> lk(m_map_mutex);
    if (m_player)
        m_player->hp = hp;
}

void GoannaSession::onBreath(NetworkPacket &pkt) {
    u16 breath;
    pkt >> breath;
    m_breath = breath;
}

void GoannaSession::onHudAdd(NetworkPacket &pkt) {
    u32 server_id;
    u8 type;
    HudElement e;
    pkt >> server_id >> type >> e.pos >> e.name >> e.scale >> e.text >> e.number >> e.item
        >> e.dir >> e.align >> e.offset;
    pkt >> e.world_pos;
    if (stats().proto_ver >= 52) {
        pkt >> e.size;
    } else {
        v2s32 old_format;
        pkt >> old_format;
        e.size = v2f::from(old_format);
    }
    e.z_index = 0;
    e.style = 0;
    do {
        if (!pkt.hasRemainingBytes()) break;
        pkt >> e.z_index;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> e.text2;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> e.style;
    } while (0);
    e.type = (HudElementType)type;
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    m_hud[server_id] = e;
    m_hud_version++;
}

void GoannaSession::onHudChange(NetworkPacket &pkt) {
    std::string sdata;
    v2f v2fdata;
    v3f v3fdata;
    u32 intdata = 0;
    u32 server_id;
    u8 stat;
    pkt >> server_id >> stat;
    if (stat >= HudElementStat_END)
        return;
    switch (static_cast<HudElementStat>(stat)) {
    case HUD_STAT_POS: case HUD_STAT_SCALE: case HUD_STAT_ALIGN: case HUD_STAT_OFFSET:
        pkt >> v2fdata; break;
    case HUD_STAT_NAME: case HUD_STAT_TEXT: case HUD_STAT_TEXT2:
        pkt >> sdata; break;
    case HUD_STAT_WORLD_POS:
        pkt >> v3fdata; break;
    case HUD_STAT_SIZE:
        if (stats().proto_ver >= 52) { pkt >> v2fdata; }
        else { v2s32 old_format; pkt >> old_format; v2fdata = v2f::from(old_format); }
        break;
    default:
        pkt >> intdata; break;
    }
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    auto it = m_hud.find(server_id);
    if (it == m_hud.end())
        return;
    HudElement &e = it->second;
    switch (static_cast<HudElementStat>(stat)) {
    case HUD_STAT_POS: e.pos = v2fdata; break;
    case HUD_STAT_NAME: e.name = sdata; break;
    case HUD_STAT_SCALE: e.scale = v2fdata; break;
    case HUD_STAT_TEXT: e.text = sdata; break;
    case HUD_STAT_NUMBER: e.number = intdata; break;
    case HUD_STAT_ITEM: e.item = intdata; break;
    case HUD_STAT_DIR: e.dir = intdata; break;
    case HUD_STAT_ALIGN: e.align = v2fdata; break;
    case HUD_STAT_OFFSET: e.offset = v2fdata; break;
    case HUD_STAT_WORLD_POS: e.world_pos = v3fdata; break;
    case HUD_STAT_SIZE: e.size = v2fdata; break;
    case HUD_STAT_Z_INDEX: e.z_index = (s16)intdata; break;
    case HUD_STAT_TEXT2: e.text2 = sdata; break;
    case HUD_STAT_STYLE: e.style = intdata; break;
    default: break;
    }
    m_hud_version++;
}

void GoannaSession::onHudRemove(NetworkPacket &pkt) {
    u32 server_id;
    pkt >> server_id;
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    m_hud.erase(server_id);
    m_hud_version++;
}

void GoannaSession::onHudSetFlags(NetworkPacket &pkt) {
    u32 flags, mask;
    pkt >> flags >> mask;
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    m_hud_flags &= ~mask;
    m_hud_flags |= flags;
    m_hud_version++;
}

void GoannaSession::onHudSetParam(NetworkPacket &pkt) {
    u16 param;
    std::string value;
    pkt >> param >> value;
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    if (param == HUD_PARAM_HOTBAR_ITEMCOUNT && value.size() == 4) {
        s32 n = readS32((u8 *)value.c_str());
        if (n > 0 && n <= HUD_HOTBAR_ITEMCOUNT_MAX)
            m_hotbar_itemcount = n;
    } else if (param == HUD_PARAM_HOTBAR_IMAGE) {
        m_hotbar_image = value;
    } else if (param == HUD_PARAM_HOTBAR_SELECTED_IMAGE) {
        m_hotbar_selected_image = value;
    }
    m_hud_version++;
}

// Client::handleCommand_DetachedInventory
void GoannaSession::onDetachedInventory(NetworkPacket &pkt) {
    std::string name;
    bool keep_inv = true;
    pkt >> name >> keep_inv;
    std::lock_guard<std::mutex> lk(m_map_mutex);
    m_detached_version++;
    if (!keep_inv) {
        m_detached_inventories.erase(name);
        return;
    }
    auto &inv = m_detached_inventories[name];
    if (!inv)
        inv = std::make_unique<Inventory>(m_itemdef);
    // this used to be the length of the following string, ignore it
    pkt.skip(2);
    std::string contents(pkt.getRemainingString(), pkt.getRemainingBytes());
    std::istringstream is(contents, std::ios::binary);
    inv->deSerialize(is);
}

// Client::handleCommand_NodemetaChanged
void GoannaSession::onNodemetaChanged(NetworkPacket &pkt) {
    if (pkt.getSize() < 1)
        return;
    std::istringstream is(pkt.readLongString(), std::ios::binary);
    std::stringstream sstr(std::ios::binary | std::ios::in | std::ios::out);
    decompressZlib(is, sstr);
    NodeMetadataList meta_updates_list(false);
    meta_updates_list.deSerialize(sstr, m_itemdef, true);
    std::lock_guard<std::mutex> lk(m_map_mutex);
    m_detached_version++;
    for (auto i = meta_updates_list.begin(); i != meta_updates_list.end(); ++i) {
        v3s16 pos = i->first;
        if (m_map->isValidPosition(pos) && m_map->setNodeMetadata(pos, i->second))
            continue; // Prevent from deleting metadata
        // Meta couldn't be set, unused metadata
        delete i->second;
    }
}

Inventory *GoannaSession::inventoryAt(const std::string &location) {
    // InventoryLocation::deSerialize, for the client-visible kinds
    if (location == "current_player")
        return m_inventory.get();
    if (location.rfind("detached:", 0) == 0) {
        auto it = m_detached_inventories.find(location.substr(9));
        return it == m_detached_inventories.end() ? nullptr : it->second.get();
    }
    if (location.rfind("nodemeta:", 0) == 0) {
        std::string coords = location.substr(9);
        std::replace(coords.begin(), coords.end(), ',', ' ');
        std::istringstream is(coords);
        v3s16 p;
        is >> p.X >> p.Y >> p.Z;
        if (is.fail())
            return nullptr;
        NodeMetadata *meta = m_map->getNodeMetadata(p);
        return meta ? meta->getInventory() : nullptr;
    }
    return nullptr;
}

void GoannaSession::onInventory(NetworkPacket &pkt) {
    if (pkt.getSize() < 1)
        return;
    std::string datastring;
    if (stats().proto_ver > 51) {
        datastring = pkt.readLongString();
    } else {
        datastring = std::string(pkt.getString(0), pkt.getSize());
    }
    std::istringstream is(datastring, std::ios_base::binary);
    std::lock_guard<std::mutex> lk(m_map_mutex);
    m_inventory->deSerialize(is);
    m_inventory_version++;
}

void GoannaSession::onInventoryFormspec(NetworkPacket &pkt) {
    std::string fs = pkt.readLongString();
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    m_inventory_formspec = fs;
}

void GoannaSession::onShowFormspec(NetworkPacket &pkt) {
    std::string formspec = pkt.readLongString();
    std::string formname;
    pkt >> formname;
    std::lock_guard<std::mutex> lk(m_hud_mutex);
    m_shown_formspecs.push_back({formspec, formname, ""});
}

// ---- interaction: Game::updatePointedThing / handleDigging / place, transplanted in spirit ----

void GoannaSession::setWieldIndex(u16 index) {
    m_wield_index = index;
    if (m_player)
        m_player->setWieldIndex(index);
    sendPlayerItem(index);
}

int GoannaSession::crackAnimationLength() {
    if (m_crack_animation_length < 0) {
        auto size = m_tsrc->getTextureDimensions("crack_anylength.png");
        m_crack_animation_length = (size.Width > 0 && size.Height >= size.Width) ? size.Height / size.Width : 5;
    }
    return m_crack_animation_length;
}

// Client::interact, transplanted.
void GoannaSession::sendInteract(u8 action, const PointedThing &pointed) {
    if (!m_con)
        return;
    NetworkPacket pkt(TOSERVER_INTERACT, 1 + 2 + 0);
    pkt << action;
    pkt << m_wield_index;
    std::ostringstream tmp_os(std::ios::binary);
    pointed.serialize(tmp_os);
    pkt.putLongString(tmp_os.str());
    writePlayerPosTo(pkt);
    send(pkt);
}

// ClientEnvironment::getSelectedActiveObjects, against Goanna's objects.
void GoannaSession::selectObjects(const core::line3d<f32> &shootline, std::vector<PointedThing> &out,
        const std::optional<Pointabilities> &pointabilities) {
    v3f line_vector = shootline.getVector();
    for (auto &kv : m_objects) {
        GoannaActiveObject *obj = kv.second.get();
        if (obj->isLocalPlayer() || !obj->isVisible())
            continue;
        const ObjectProperties &p = obj->props();
        if (!p.is_visible)
            continue;
        aabb3f selection_box = p.selectionbox;
        selection_box.MinEdge *= BS;
        selection_box.MaxEdge *= BS;
        v3f pos = obj->position();
        v3f rel_pos = shootline.start - pos;
        v3f current_intersection, current_normal;
        if (!boxLineCollision(selection_box, rel_pos, line_vector, &current_intersection, &current_normal))
            continue;
        PointabilityType pointable = p.pointable;
        if (pointabilities) {
            if (obj->isPlayer())
                pointable = pointabilities->matchPlayer(ItemGroupList()).value_or(p.pointable);
            else
                pointable = pointabilities->matchObject(obj->name(), ItemGroupList()).value_or(p.pointable);
        }
        if (pointable == PointabilityType::POINTABLE_NOT)
            continue;
        current_intersection += pos;
        f32 d_sq = (current_intersection - shootline.start).getLengthSQ();
        out.emplace_back(obj->id(), current_intersection, current_normal, current_normal, d_sq, pointable);
    }
}

void GoannaSession::stepInteract(float dtime, const InteractInput &in) {
    if (!m_player || !m_ready_sent)
        return;
    // wielded / hand items
    ItemStack selected_item, hand_item;
    if (InventoryList *main = m_inventory->getList("main"))
        if (m_wield_index < main->getSize())
            selected_item = main->getItem(m_wield_index);
    if (InventoryList *hand = m_inventory->getList("hand"))
        if (hand->getSize() > 0)
            hand_item = hand->getItem(0);
    ItemStack tool_item = selected_item.name.empty() ? hand_item : selected_item;
    f32 range = getToolRange(selected_item, hand_item, m_itemdef);

    // pointed thing
    core::line3d<f32> shootline(in.eye_pos_bs, in.eye_pos_bs + in.look_dir * BS * range);
    const ItemDefinition &selected_def = selected_item.getDefinition(m_itemdef);
    RaycastState state(shootline, true, selected_def.liquids_pointable, selected_def.pointabilities);
    PointedThing pointed;
    continueRaycast(&state, &pointed, *m_map,
            [this](const core::line3d<f32> &l, std::vector<PointedThing> &o,
                    const std::optional<Pointabilities> &pa) { selectObjects(l, o, pa); });
    m_interact.pointed = pointed;

    m_nodig_delay_timer -= dtime;
    if (m_nodig_delay_timer < 0) m_nodig_delay_timer = 0;
    const float repeat_dig_time = 0.0f, repeat_place_time = 0.25f;

    // pointing changed while digging -> stop
    if (m_interact.digging && !(pointed.type == POINTEDTHING_NODE && m_pointed_old.type == POINTEDTHING_NODE &&
            pointed.node_undersurface == m_pointed_old.node_undersurface)) {
        sendInteract(INTERACT_STOP_DIGGING, m_pointed_old);
        m_interact.digging = false;
        m_interact.dig_time = 0;
        m_interact.crack_level = -1;
    }
    if (m_interact.digging && !in.dig) {
        sendInteract(INTERACT_STOP_DIGGING, m_pointed_old);
        m_interact.digging = false;
        m_interact.dig_time = 0;
        m_interact.crack_level = -1;
    }
    if (!m_interact.digging && m_btn_down_for_dig && !in.dig)
        m_btn_down_for_dig = false;

    if (in.place)
        m_repeat_place_timer += dtime;
    else
        m_repeat_place_timer = 0;
    bool place_now = in.place_pressed || (in.place && m_repeat_place_timer >= repeat_place_time);

    if (pointed.type == POINTEDTHING_NODE) {
        v3s16 nodepos = pointed.node_undersurface;
        MapNode n = m_map->getNode(nodepos);
        const ContentFeatures &features = m_nodedef->get(n);
        // digging (Game::handleDigging)
        if (in.dig && m_nodig_delay_timer <= 0 && !(m_btn_down_for_dig && !m_interact.digging)) {
            DigParams params = getDigParams(features.groups,
                    &tool_item.getToolCapabilities(m_itemdef, &hand_item), tool_item.wear);
            if (!params.diggable)
                params = getDigParams(features.groups, &hand_item.getToolCapabilities(m_itemdef));
            m_interact.dig_time_complete = params.diggable ? params.time : 10000000.0f;
            if (!m_interact.digging) {
                m_dig_instantly = m_interact.dig_time_complete == 0;
                sendInteract(INTERACT_START_DIGGING, pointed);
                m_interact.digging = true;
                m_btn_down_for_dig = true;
            }
            int cal = crackAnimationLength();
            float dig_index = m_dig_instantly ? cal : (float)cal * m_interact.dig_time / m_interact.dig_time_complete;
            if (m_interact.dig_time_complete >= 100000.0f) {
                m_interact.crack_level = -1;
            } else if (dig_index < cal) {
                m_interact.crack_level = (int)dig_index;
                m_interact.crack_pos = nodepos;
            } else {
                // Digging completed
                m_interact.crack_level = -1;
                m_interact.dig_time = 0;
                m_interact.digging = false;
                m_nodig_delay_timer = m_interact.dig_time_complete / (float)cal;
                if (m_nodig_delay_timer > 0.3f) m_nodig_delay_timer = 0.3f;
                else if (m_dig_instantly) m_nodig_delay_timer = 0.15f;
                m_nodig_delay_timer = std::max(m_nodig_delay_timer, repeat_dig_time - m_interact.dig_time_complete);
                // client-side prediction (Client::removeNode / addNode)
                std::map<v3s16, MapBlock *> modified;
                try {
                    if (features.node_dig_prediction == "air") {
                        m_map->removeNodeAndUpdate(nodepos, modified);
                    } else if (!features.node_dig_prediction.empty()) {
                        content_t id;
                        if (m_nodedef->getId(features.node_dig_prediction, id))
                            m_map->addNodeAndUpdate(nodepos, MapNode(id), modified, true);
                    }
                } catch (const InvalidPositionException &) {}
                for (auto &kv : modified)
                    m_new_blocks.push_back(kv.first);
                queueBlocksAround(nodepos);
                sendInteract(INTERACT_DIGGING_COMPLETED, pointed);
            }
            if (m_interact.dig_time_complete < 100000.0f)
                m_interact.dig_time += dtime;
            else
                m_interact.dig_time = 0;
        }
        // placing (Game::nodePlacement without prediction)
        if (place_now) {
            m_repeat_place_timer = 0;
            NodeMetadata *meta = m_map->getNodeMetadata(nodepos);
            if (meta && !meta->getString("formspec").empty() && !in.sneak) {
                // formspec in meta: opened client-side; on_rightclick
                // callbacks are called anyway
                if (features.rightclickable)
                    sendInteract(INTERACT_PLACE, pointed);
                std::string context = "nodemeta:" + std::to_string(nodepos.X) + "," +
                        std::to_string(nodepos.Y) + "," + std::to_string(nodepos.Z);
                std::lock_guard<std::mutex> hl(m_hud_mutex);
                m_shown_formspecs.push_back({meta->getString("formspec"), "", context});
            } else {
                sendInteract(INTERACT_PLACE, pointed);
            }
        }
    } else if (pointed.type == POINTEDTHING_OBJECT) {
        // punch on press, place/use on right
        if (in.dig && !m_btn_down_for_dig) {
            m_btn_down_for_dig = true;
            sendInteract(INTERACT_START_DIGGING, pointed);
            m_nodig_delay_timer = std::max(0.15f, repeat_dig_time);
        }
        if (in.place_pressed)
            sendInteract(INTERACT_PLACE, pointed);
    } else {
        // pointing at nothing: right click = activate (Game::handlePointingAtNothing)
        if (in.place_pressed) {
            PointedThing fauxPointed;
            fauxPointed.type = POINTEDTHING_NOTHING;
            sendInteract(INTERACT_ACTIVATE, fauxPointed);
        }
    }
    m_pointed_old = pointed;
    // crack overlay: re-mesh the block when the crack level or position changes
    static int last_level = -1;
    static v3s16 last_pos;
    if (m_interact.crack_level != last_level || (m_interact.crack_level >= 0 && m_interact.crack_pos != last_pos)) {
        if (last_level >= 0)
            m_new_blocks.push_back(getNodeBlockPos(last_pos));
        if (m_interact.crack_level >= 0)
            m_new_blocks.push_back(getNodeBlockPos(m_interact.crack_pos));
        last_level = m_interact.crack_level;
        last_pos = m_interact.crack_pos;
    }
}

void GoannaSession::stepObjects(float dtime) {
    for (auto &kv : m_objects) {
        GoannaActiveObject *obj = kv.second.get();
        const GoannaActiveObject *parent = nullptr;
        if (obj->attachmentParent() != 0) {
            auto it = m_objects.find(obj->attachmentParent());
            if (it != m_objects.end())
                parent = it->second.get();
        }
        obj->step(dtime, m_map.get(), this, parent);
    }
}

// Client::handleCommand_ActiveObjectRemoveAdd, transplanted.
void GoannaSession::onActiveObjectRemoveAdd(NetworkPacket &pkt) {
    u8 type;
    u16 removed_count, added_count, id;
    pkt >> removed_count;
    std::lock_guard<std::mutex> lk(m_map_mutex);
    for (u16 i = 0; i < removed_count; i++) {
        pkt >> id;
        m_objects.erase(id);
    }
    pkt >> added_count;
    for (u16 i = 0; i < added_count; i++) {
        pkt >> id >> type;
        std::string init_data = pkt.readLongString();
        auto obj = std::make_unique<GoannaActiveObject>(id, type);
        try {
            obj->initialize(init_data, m_player.get());
        } catch (const std::exception &e) {
            errorstream << "goanna: bad active object init data for id " << id << ": " << e.what() << std::endl;
            continue;
        }
        m_objects[id] = std::move(obj);
    }
}

// Client::handleCommand_ActiveObjectMessages, transplanted.
void GoannaSession::onActiveObjectMessages(NetworkPacket &pkt) {
    std::string datastring(pkt.getString(0), pkt.getSize());
    std::istringstream is(datastring, std::ios_base::binary);
    std::lock_guard<std::mutex> lk(m_map_mutex);
    while (canRead(is)) {
        u16 id = readU16(is);
        std::string message = deSerializeString16(is);
        auto it = m_objects.find(id);
        if (it == m_objects.end())
            continue;
        try {
            it->second->processMessage(message, m_player.get());
        } catch (const std::exception &e) {
            errorstream << "goanna: bad active object message for id " << id << ": " << e.what() << std::endl;
        }
    }
}

bool GoannaSession::takeServerMove(v3f &pos_bs, float &pitch, float &yaw) {
    std::lock_guard<std::mutex> lk(m_pose_mutex);
    if (!m_server_move_pending)
        return false;
    m_server_move_pending = false;
    pos_bs = m_server_move_pos;
    pitch = m_server_move_pitch;
    yaw = m_server_move_yaw;
    return true;
}

void GoannaSession::setPlayerPose(v3f pos_nodes, float pitch_deg, float yaw_deg) {
    std::lock_guard<std::mutex> lk(m_pose_mutex);
    m_pose_pos = pos_nodes * BS;
    m_pose_pitch = pitch_deg;
    m_pose_yaw = yaw_deg;
}

// --- IGameDef ---

IItemDefManager *GoannaSession::getItemDefManager() { return m_itemdef; }
const NodeDefManager *GoannaSession::getNodeDefManager() { return m_nodedef; }
u16 GoannaSession::allocateUnknownNodeId(const std::string &name) {
    return m_nodedef->allocateDummy(name);
}
const std::vector<ModSpec> &GoannaSession::getMods() const { return m_no_mods; }

// --- PeerHandler ---

void GoannaSession::peerAdded(con::IPeer *peer) {
    infostream << "goanna: peer added " << peer->id << std::endl;
}

void GoannaSession::deletingPeer(con::IPeer *peer, bool timeout) {
    infostream << "goanna: peer removed " << peer->id << (timeout ? " (timeout)" : "") << std::endl;
    if (stats().state != SessionState::Denied)
        setState(SessionState::Disconnected, timeout ? "connection timed out" : "server closed connection");
    m_running = false;
}

// --- plumbing ---

void GoannaSession::setState(SessionState s, const std::string &msg) {
    std::lock_guard<std::mutex> lk(m_stats_mutex);
    m_stats.state = s;
    if (!msg.empty())
        m_stats.message = msg;
    actionstream << "goanna: state -> " << session_state_name(s)
                 << (msg.empty() ? "" : ": " + msg) << std::endl;
}

void GoannaSession::send(NetworkPacket &pkt, bool reliable) {
    m_con->Send(PEER_ID_SERVER, 0, &pkt, reliable);
}

void GoannaSession::threadMain() {
    try {
        Address addr;
        addr.Resolve(m_host.c_str());
        addr.setPort(m_port);
        m_con.reset(con::createMTP(CONNECTION_TIMEOUT, addr.isIPv6(), this));
        setState(SessionState::Connecting, "connecting to " + m_host);
        m_con->Connect(addr);

        auto last_pos = std::chrono::steady_clock::now();
        bool init_sent = false;
        while (m_running) {
            if (!init_sent && m_con->Connected()) {
                sendInit();
                init_sent = true;
            }
            NetworkPacket pkt;
            if (m_con->ReceiveTimeoutMs(&pkt, 20)) {
                try {
                    handle(pkt);
                } catch (const std::exception &e) {
                    errorstream << "goanna: error handling command 0x" << std::hex << pkt.getCommand()
                                << std::dec << ": " << e.what() << std::endl;
                }
            }
            if (m_send_ready && !m_ready_sent)
                sendReady();
            if (m_media_announced && !m_media_done && !m_ready_sent) {
                float waited = std::chrono::duration<float>(
                        std::chrono::steady_clock::now() - m_media_announce_time).count();
                if (waited > 30.0f) {
                    warningstream << "goanna: media incomplete after 30 s; proceeding" << std::endl;
                    m_media_done = true;
                    maybeReady();
                }
            }
            SessionState st;
            {
                std::lock_guard<std::mutex> lk(m_stats_mutex);
                st = m_stats.state;
            }
            if (st == SessionState::Ready) {
                auto now = std::chrono::steady_clock::now();
                float dt = std::chrono::duration<float>(now - last_pos).count();
                if (dt >= m_recommended_send_interval) {
                    sendPlayerPos();
                    last_pos = now;
                }
                std::vector<v3s16> acks;
                {
                    std::lock_guard<std::mutex> lk(m_map_mutex);
                    acks.swap(m_ack_blocks);
                }
                if (!acks.empty())
                    sendGotBlocks(acks);
            }
        }
    } catch (const std::exception &e) {
        setState(SessionState::Error, e.what());
    }
}

// --- outgoing ---

// Follows Client::sendInit in luanti/src/client/client.cpp.
void GoannaSession::sendInit() {
    NetworkPacket pkt(TOSERVER_INIT, 1 + 2 + 2 + (1 + m_name.size()));
    pkt << SER_FMT_VER_HIGHEST_READ << (u16)0;
    pkt << CLIENT_PROTOCOL_VERSION_MIN << LATEST_PROTOCOL_VERSION;
    pkt << m_name;
    send(pkt);
    setState(SessionState::Init, "TOSERVER_INIT sent");
}

// Follows Client::startAuth in luanti/src/client/client.cpp.
void GoannaSession::startAuth(AuthMechanism mech) {
    m_chosen_auth = mech;
    switch (mech) {
    case AUTH_MECHANISM_FIRST_SRP: {
        std::string verifier, salt;
        generate_srp_verifier_and_salt(m_name, m_password, &verifier, &salt);
        NetworkPacket pkt(TOSERVER_FIRST_SRP, 0);
        pkt << salt << verifier << (u8)(m_password.empty() ? 1 : 0);
        send(pkt);
        setState(SessionState::Auth, "registering (FIRST_SRP)");
        break;
    }
    case AUTH_MECHANISM_SRP:
    case AUTH_MECHANISM_LEGACY_PASSWORD: {
        u8 based_on = 1;
        std::string password = m_password;
        if (mech == AUTH_MECHANISM_LEGACY_PASSWORD) {
            password = translate_password(m_name, m_password);
            based_on = 0;
        }
        std::string name_lower = lowercase(m_name);
        m_srp = srp_user_new(SRP_SHA256, SRP_NG_2048, m_name.c_str(), name_lower.c_str(),
                (const unsigned char *)password.c_str(), password.size(), nullptr, nullptr);
        char *bytes_A = nullptr;
        size_t len_A = 0;
        SRP_Result res = srp_user_start_authentication(m_srp, nullptr, nullptr, 0,
                (unsigned char **)&bytes_A, &len_A);
        if (res != SRP_OK) {
            setState(SessionState::Error, "SRP user creation failed");
            return;
        }
        NetworkPacket pkt(TOSERVER_SRP_BYTES_A, 0);
        pkt << std::string(bytes_A, len_A) << based_on;
        send(pkt);
        setState(SessionState::Auth, "authenticating (SRP)");
        break;
    }
    case AUTH_MECHANISM_NONE:
        break;
    }
}

void GoannaSession::sendInit2() {
    std::string lang;
    NetworkPacket pkt(TOSERVER_INIT2, sizeof(u16) + lang.size());
    pkt << lang;
    send(pkt);
}

void GoannaSession::sendReady() {
    NetworkPacket pkt(TOSERVER_CLIENT_READY, 1 + 1 + 1 + 1 + 2 + strlen(g_version_hash) + 2);
    pkt << (u8)VERSION_MAJOR << (u8)VERSION_MINOR << (u8)VERSION_PATCH << (u8)0
        << (u16)strlen(g_version_hash);
    pkt.putRawString(g_version_hash, (u16)strlen(g_version_hash));
    pkt << (u16)FORMSPEC_API_VERSION;
    send(pkt);
    m_ready_sent = true;
    setState(SessionState::Ready, "TOSERVER_CLIENT_READY sent");
}

void GoannaSession::writePlayerPosTo(NetworkPacket &pkt) {
    v3f pos;
    float pitch, yaw;
    {
        std::lock_guard<std::mutex> lk(m_pose_mutex);
        pos = m_pose_pos;
        pitch = m_pose_pitch;
        yaw = m_pose_yaw;
    }
    // Format documented at TOSERVER_PLAYERPOS in networkprotocol.h.
    v3s32 position = v3s32::from(pos * 100);
    v3s32 speed(0, 0, 0);
    s32 ipitch = pitch * 100;
    s32 iyaw = yaw * 100;
    u32 keys = 0;
    u8 fov = (u8)std::min(255.0f, 1.2f * 80.0f);
    u8 wanted_range = 10; // blocks
    u8 camera_inverted = 0;
    f32 movement_speed = 0, movement_dir = 0;
    pkt << position << speed << ipitch << iyaw << keys << fov << wanted_range << camera_inverted
        << movement_speed << movement_dir;
}

void GoannaSession::sendPlayerPos() {
    NetworkPacket pkt(TOSERVER_PLAYERPOS, 12 + 12 + 4 + 4 + 4 + 1 + 1 + 1 + 4 + 4);
    writePlayerPosTo(pkt);
    send(pkt, false);
}

void GoannaSession::sendGotBlocks(const std::vector<v3s16> &blocks) {
    // u8 count limits a packet to 255 blocks.
    for (size_t i = 0; i < blocks.size(); i += 255) {
        size_t n = std::min<size_t>(255, blocks.size() - i);
        NetworkPacket pkt(TOSERVER_GOTBLOCKS, 1 + 6 * n);
        pkt << (u8)n;
        for (size_t k = 0; k < n; ++k)
            pkt << blocks[i + k];
        send(pkt);
    }
}

u8 GoannaSession::emissiveLevel(u32 texture_id) const {
    auto it = m_emissive_by_texture.find(texture_id);
    return it == m_emissive_by_texture.end() ? 0 : it->second;
}

bool GoannaSession::getMedia(const std::string &name, std::string &out) const {
    std::lock_guard<std::mutex> lk(m_media_mutex);
    auto it = m_media.find(name);
    if (it == m_media.end())
        return false;
    out = it->second;
    return true;
}

bool GoannaSession::mediaComplete() const {
    return m_media_done;
}

void GoannaSession::requestMedia(const std::vector<std::string> &names) {
    // TOSERVER_REQUEST_MEDIA: u16 count, then names. Chunk to keep packets sane.
    const size_t CHUNK = 500;
    for (size_t i = 0; i < names.size(); i += CHUNK) {
        size_t n = std::min(CHUNK, names.size() - i);
        NetworkPacket pkt(TOSERVER_REQUEST_MEDIA, 2);
        pkt << (u16)n;
        for (size_t k = 0; k < n; ++k)
            pkt << names[i + k];
        send(pkt);
    }
}

void GoannaSession::maybeReady() {
    if (!m_ready_sent && !m_content_ready && m_nodedef_received && m_itemdef_received &&
            m_media_announced && m_media_done) {
        m_content_ready = true;
        setState(SessionState::ContentReady, "content received; building visuals");
    }
}

static bool isImageName(const std::string &name) {
    std::string ext = name.size() > 4 ? name.substr(name.size() - 4) : "";
    for (auto &c : ext) c = tolower(c);
    return ext == ".png" || ext == ".jpg" || ext == ".tga" || ext == ".bmp" || ext == "jpeg";
}

bool GoannaSession::prepareContentIfReady() {
    if (!m_content_ready || m_send_ready)
        return false;
    // 1. media images into the texture source
    size_t n_img = 0;
    {
        std::lock_guard<std::mutex> lk(m_media_mutex);
        for (auto &kv : m_media) {
            if (isImageName(kv.first) && m_tsrc->insertMediaImage(kv.first, kv.second))
                ++n_img;
        }
    }
    // 2. node definitions: same order as Client::afterContentReceived
    {
        std::lock_guard<std::mutex> lk(m_map_mutex);
        m_nodedef->updateAliases(m_itemdef);
        m_nodedef->setNodeRegistrationStatus(true);
        m_nodedef->runNodeResolveCallbacks();
        NodeVisuals::fillNodeVisuals(m_nodedef, m_mesh_client.get(), nullptr);
        // Which textures belong to light-emitting nodes (emissive materials).
        // Materials are keyed by texture, and a texture can be shared between
        // a glowing node and a plain one (games register hidden light-emitting
        // variants of stone, dirt and so on), so a texture counts as emissive
        // only if every node that shows it emits light: the minimum, not the
        // maximum. Torches, glowstone and lava textures survive that test.
        std::map<u32, u8> min_light;
        for (content_t id = 0; id < 65535; ++id) {
            const ContentFeatures &f = m_nodedef->get(id);
            if (f.name.empty() || f.name == "unknown" || !f.visuals)
                continue;
            auto note = [&](u32 tid) {
                if (!tid)
                    return;
                auto it = min_light.find(tid);
                if (it == min_light.end())
                    min_light[tid] = f.light_source;
                else
                    it->second = std::min(it->second, f.light_source);
            };
            for (int i = 0; i < 6; ++i)
                for (int l = 0; l < MAX_TILE_LAYERS; ++l)
                    note(f.visuals->tiles[i].layers[l].texture_id);
            for (int i = 0; i < CF_SPECIAL_COUNT; ++i)
                for (int l = 0; l < MAX_TILE_LAYERS; ++l)
                    note(f.visuals->special_tiles[i].layers[l].texture_id);
        }
        m_emissive_by_texture.clear();
        for (auto &kv : min_light)
            if (kv.second > 0)
                m_emissive_by_texture[kv.first] = kv.second;
    }
    actionstream << "goanna: content prepared: " << n_img << " images, node visuals filled" << std::endl;
    m_send_ready = true; // session thread sends CLIENT_READY
    return true;
}

// --- incoming ---

void GoannaSession::handle(NetworkPacket &pkt) {
    switch (pkt.getCommand()) {
    case TOCLIENT_HELLO: onHello(pkt); break;
    case TOCLIENT_SRP_BYTES_S_B: onSrpBytesSB(pkt); break;
    case TOCLIENT_AUTH_ACCEPT: onAuthAccept(pkt); break;
    case TOCLIENT_ACCESS_DENIED: onAccessDenied(pkt); break;
    case TOCLIENT_NODEDEF: onNodeDef(pkt); break;
    case TOCLIENT_ITEMDEF: onItemDef(pkt); break;
    case TOCLIENT_ANNOUNCE_MEDIA: onAnnounceMedia(pkt); break;
    case TOCLIENT_MEDIA: onMedia(pkt); break;
    case TOCLIENT_BLOCKDATA: onBlockData(pkt); break;
    case TOCLIENT_MOVE_PLAYER: onMovePlayer(pkt); break;
    case TOCLIENT_MOVEMENT: onMovement(pkt); break;
    case TOCLIENT_ADDNODE: onAddNode(pkt); break;
    case TOCLIENT_REMOVENODE: onRemoveNode(pkt); break;
    case TOCLIENT_PRIVILEGES: onPrivileges(pkt); break;
    case TOCLIENT_TIME_OF_DAY: onTimeOfDay(pkt); break;
    case TOCLIENT_SET_SKY: onSetSky(pkt); break;
    case TOCLIENT_ACTIVE_OBJECT_REMOVE_ADD: onActiveObjectRemoveAdd(pkt); break;
    case TOCLIENT_ACTIVE_OBJECT_MESSAGES: onActiveObjectMessages(pkt); break;
    case TOCLIENT_CHAT_MESSAGE: onChatMessage(pkt); break;
    case TOCLIENT_HP: onHP(pkt); break;
    case TOCLIENT_BREATH: onBreath(pkt); break;
    case TOCLIENT_HUDADD: onHudAdd(pkt); break;
    case TOCLIENT_HUDCHANGE: onHudChange(pkt); break;
    case TOCLIENT_HUDRM: onHudRemove(pkt); break;
    case TOCLIENT_HUD_SET_FLAGS: onHudSetFlags(pkt); break;
    case TOCLIENT_HUD_SET_PARAM: onHudSetParam(pkt); break;
    case TOCLIENT_INVENTORY: onInventory(pkt); break;
    case TOCLIENT_INVENTORY_FORMSPEC: onInventoryFormspec(pkt); break;
    case TOCLIENT_DETACHED_INVENTORY: onDetachedInventory(pkt); break;
    case TOCLIENT_NODEMETA_CHANGED: onNodemetaChanged(pkt); break;
    case TOCLIENT_SHOW_FORMSPEC: onShowFormspec(pkt); break;
    case TOCLIENT_SET_SUN: onSetSun(pkt); break;
    case TOCLIENT_SET_MOON: onSetMoon(pkt); break;
    case TOCLIENT_SET_STARS: onSetStars(pkt); break;
    case TOCLIENT_CLOUD_PARAMS: onCloudParams(pkt); break;
    case TOCLIENT_SET_LIGHTING: onSetLighting(pkt); break;
    case TOCLIENT_OVERRIDE_DAY_NIGHT_RATIO: onOverrideDayNightRatio(pkt); break;
    default:
        break; // everything else is ignored at this stage
    }
}

void GoannaSession::onHello(NetworkPacket &pkt) {
    if (pkt.getSize() < 1)
        return;
    u8 ser_ver;
    u16 unused_compression, proto_ver;
    u32 auth_mechs;
    std::string unused;
    pkt >> ser_ver >> unused_compression >> proto_ver >> auth_mechs >> unused;
    if (!ser_ver_supported_read(ser_ver)) {
        setState(SessionState::Error, "unsupported serialization version");
        return;
    }
    {
        std::lock_guard<std::mutex> lk(m_stats_mutex);
        m_stats.ser_ver = ser_ver;
        m_stats.proto_ver = proto_ver;
    }
    AuthMechanism mech = AUTH_MECHANISM_NONE;
    if (auth_mechs & AUTH_MECHANISM_SRP) mech = AUTH_MECHANISM_SRP;
    else if (auth_mechs & AUTH_MECHANISM_FIRST_SRP) mech = AUTH_MECHANISM_FIRST_SRP;
    else if (auth_mechs & AUTH_MECHANISM_LEGACY_PASSWORD) mech = AUTH_MECHANISM_LEGACY_PASSWORD;
    infostream << "goanna: HELLO ser_ver=" << (int)ser_ver << " proto=" << proto_ver
               << " auth_mechs=" << auth_mechs << std::endl;
    if (mech == AUTH_MECHANISM_NONE) {
        setState(SessionState::Denied, "no supported auth mechanism");
        m_con->Disconnect();
        return;
    }
    startAuth(mech);
}

void GoannaSession::onSrpBytesSB(NetworkPacket &pkt) {
    if (!m_srp) {
        errorstream << "goanna: SRP S_B without SRP user" << std::endl;
        return;
    }
    std::string s, B;
    pkt >> s >> B;
    char *bytes_M = nullptr;
    size_t len_M = 0;
    srp_user_process_challenge(m_srp, (const unsigned char *)s.c_str(), s.size(),
            (const unsigned char *)B.c_str(), B.size(), (unsigned char **)&bytes_M, &len_M);
    if (!bytes_M) {
        setState(SessionState::Error, "SRP-6a S_B safety check violation");
        return;
    }
    NetworkPacket resp(TOSERVER_SRP_BYTES_M, 0);
    resp << std::string(bytes_M, len_M);
    send(resp);
}

void GoannaSession::onAuthAccept(NetworkPacket &pkt) {
    if (m_srp) {
        srp_user_delete(m_srp);
        m_srp = nullptr;
    }
    v3f unused;
    u64 seed;
    f32 send_interval;
    u32 sudo_methods;
    pkt >> unused >> seed >> send_interval >> sudo_methods;
    m_recommended_send_interval = send_interval;
    {
        std::lock_guard<std::mutex> lk(m_stats_mutex);
        m_stats.map_seed = seed;
    }
    sendInit2();
    setState(SessionState::Definitions, "authenticated; waiting for definitions");
}

void GoannaSession::onAccessDenied(NetworkPacket &pkt) {
    std::string reason = "access denied";
    if (pkt.getSize() >= 1) {
        u8 code;
        pkt >> code;
        if (pkt.getRemainingBytes() >= 2) {
            std::string custom;
            pkt >> custom;
            if (!custom.empty())
                reason = custom;
        }
        reason += " (code " + std::to_string((int)code) + ")";
    }
    setState(SessionState::Denied, reason);
}

void GoannaSession::onNodeDef(NetworkPacket &pkt) {
    std::istringstream tmp_is(pkt.readLongString(), std::ios::binary);
    std::stringstream tmp_os(std::ios::binary | std::ios::in | std::ios::out);
    u16 proto = stats().proto_ver;
    if (proto >= 48)
        decompressZstd(tmp_is, tmp_os);
    else
        decompressZlib(tmp_is, tmp_os);
    m_nodedef->deSerialize(tmp_os, proto);
    m_nodedef_received = true;
    {
        std::lock_guard<std::mutex> lk(m_stats_mutex);
        std::vector<content_t> ids;
        // count registered names cheaply
        size_t n = 0;
        for (content_t id = 0; id < 4096; ++id) {
            const ContentFeatures &f = m_nodedef->get(id);
            if (!f.name.empty()) ++n;
        }
        m_stats.node_defs = n;
    }
    infostream << "goanna: node definitions received" << std::endl;
    maybeReady();
}

void GoannaSession::onItemDef(NetworkPacket &pkt) {
    std::istringstream tmp_is(pkt.readLongString(), std::ios::binary);
    std::stringstream tmp_os(std::ios::binary | std::ios::in | std::ios::out);
    u16 proto = stats().proto_ver;
    if (proto >= 48)
        decompressZstd(tmp_is, tmp_os);
    else
        decompressZlib(tmp_is, tmp_os);
    m_itemdef->deSerialize(tmp_os, proto);
    m_itemdef_received = true;
    {
        std::lock_guard<std::mutex> lk(m_stats_mutex);
        std::set<std::string> names;
        m_itemdef->getAll(names);
        m_stats.item_defs = names.size();
    }
    infostream << "goanna: item definitions received" << std::endl;
    maybeReady();
}

void GoannaSession::onAnnounceMedia(NetworkPacket &pkt) {
    u16 proto = stats().proto_ver;
    std::vector<std::string> names;
    {
        std::lock_guard<std::mutex> lk(m_media_mutex);
        if (proto >= 48) {
            std::istringstream iss(pkt.readLongString(), std::ios::binary);
            std::stringstream ss(std::ios::in | std::ios::out | std::ios::binary);
            decompressZstd(iss, ss);
            names = deserializeString16Array(ss);
            for (auto &name : names)
                m_media_wanted[name] = pkt.readRawString(20);
        } else {
            u16 num_files;
            pkt >> num_files;
            for (u16 i = 0; i < num_files; i++) {
                std::string name, sha1_base64;
                pkt >> name >> sha1_base64;
                m_media_wanted[name] = base64_decode(sha1_base64);
                names.push_back(name);
            }
        }
    }
    // Remote media servers are ignored; everything comes over the connection.
    {
        std::lock_guard<std::mutex> lk(m_stats_mutex);
        m_stats.media_announced = names.size();
    }
    m_media_announced = true;
    m_media_announce_time = std::chrono::steady_clock::now();
    infostream << "goanna: media announced: " << names.size() << " files; requesting all" << std::endl;
    if (names.empty()) {
        m_media_done = true;
    } else {
        requestMedia(names);
    }
    maybeReady();
}

void GoannaSession::onMedia(NetworkPacket &pkt) {
    u16 num_bunches, bunch_i;
    u32 num_files;
    pkt >> num_bunches >> bunch_i >> num_files;
    u16 proto = stats().proto_ver;
    size_t have = 0, want = 0;
    {
        std::lock_guard<std::mutex> lk(m_media_mutex);
        for (u32 i = 0; i < num_files; i++) {
            std::string name, data;
            pkt >> name;
            data = pkt.readLongString();
            if (proto >= 48) {
                std::istringstream iss(data, std::ios::binary);
                std::ostringstream oss(std::ios::binary);
                decompressZstd(iss, oss);
                data = oss.str();
            }
            m_media[name] = std::move(data);
        }
        have = m_media.size();
        want = m_media_wanted.size();
    }
    {
        std::lock_guard<std::mutex> lk(m_stats_mutex);
        m_stats.media_received = have;
    }
    if (have >= want && want > 0) {
        m_media_done = true;
        infostream << "goanna: all media received (" << have << " files)" << std::endl;
        maybeReady();
    }
}

void GoannaSession::onBlockData(NetworkPacket &pkt) {
    if (pkt.getSize() < 6)
        return;
    v3s16 p;
    pkt >> p;
    std::string datastring(pkt.getRemainingString(), pkt.getRemainingBytes());
    std::istringstream istr(datastring, std::ios_base::binary);
    u8 ser_ver = stats().ser_ver;

    std::lock_guard<std::mutex> lk(m_map_mutex);
    MapSector *sector = m_map->emergeSector(v2s16(p.X, p.Z));
    MapBlock *block = sector->getBlockNoCreateNoEx(p.Y);
    if (!block)
        block = sector->createBlankBlock(p.Y);
    block->deSerialize(istr, ser_ver, false);
    block->deSerializeNetworkSpecific(istr);
    m_new_blocks.push_back(p);
    // Neighbours already present must be re-meshed for their boundary faces.
    static const v3s16 dirs[6] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
    for (const v3s16 &d : dirs)
        if (m_map->getBlockNoCreateNoEx(p + d))
            m_new_blocks.push_back(p + d);
    m_ack_blocks.push_back(p);
    {
        std::lock_guard<std::mutex> lk2(m_stats_mutex);
        m_stats.blocks_received++;
    }
}

void GoannaSession::onMovePlayer(NetworkPacket &pkt) {
    v3f pos;
    f32 pitch, yaw;
    pkt >> pos >> pitch >> yaw;
    {
        std::lock_guard<std::mutex> lk(m_stats_mutex);
        m_stats.player_pos = pos / BS;
        m_stats.player_pitch = pitch;
        m_stats.player_yaw = yaw;
    }
    {
        std::lock_guard<std::mutex> lk(m_pose_mutex);
        m_server_move_pending = true;
        m_server_move_pos = pos;
        m_server_move_pitch = pitch;
        m_server_move_yaw = yaw;
    }
    setPlayerPose(pos / BS, pitch, yaw);
    infostream << "goanna: MOVE_PLAYER to " << (pos / BS).X << "," << (pos / BS).Y << ","
               << (pos / BS).Z << std::endl;
}

// Queue the block containing nodepos and any neighbouring blocks the node
// touches (a node on a block edge changes the neighbour's boundary faces).
void GoannaSession::queueBlocksAround(v3s16 nodepos) {
    v3s16 bp = getNodeBlockPos(nodepos);
    v3s16 rel = nodepos - bp * MAP_BLOCKSIZE;
    std::set<v3s16> blocks;
    blocks.insert(bp);
    for (int axis = 0; axis < 3; ++axis) {
        s16 r = axis == 0 ? rel.X : (axis == 1 ? rel.Y : rel.Z);
        v3s16 d(0, 0, 0);
        if (r == 0) d = axis == 0 ? v3s16(-1,0,0) : (axis == 1 ? v3s16(0,-1,0) : v3s16(0,0,-1));
        else if (r == MAP_BLOCKSIZE - 1) d = axis == 0 ? v3s16(1,0,0) : (axis == 1 ? v3s16(0,1,0) : v3s16(0,0,1));
        if (d != v3s16(0,0,0))
            blocks.insert(bp + d);
    }
    for (const v3s16 &b : blocks)
        if (m_map->getBlockNoCreateNoEx(b))
            m_new_blocks.push_back(b);
}

void GoannaSession::onAddNode(NetworkPacket &pkt) {
    v3s16 p;
    pkt >> p;
    u8 ser_ver = stats().ser_ver;
    auto *ptr = reinterpret_cast<const u8 *>(pkt.getRemainingString());
    pkt.skip(MapNode::serializedLength(ser_ver));
    MapNode n;
    n.deSerialize(ptr, ser_ver);
    bool keep_metadata = false;
    if (pkt.getRemainingBytes() >= 1)
        pkt >> keep_metadata;
    std::lock_guard<std::mutex> lk(m_map_mutex);
    std::map<v3s16, MapBlock *> modified;
    try {
        m_map->addNodeAndUpdate(p, n, modified, !keep_metadata);
    } catch (const InvalidPositionException &) {
        return;
    }
    for (auto &kv : modified)
        m_new_blocks.push_back(kv.first);
    queueBlocksAround(p);
}

void GoannaSession::onRemoveNode(NetworkPacket &pkt) {
    v3s16 p;
    pkt >> p;
    std::lock_guard<std::mutex> lk(m_map_mutex);
    std::map<v3s16, MapBlock *> modified;
    try {
        m_map->removeNodeAndUpdate(p, modified);
    } catch (const InvalidPositionException &) {
        return;
    }
    for (auto &kv : modified)
        m_new_blocks.push_back(kv.first);
    queueBlocksAround(p);
}

void GoannaSession::onMovement(NetworkPacket &pkt) {
    if (!m_player)
        return;
    f32 mad, maa, maf, msw, mscr, msf, mscl, msj, lf, lfs, ls, g;
    pkt >> mad >> maa >> maf >> msw >> mscr >> msf >> mscl >> msj >> lf >> lfs >> ls >> g;
    std::lock_guard<std::mutex> lk(m_map_mutex);
    LocalPlayer *p = m_player.get();
    p->movement_acceleration_default   = mad * BS;
    p->movement_acceleration_air       = maa * BS;
    p->movement_acceleration_fast      = maf * BS;
    p->movement_speed_walk             = msw * BS;
    p->movement_speed_crouch           = mscr * BS;
    p->movement_speed_fast             = msf * BS;
    p->movement_speed_climb            = mscl * BS;
    p->movement_speed_jump             = msj * BS;
    p->movement_liquid_fluidity        = lf * BS;
    p->movement_liquid_fluidity_smooth = lfs * BS;
    p->movement_liquid_sink            = ls * BS;
    p->movement_gravity                = g * BS;
    infostream << "goanna: movement params received (walk " << msw << ", jump " << msj
               << ", gravity " << g << ")" << std::endl;
}

void GoannaSession::onPrivileges(NetworkPacket &pkt) {
    u16 n;
    pkt >> n;
    LocalPlayer::Privileges privs;
    for (u16 i = 0; i < n; ++i) {
        std::string priv;
        pkt >> priv;
        if (priv == "fly") privs.fly = true;
        else if (priv == "fast") privs.fast = true;
        else if (priv == "noclip") privs.noclip = true;
    }
    std::lock_guard<std::mutex> lk(m_map_mutex);
    if (m_player)
        m_player->privileges = privs;
    infostream << "goanna: privileges: fly=" << privs.fly << " fast=" << privs.fast
               << " noclip=" << privs.noclip << std::endl;
}

void GoannaSession::onTimeOfDay(NetworkPacket &pkt) {
    if (pkt.getSize() < 2)
        return;
    u16 tod;
    pkt >> tod;
    f32 speed = 72.0f;
    if (pkt.getRemainingBytes() >= 4)
        pkt >> speed;
    {
        std::lock_guard<std::mutex> lk(m_sky_mutex);
        m_sky.time_of_day = tod / 24000.0f;
        m_sky.time_speed = speed;
        m_time_of_day_at = std::chrono::steady_clock::now();
        m_sky.version++;
    }
    std::lock_guard<std::mutex> lk(m_stats_mutex);
    m_stats.time_of_day = tod / 24000.0f;
}

SkyState GoannaSession::skyState() const {
    std::lock_guard<std::mutex> lk(m_sky_mutex);
    SkyState st = m_sky;
    // advance time locally like the real client (time_speed = game seconds per real second, 24000/day = 72 -> 20 min day)
    float elapsed = std::chrono::duration<float>(std::chrono::steady_clock::now() - m_time_of_day_at).count();
    st.time_of_day = std::fmod(st.time_of_day + elapsed * st.time_speed / 86400.0f, 1.0f);
    if (st.time_of_day < 0) st.time_of_day += 1.0f;
    if (m_tod_override >= 0.0f)
        st.time_of_day = m_tod_override;
    return st;
}

// The following decode exactly what Client::handleCommand_HudSetSky/Sun/Moon/
// Stars/CloudParams/SetLighting/OverrideDayNightRatio decode.
void GoannaSession::onSetSky(NetworkPacket &pkt) {
    if (stats().proto_ver < 39)
        return; // legacy servers: keep defaults
    SkyboxParams skybox;
    pkt >> skybox.bgcolor >> skybox.type >> skybox.clouds >>
        skybox.fog_sun_tint >> skybox.fog_moon_tint >> skybox.fog_tint_type;
    if (skybox.type == "skybox") {
        u16 texture_count;
        std::string texture;
        pkt >> texture_count;
        for (u16 i = 0; i < texture_count; i++) {
            pkt >> texture;
            skybox.textures.emplace_back(texture);
        }
    } else if (skybox.type == "regular") {
        auto &c = skybox.sky_color;
        pkt >> c.day_sky >> c.day_horizon >> c.dawn_sky >> c.dawn_horizon
            >> c.night_sky >> c.night_horizon >> c.indoors;
    }
    do {
        if (!pkt.hasRemainingBytes()) break;
        pkt >> skybox.body_orbit_tilt;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> skybox.fog_distance >> skybox.fog_start;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> skybox.fog_color;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> skybox.auto_dim_skybox;
    } while (0);
    std::lock_guard<std::mutex> lk(m_sky_mutex);
    m_sky.sky = skybox;
    m_sky.version++;
}

void GoannaSession::onSetSun(NetworkPacket &pkt) {
    SunParams sun;
    pkt >> sun.visible >> sun.texture >> sun.tonemap >> sun.sunrise >> sun.sunrise_visible >> sun.scale;
    std::lock_guard<std::mutex> lk(m_sky_mutex);
    m_sky.sun = sun;
    m_sky.version++;
}

void GoannaSession::onSetMoon(NetworkPacket &pkt) {
    MoonParams moon;
    pkt >> moon.visible >> moon.texture >> moon.tonemap >> moon.scale;
    std::lock_guard<std::mutex> lk(m_sky_mutex);
    m_sky.moon = moon;
    m_sky.version++;
}

void GoannaSession::onSetStars(NetworkPacket &pkt) {
    StarParams stars = SkyboxDefaults::getStarDefaults();
    pkt >> stars.visible >> stars.count >> stars.starcolor >> stars.scale;
    do {
        if (!pkt.hasRemainingBytes()) break;
        pkt >> stars.day_opacity;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> stars.star_seed;
    } while (0);
    std::lock_guard<std::mutex> lk(m_sky_mutex);
    m_sky.stars = stars;
    m_sky.version++;
}

void GoannaSession::onCloudParams(NetworkPacket &pkt) {
    f32 density, height, thickness;
    video::SColor color_bright, color_ambient;
    video::SColor color_shadow = video::SColor(255, 204, 204, 204);
    v2f speed;
    pkt >> density >> color_bright >> color_ambient >> height >> thickness >> speed;
    if (pkt.hasRemainingBytes())
        pkt >> color_shadow;
    std::lock_guard<std::mutex> lk(m_sky_mutex);
    m_sky.clouds.density = density;
    m_sky.clouds.color_bright = color_bright;
    m_sky.clouds.color_ambient = color_ambient;
    m_sky.clouds.color_shadow = color_shadow;
    m_sky.clouds.height = height;
    m_sky.clouds.thickness = thickness;
    m_sky.clouds.speed = speed;
    m_sky.version++;
}

void GoannaSession::onSetLighting(NetworkPacket &pkt) {
    Lighting lighting;
    {
        std::lock_guard<std::mutex> lk(m_sky_mutex);
        lighting = m_sky.lighting;
    }
    pkt >> lighting.shadow_intensity;
    do {
        if (!pkt.hasRemainingBytes()) break;
        pkt >> lighting.saturation;
        pkt >> lighting.exposure.luminance_min >> lighting.exposure.luminance_max
            >> lighting.exposure.exposure_correction >> lighting.exposure.speed_dark_bright
            >> lighting.exposure.speed_bright_dark >> lighting.exposure.center_weight_power;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> lighting.volumetric_light_strength;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> lighting.shadow_tint;
        pkt >> lighting.bloom_intensity >> lighting.bloom_strength_factor >> lighting.bloom_radius;
        if (!pkt.hasRemainingBytes()) break;
        pkt >> lighting.shadow_direction;
    } while (0);
    std::lock_guard<std::mutex> lk(m_sky_mutex);
    m_sky.lighting = lighting;
    m_sky.version++;
}

void GoannaSession::onOverrideDayNightRatio(NetworkPacket &pkt) {
    bool do_override;
    u16 ratio_u;
    pkt >> do_override >> ratio_u;
    std::lock_guard<std::mutex> lk(m_sky_mutex);
    m_sky.day_night_override = do_override;
    m_sky.day_night_override_ratio = (float)ratio_u / 65536;
    m_sky.version++;
}

} // namespace goanna
