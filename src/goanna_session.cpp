#include "goanna_session.h"

#include <chrono>
#include <set>
#include <cstring>
#include <sstream>

#include "constants.h"
#include "content/mods.h"
#include "itemdef.h"
#include "log.h"
#include "mapblock.h"
#include "network/address.h"
#include "network/networkpacket.h"
#include "network/socket.h"
#include "nodedef.h"
#include "porting.h"
#include "serialization.h"
#include "settings.h"
#include "util/auth.h"
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
    g_settings = Settings::createLayer(SL_GLOBAL);
    sockets_init();
}

GoannaSession::GoannaSession() {
    ensureSettings();
    m_nodedef = createNodeDefManager();
    m_itemdef = createItemDefManager();
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
    auto it = m_blocks.find(pos);
    return it == m_blocks.end() ? nullptr : it->second.get();
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

void GoannaSession::sendInit() {
    NetworkPacket pkt(TOSERVER_INIT, 1 + 2 + 2 + (1 + m_name.size()));
    pkt << SER_FMT_VER_HIGHEST_READ << (u16)0;
    pkt << CLIENT_PROTOCOL_VERSION_MIN << LATEST_PROTOCOL_VERSION;
    pkt << m_name;
    send(pkt);
    setState(SessionState::Init, "TOSERVER_INIT sent");
}

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

void GoannaSession::sendPlayerPos() {
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
    NetworkPacket pkt(TOSERVER_PLAYERPOS, 12 + 12 + 4 + 4 + 4 + 1 + 1 + 1 + 4 + 4);
    pkt << position << speed << ipitch << iyaw << keys << fov << wanted_range << camera_inverted
        << movement_speed << movement_dir;
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

void GoannaSession::maybeReady() {
    if (!m_ready_sent && m_nodedef_received && m_itemdef_received && m_media_announced) {
        m_nodedef->updateAliases(m_itemdef);
        m_nodedef->setNodeRegistrationStatus(true);
        m_nodedef->runNodeResolveCallbacks();
        sendReady();
    }
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
    case TOCLIENT_BLOCKDATA: onBlockData(pkt); break;
    case TOCLIENT_MOVE_PLAYER: onMovePlayer(pkt); break;
    case TOCLIENT_TIME_OF_DAY: onTimeOfDay(pkt); break;
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
    u16 num_files;
    pkt >> num_files;
    {
        std::lock_guard<std::mutex> lk(m_stats_mutex);
        m_stats.media_announced = num_files;
    }
    // Media itself is not fetched yet (stage 2). We still need to have
    // "received" it from the server's point of view only in that we may send
    // CLIENT_READY whenever we like.
    m_media_announced = true;
    infostream << "goanna: media announced: " << num_files << " files" << std::endl;
    maybeReady();
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
    auto it = m_blocks.find(p);
    MapBlock *block;
    if (it == m_blocks.end()) {
        auto nb = std::make_unique<MapBlock>(p, this);
        block = nb.get();
        m_blocks[p] = std::move(nb);
    } else {
        block = it->second.get();
    }
    block->deSerialize(istr, ser_ver, false);
    block->deSerializeNetworkSpecific(istr);
    m_new_blocks.push_back(p);
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
    setPlayerPose(pos / BS, pitch, yaw);
    infostream << "goanna: MOVE_PLAYER to " << (pos / BS).X << "," << (pos / BS).Y << ","
               << (pos / BS).Z << std::endl;
}

void GoannaSession::onTimeOfDay(NetworkPacket &pkt) {
    if (pkt.getSize() < 2)
        return;
    u16 tod;
    pkt >> tod;
    std::lock_guard<std::mutex> lk(m_stats_mutex);
    m_stats.time_of_day = tod / 24000.0f;
}

} // namespace goanna
