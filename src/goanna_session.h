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
    Client *meshClient() { return m_mesh_client.get(); }
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
    std::unique_ptr<GoannaTextureSource> m_tsrc;
    GoannaShaderSource m_shsrc;
    std::unique_ptr<Client> m_mesh_client;
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
