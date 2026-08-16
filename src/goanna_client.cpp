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
#include "transplant/localplayer.h"
#include "client/mapblock_mesh.h"
#include "client/tile.h"
#include <SMesh.h>
#include <CMeshBuffer.h>
#include <SMaterial.h>
#include <godot_cpp/classes/project_settings.hpp>
#include <set>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace goanna {
struct MaterialKey {
    u32 texture_id = 0;
    int base_material = 0;   // video::E_MATERIAL_TYPE
    bool backface_culling = true;
    uint64_t hash() const {
        return ((uint64_t)texture_id << 16) | ((uint64_t)(base_material & 0xff) << 1) | (backface_culling ? 1 : 0);
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

static Color toColor(const video::SColor &c) {
    return Color(c.getRed() / 255.0f, c.getGreen() / 255.0f, c.getBlue() / 255.0f, c.getAlpha() / 255.0f);
}
static Vector3 toGodotDir(const v3f &v) { return Vector3(v.X, v.Y, -v.Z); }

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
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(key.texture_id);
    Ref<StandardMaterial3D> mat;
    mat.instantiate();
    mat->set_roughness(1.0f);
    mat->set_metallic(0.0f);
    mat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
    mat->set_texture_filter(BaseMaterial3D::TEXTURE_FILTER_NEAREST_WITH_MIPMAPS);
    mat->set_cull_mode(key.backface_culling ? BaseMaterial3D::CULL_BACK : BaseMaterial3D::CULL_DISABLED);
    if (gt) {
        Ref<ImageTexture> tex = gt->godotTexture();
        if (tex.is_valid())
            mat->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, tex);
        if (key.base_material == video::EMT_TRANSPARENT_ALPHA_CHANNEL) {
            mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
            mat->set_depth_draw_mode(BaseMaterial3D::DEPTH_DRAW_ALWAYS);
        } else if (key.base_material == video::EMT_TRANSPARENT_ALPHA_CHANNEL_REF || gt->hasAlpha()) {
            mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA_SCISSOR);
            mat->set_alpha_scissor_threshold(0.5f);
        }
    } else {
        mat->set_albedo(Color(0.9, 0.4, 0.9));
    }
    m_materials[key.hash()] = mat;
    return mat;
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
                key.base_material = (int)m.MaterialType;
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
    ClassDB::bind_method(D_METHOD("set_time_of_day_override", "tod"), &GoannaClient::set_time_of_day_override);
}

} // namespace goanna
