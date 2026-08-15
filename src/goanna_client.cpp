#include "goanna_client.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "goanna_session.h"
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
    d["player_pos"] = Vector3(s.player_pos.X, s.player_pos.Y, s.player_pos.Z);
    d["time_of_day"] = s.time_of_day;
    return d;
}

int GoannaClient::pending_block_count() {
    if (!m_session)
        return 0;
    return (int)m_session->takeNewBlocks().size();
}

void GoannaClient::_bind_methods() {
    ClassDB::bind_method(D_METHOD("hello"), &GoannaClient::hello);
    ClassDB::bind_method(D_METHOD("luanti_version"), &GoannaClient::luanti_version);
    ClassDB::bind_method(D_METHOD("connect_to", "host", "port", "player_name", "password"),
            &GoannaClient::connect_to);
    ClassDB::bind_method(D_METHOD("disconnect_from_server"), &GoannaClient::disconnect_from_server);
    ClassDB::bind_method(D_METHOD("status"), &GoannaClient::status);
    ClassDB::bind_method(D_METHOD("pending_block_count"), &GoannaClient::pending_block_count);
}

} // namespace goanna
