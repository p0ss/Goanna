// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// A Luanti client session, built on Luanti's own network layer, node/item
// definition managers and MapBlock code. No Irrlicht, no rendering: it
// connects, authenticates, receives definitions and mapblocks, and keeps
// them for Goanna's Godot side to mesh and draw.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "content/mods.h"
#include "gamedef.h"
#include "irrlichttypes_bloated.h"
#include "network/peerhandler.h" // must precede connection.h (PeerHandler lookup)
#include "network/connection.h"
#include "network/networkprotocol.h"
#include "goanna_map.h"
#include "goanna_textures.h"
#include "goanna_sky.h"
#include "transplant/client/content_cao.h"
#include "goanna_models.h"
#include "hud_element.h"
#include "inventory.h"
#include "util/pointedthing.h"

class NodeDefManager;
class IWritableItemDefManager;
class MapBlock;
class NetworkPacket;
class LocalPlayer;
class Client;
struct SRPUser;

namespace goanna {

enum class SessionState {
    Idle,
    Connecting,   // UDP handshake in progress
    Init,         // TOSERVER_INIT sent, waiting for HELLO
    Auth,         // SRP in flight
    Definitions,  // AUTH_ACCEPT received; waiting for nodedef/itemdef/media
    ContentReady, // everything received; waiting for the main thread to build visuals
    Ready,        // CLIENT_READY sent; blocks flowing
    Denied,
    Disconnected,
    Error,
};

const char *session_state_name(SessionState s);

struct SessionStats {
    SessionState state = SessionState::Idle;
    std::string message;
    uint16_t proto_ver = 0;
    uint8_t ser_ver = 0;
    size_t node_defs = 0;
    size_t item_defs = 0;
    size_t media_announced = 0;
    size_t media_received = 0;
    size_t blocks_received = 0;
    v3f player_pos = v3f(0, 0, 0);
    float player_pitch = 0, player_yaw = 0;
    float time_of_day = 0;
    uint64_t map_seed = 0;
};

class GoannaSession final : public IGameDef, public con::PeerHandler {
public:
    GoannaSession();
    ~GoannaSession() override;

    // Where Luanti's base texture pack lives (the luanti/ checkout). Set once
    // before any session starts.
    static void setSharePath(const std::string &path);

    // Non-blocking: spins up the receive thread.
    void start(const std::string &host, uint16_t port, const std::string &player_name,
            const std::string &password);

    // Main-thread step: when the session reaches ContentReady, decode media
    // into the texture source, fill node visuals, then send CLIENT_READY.
    // Returns true if it did the work this call.
    bool prepareContentIfReady();
    GoannaTextureSource *tsrc() { return m_tsrc.get(); }
    GoannaShaderSource &shsrc() { return m_shsrc; }
    // Highest light_source (0..14) among nodes using this texture id, or 0.
    u8 emissiveLevel(u32 texture_id) const;
    Client *meshClient() { return m_mesh_client.get(); }
    // Models loaded from media (main thread only).
    ModelCache &models() { return *m_models; }
    void stop();

    SessionStats stats() const;

    // Snapshot of block positions received since the last call (consumed).
    std::vector<v3s16> takeNewBlocks();
    void requeueBlock(v3s16 pos); // caller holds mapLock()
    // Access to a received block; nullptr if unknown. Caller holds mapLock().
    MapBlock *getBlock(v3s16 pos);
    std::mutex &mapLock() { return m_map_mutex; }
    const NodeDefManager *nodeDefs() const { return m_nodedef; }
    GoannaMap &map() { return *m_map; }

    // Sky/lighting as last sent by the server, with time of day advanced
    // locally. Thread-safe copy.
    SkyState skyState() const;
    // Client-side override of the time of day (0..1), or <0 for none. Testing aid.
    void setTimeOfDayOverride(float tod) { m_tod_override = tod; }

