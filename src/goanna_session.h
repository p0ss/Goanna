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

class NodeDefManager;
class IWritableItemDefManager;
class MapBlock;
class NetworkPacket;
struct SRPUser;

namespace goanna {

enum class SessionState {
    Idle,
    Connecting,   // UDP handshake in progress
    Init,         // TOSERVER_INIT sent, waiting for HELLO
    Auth,         // SRP in flight
    Definitions,  // AUTH_ACCEPT received; waiting for nodedef/itemdef/media announce
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

    // Non-blocking: spins up the receive thread.
    void start(const std::string &host, uint16_t port, const std::string &player_name,
            const std::string &password);
    void stop();

    SessionStats stats() const;

    // Snapshot of block positions received since the last call (consumed).
    std::vector<v3s16> takeNewBlocks();
    void requeueBlock(v3s16 pos); // caller holds mapLock()
    // Access to a received block; nullptr if unknown. Caller holds mapLock().
    MapBlock *getBlock(v3s16 pos);
    std::mutex &mapLock() { return m_map_mutex; }
    const NodeDefManager *nodeDefs() const { return m_nodedef; }

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
    void onTimeOfDay(NetworkPacket &pkt);

    std::string m_host;
    uint16_t m_port = 30000;
    std::string m_name, m_password;

    std::unique_ptr<con::IConnection> m_con;
    std::thread m_thread;
    std::atomic<bool> m_running{false};

    mutable std::mutex m_stats_mutex;
    SessionStats m_stats;

    std::mutex m_map_mutex;
    std::map<v3s16, std::unique_ptr<MapBlock>> m_blocks;
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
