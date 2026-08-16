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
    d["media_received"] = (int)s.media_received;
    d["materials"] = m_materials.size();
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

int GoannaClient::poll_blocks(int max_blocks) {
    if (!m_session)
        return 0;
    std::vector<v3s16> fresh = m_session->takeNewBlocks();
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
        MeshData md = meshBlock(*m_session, block);
        MeshInstance3D *mi = nullptr;
        auto it = m_block_nodes.find(bp);
        if (it != m_block_nodes.end())
            mi = it->second;
        if (md.empty()) {
            if (mi) {
                mi->queue_free();
                m_block_nodes.erase(bp);
            }
            ++done;
            continue;
        }
        Ref<ArrayMesh> mesh;
        mesh.instantiate();
        int si = 0;
        for (const SurfaceData &sd : md.surfaces) {
            PackedVector3Array verts, norms;
            PackedVector2Array uvs;
            PackedColorArray cols;
            PackedInt32Array idx;
            size_t nv = sd.positions.size() / 3;
            verts.resize(nv); norms.resize(nv); uvs.resize(nv); cols.resize(nv);
            for (size_t i = 0; i < nv; ++i) {
                verts[i] = Vector3(sd.positions[i*3], sd.positions[i*3+1], sd.positions[i*3+2]);
                norms[i] = Vector3(sd.normals[i*3], sd.normals[i*3+1], sd.normals[i*3+2]);
                uvs[i] = Vector2(sd.uvs[i*2], sd.uvs[i*2+1]);
                cols[i] = Color(sd.colors[i*4], sd.colors[i*4+1], sd.colors[i*4+2], sd.colors[i*4+3]);
            }
            idx.resize(sd.indices.size());
            for (size_t i = 0; i < sd.indices.size(); ++i)
                idx[i] = sd.indices[i];
            Array arrays;
            arrays.resize(Mesh::ARRAY_MAX);
            arrays[Mesh::ARRAY_VERTEX] = verts;
            arrays[Mesh::ARRAY_NORMAL] = norms;
            arrays[Mesh::ARRAY_TEX_UV] = uvs;
            arrays[Mesh::ARRAY_COLOR] = cols;
            arrays[Mesh::ARRAY_INDEX] = idx;
            mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
            mesh->surface_set_material(si++, m_materials.get(*m_session, sd));
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
}

} // namespace goanna