    // The local player (Luanti's LocalPlayer, transplanted). Positions in
    // BS units as in Luanti. Caller holds mapLock() while stepping.
    LocalPlayer *player() { return m_player.get(); }
    // Server-set pose consumed by the controller (true once after MOVE_PLAYER).
    bool takeServerMove(v3f &pos_bs, float &pitch, float &yaw);
    // Advance the local player: transplanted from ClientEnvironment::step
    // (sub-stepping, gravity, liquid resistance). Caller holds mapLock().
    void stepPlayer(float dtime);

    // --- in-game data for the UI layer ---
    struct ChatLine { u8 type; std::wstring sender; std::wstring message; };
    // Chat lines received since the last call (consumed).
    std::vector<ChatLine> takeChat();
    void sendChat(const std::wstring &message);
    // Client -> server: a raw inventory action string (Client::inventoryAction),
    // e.g. "Move 1 current_player main 3 current_player main 5".
    void sendInventoryAction(const std::string &action);
    // HUD elements as the server defines them (id -> element). Caller holds hudLock().
    std::map<u32, HudElement> &hudElements() { return m_hud; }
    std::mutex &hudLock() { return m_hud_mutex; }
    u32 hudFlags() const { return m_hud_flags; }
    u32 hudVersion() const { return m_hud_version; }
    s32 hotbarItemCount() const { return m_hotbar_itemcount; }
    // Caller holds hudLock().
    const std::string &hotbarImage() const { return m_hotbar_image; }
    const std::string &hotbarSelectedImage() const { return m_hotbar_selected_image; }
    u16 hp() const { return m_hp; }
    u16 breath() const { return m_breath; }
    // Player inventory (Luanti's own Inventory). Caller holds mapLock().
    Inventory *inventory() { return m_inventory.get(); }
    u32 inventoryVersion() const { return m_inventory_version; }
    // Inventory at a Luanti inventory location: "current_player",
    // "detached:<name>" or "nodemeta:x,y,z"; nullptr if unknown. Caller
    // holds mapLock().
    Inventory *inventoryAt(const std::string &location);
    // Bumped when any detached inventory or node metadata changes.
    u32 detachedVersion() const { return m_detached_version; }
    const std::map<std::string, std::unique_ptr<Inventory>> &detachedInventories() const { return m_detached_inventories; }
    // Formspecs: the current inventory formspec, and a queue of shown formspecs
    // Formspecs to show: from SHOW_FORMSPEC (context empty) or opened
    // client-side from a pointed node's metadata (context "nodemeta:x,y,z",
    // Game::nodePlacement). Consumed by takeShownFormspecs().
    struct ShownFormspec {
        std::string formspec, formname, context;
    };
    std::string inventoryFormspec() const;
    std::vector<ShownFormspec> takeShownFormspecs();
    // Client -> server: fields of a node's own formspec (Client::sendNodemetaFields).
    void sendNodemetaFields(v3s16 p, const std::string &formname, const std::map<std::string, std::string> &fields);
    // Client -> server: hotbar selection.
    void sendPlayerItem(u16 index);
    // Client -> server: raw formspec fields (formname, {field: value}).
    void sendInventoryFields(const std::string &formname, const std::map<std::string, std::string> &fields);

    // --- interaction (digging, placing) ---
    struct InteractInput {
        bool dig = false;        // dig button held
        bool place = false;      // place button held
        bool place_pressed = false; // place button went down this frame
        bool sneak = false;      // sneak held: no client-side node formspecs
        v3f eye_pos_bs;          // camera position (BS units, Luanti space)
        v3f look_dir;            // unit vector, Luanti space
    };
    struct InteractState {
        PointedThing pointed;
        bool digging = false;
        float dig_time = 0, dig_time_complete = 0;
        int crack_level = -1;   // -1 none
        v3s16 crack_pos;
    };
    // Game::updatePointedThing/handleDigging/nodePlacement transplanted in
    // spirit: raycast, dig timing from tool capabilities, packets. Caller
    // holds mapLock().
    void stepInteract(float dtime, const InteractInput &in);
    const InteractState &interactState() const { return m_interact; }
    void setWieldIndex(u16 index);
    u16 wieldIndex() const { return m_wield_index; }
    int crackAnimationLength();

    // Active objects (players, mobs, items). Caller holds mapLock().
    std::map<u16, std::unique_ptr<GoannaActiveObject>> &objects() { return m_objects; }
    void stepObjects(float dtime);

    // Player pose as the client will report it to the server (position in nodes).
    void setPlayerPose(v3f pos_nodes, float pitch_deg, float yaw_deg);

    // Media (textures, models, sounds) received from the server, by name.
    // Returns nullptr if unknown/not yet received. Thread-safe copy.
    bool getMedia(const std::string &name, std::string &out) const;
    bool mediaComplete() const;

    // --- IGameDef ---
    IItemDefManager *getItemDefManager() override;
    const NodeDefManager *getNodeDefManager() override;
    ICraftDefManager *getCraftDefManager() override { return nullptr; }
    u16 allocateUnknownNodeId(const std::string &name) override;
    const std::vector<ModSpec> &getMods() const override;
    const ModSpec *getModSpec(const std::string &modname) const override { return nullptr; }
    ModStorageDatabase *getModStorageDatabase() override { return nullptr; }
    bool joinModChannel(const std::string &channel) override { return false; }
    bool leaveModChannel(const std::string &channel) override { return false; }
    bool sendModChannelMessage(const std::string &channel, const std::string &message) override { return false; }
    ModChannel *getModChannel(const std::string &channel) override { return nullptr; }
    bool isClient() override { return true; }

    // --- con::PeerHandler ---
    void peerAdded(con::IPeer *peer) override;
    void deletingPeer(con::IPeer *peer, bool timeout) override;

private:
    void threadMain();
    void handle(NetworkPacket &pkt);
    void send(NetworkPacket &pkt, bool reliable = true);
    void setState(SessionState s, const std::string &msg = "");

    void sendInit();
    void startAuth(AuthMechanism mech);
    void sendInit2();
    void sendReady();
    void sendPlayerPos();
    void sendGotBlocks(const std::vector<v3s16> &blocks);
    void maybeReady();

    void onHello(NetworkPacket &pkt);
    void onSrpBytesSB(NetworkPacket &pkt);
    void onAuthAccept(NetworkPacket &pkt);
    void onAccessDenied(NetworkPacket &pkt);
    void onNodeDef(NetworkPacket &pkt);
    void onItemDef(NetworkPacket &pkt);
    void onAnnounceMedia(NetworkPacket &pkt);
    void onMedia(NetworkPacket &pkt);
    void requestMedia(const std::vector<std::string> &names);
    void onBlockData(NetworkPacket &pkt);
    void onMovePlayer(NetworkPacket &pkt);
    void onMovement(NetworkPacket &pkt);
    void onAddNode(NetworkPacket &pkt);
    void onRemoveNode(NetworkPacket &pkt);
    void queueBlocksAround(v3s16 nodepos);
    void onPrivileges(NetworkPacket &pkt);
    void onTimeOfDay(NetworkPacket &pkt);
    void onSetSky(NetworkPacket &pkt);
    void onSetSun(NetworkPacket &pkt);
    void onSetMoon(NetworkPacket &pkt);
    void onSetStars(NetworkPacket &pkt);
    void onCloudParams(NetworkPacket &pkt);
    void onSetLighting(NetworkPacket &pkt);
    void onOverrideDayNightRatio(NetworkPacket &pkt);
    void sendInteract(u8 action, const PointedThing &pointed);
    void writePlayerPosTo(NetworkPacket &pkt);
    void selectObjects(const core::line3d<f32> &shootline, std::vector<PointedThing> &out,
            const std::optional<Pointabilities> &pointabilities);
    void onActiveObjectRemoveAdd(NetworkPacket &pkt);
    void onActiveObjectMessages(NetworkPacket &pkt);
    void onChatMessage(NetworkPacket &pkt);
    void onHP(NetworkPacket &pkt);
    void onBreath(NetworkPacket &pkt);
    void onHudAdd(NetworkPacket &pkt);
    void onHudChange(NetworkPacket &pkt);
    void onHudRemove(NetworkPacket &pkt);
    void onHudSetFlags(NetworkPacket &pkt);
    void onHudSetParam(NetworkPacket &pkt);
    void onInventory(NetworkPacket &pkt);
    void onInventoryFormspec(NetworkPacket &pkt);
    void onDetachedInventory(NetworkPacket &pkt);
    void onNodemetaChanged(NetworkPacket &pkt);
    void onShowFormspec(NetworkPacket &pkt);

    std::string m_host;
    uint16_t m_port = 30000;
    std::string m_name, m_password;

    std::unique_ptr<con::IConnection> m_con;
    std::thread m_thread;
    std::atomic<bool> m_running{false};

    mutable std::mutex m_stats_mutex;
    SessionStats m_stats;

    mutable std::mutex m_sky_mutex;
    SkyState m_sky;
    float m_tod_override = -1.0f;
    std::chrono::steady_clock::time_point m_time_of_day_at;

    std::mutex m_map_mutex;
    std::unique_ptr<GoannaMap> m_map;
    std::unique_ptr<LocalPlayer> m_player;
    std::map<u16, std::unique_ptr<GoannaActiveObject>> m_objects;
    InteractState m_interact;
    PointedThing m_pointed_old;
    float m_nodig_delay_timer = 0, m_repeat_place_timer = 0;
    bool m_dig_instantly = false, m_btn_down_for_dig = false;
    u16 m_wield_index = 0;
    int m_crack_animation_length = -1;

    mutable std::mutex m_hud_mutex;
    std::vector<ChatLine> m_chat;
    std::map<u32, HudElement> m_hud;
    u32 m_hud_flags = 0xffffffff;
    u32 m_hud_version = 0;
    s32 m_hotbar_itemcount = 8;
    std::string m_hotbar_image, m_hotbar_selected_image;
    std::atomic<u16> m_hp{20};
    std::atomic<u16> m_breath{10};
    std::unique_ptr<Inventory> m_inventory;
    u32 m_inventory_version = 0;
    std::map<std::string, std::unique_ptr<Inventory>> m_detached_inventories;
    u32 m_detached_version = 0;
    std::string m_inventory_formspec;
    std::vector<ShownFormspec> m_shown_formspecs;
    std::unique_ptr<GoannaTextureSource> m_tsrc;
    GoannaShaderSource m_shsrc;
    std::unique_ptr<ModelCache> m_models;
    std::unique_ptr<Client> m_mesh_client;
    std::map<u32, u8> m_emissive_by_texture;
    std::atomic<bool> m_content_ready{false};
    std::atomic<bool> m_send_ready{false};
    bool m_server_move_pending = false;
    v3f m_server_move_pos;
    float m_server_move_pitch = 0, m_server_move_yaw = 0;
    std::vector<v3s16> m_new_blocks;
    std::vector<v3s16> m_ack_blocks;

    NodeDefManager *m_nodedef = nullptr;
    IWritableItemDefManager *m_itemdef = nullptr;
    std::vector<ModSpec> m_no_mods;

    AuthMechanism m_chosen_auth = AUTH_MECHANISM_NONE;
    SRPUser *m_srp = nullptr;
    bool m_nodedef_received = false, m_itemdef_received = false, m_media_announced = false;
    bool m_media_done = false;
    bool m_ready_sent = false;
    std::chrono::steady_clock::time_point m_media_announce_time;

    mutable std::mutex m_media_mutex;
    std::map<std::string, std::string> m_media_wanted; // name -> sha1 raw
    std::map<std::string, std::string> m_media;        // name -> bytes

    std::mutex m_pose_mutex;
    v3f m_pose_pos = v3f(0, 0, 0);
    float m_pose_pitch = 0, m_pose_yaw = 0;
    float m_recommended_send_interval = 0.1f;
};

} // namespace goanna
