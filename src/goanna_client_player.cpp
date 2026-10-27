// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The local player and what is around them: step_player, the transplanted
// movement step; set_player_pose, for a camera placed from outside;
// step_interact, pointing, digging and placing; the wielded item; the entity
// renderer (sync_entities, the entity queries and the item and model
// previews); and the questions GDScript asks about a place in the map
// (node_name_at, top_surface_at, ground_height, rain_cover_rows,
// ground_albedo, is_underwater).
//
// Threads: Godot's main thread only. A method that reads the map, the local
// player or the active objects holds the session's map lock while it does.

#include "goanna_client_internal.h"

using namespace godot;

namespace goanna {

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
    // Luanti's pitch is positive looking down, Godot's rotation.x positive
    // looking up; step_player negates it for the walking path and this path
    // did not. The server culls what it sends against the look direction it
    // is told (RemoteClient::GetNextBlocks), so a flying player looking 20
    // degrees down was served as one looking 20 degrees up: the ground under
    // them fell outside the cone and a hillside at the horizon was what
    // arrived at full detail, while the foreground stayed at the far tiers.
    m_session->setPlayerPose(luanti, -pitch_deg, yaw_deg);
    // The schedulers weight by where the camera looks, and this path does not
    // go through the local player's pitch and yaw, so it has to say so
    // itself. Godot's convention, unnegated: setViewAngles wants the camera's.
    setViewAngles(pitch_deg, yaw_deg);
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
    // The same two buttons as the vanilla client's PlayerControl holds them,
    // which the local player's own dig animation reads.
    p->control.dig = dig;
    p->control.place = place;
    // Tell the server what is held, as a vanilla client does in every
    // position packet: step_player has already put the movement keys, jump,
    // aux1 and sneak into PlayerControl. Goanna sent dig and place alone
    // until 2026-09-29, so a game that picks the walk animation from the
    // keys (Mineclonia's mcl_player does) showed the body standing still
    // while it walked, which the third person camera made plain.
    m_session->setPlayerKeys(p->control.getKeysPressed());
    // From the rendered camera (see set_view_offset); Godot Z is Luanti -Z.
    in.eye_pos_bs = p->getPosition() + p->getEyeOffset()
            + v3f(m_view_offset.x, m_view_offset.y, -m_view_offset.z) * BS;
    // Luanti camera direction from pitch/yaw (Camera::update)
    float pitch = p->getPitch(), yaw = p->getYaw();
    v3f dir(0, 0, 1);
    dir.rotateYZBy(pitch);
    dir.rotateXZBy(yaw);
    in.look_dir = dir.normalize();
    m_session->stepInteract((float)dt, in);
    const auto &st = m_session->interactState();
    const PointedThing &pt = st.pointed;

    // Only contacts advance deformation; animation, sound and debris use the
    // same session clock. Skipped frames coalesce contacts without losing depth.
    if (st.crack_level >= 0 && pt.type == POINTEDTHING_NODE && g_goanna_carve_depth > 0) {
        if (st.crack_pos != m_carve_pos || st.impact_progress < m_carve.applied_progress) {
            m_carve = goanna::FormDig();
            m_carve_pos = st.crack_pos;
            // RESUME FROM THE DAMAGE ALREADY ON THE BLOCK. Starting pristine
            // threw away every earlier blow the moment a dig began: a block
            // left half mined went visibly whole again as soon as it was
            // struck, and only the blows from this dig showed. The stored
            // carve is the truth about the node; this dig continues it.
            m_session->carves().get(m_carve_pos.X, m_carve_pos.Y, m_carve_pos.Z, m_carve.damage);
            // The base shape this dig carves from: a plain cube for an
            // ordinary solid node, or the target's own resolved boxes for a
            // nodebox one. Live neighbour connections are NOT replicated
            // here (that scan lives in drawNodeboxNode); this is an
            // approximation for the PREDICTION only, while digging. The
            // stored carve, once meshed, always uses the true connected
            // shape.
            const MapNode target = m_session->map().getNode(m_carve_pos);
            const ContentFeatures &target_f = m_session->nodeDefs()->get(target);
            if (target_f.drawtype == NDT_NODEBOX) {
                std::vector<aabb3f> boxes;
                target.getNodeBoxes(m_session->nodeDefs(), &boxes, 0);
                std::vector<goanna::FormBox> local_boxes;
                local_boxes.reserve(boxes.size());
                for (const aabb3f &b : boxes) {
                    local_boxes.push_back({b.MinEdge.X / BS, b.MinEdge.Y / BS, b.MinEdge.Z / BS,
                            b.MaxEdge.X / BS, b.MaxEdge.Y / BS, b.MaxEdge.Z / BS});
                }
                m_carve.beginBoxes(local_boxes, 8);
            } else {
                m_carve.beginCube();
            }
        }
        const v3f hit = pt.intersection_point / BS
                - v3f((f32)m_carve_pos.X, (f32)m_carve_pos.Y, (f32)m_carve_pos.Z);
        const float progress = st.impact_progress;
        const v3f normal = pt.intersection_normal;
        if (st.dig_impact && m_carve.advance(progress, hit.X, hit.Y, hit.Z,
                normal.X, normal.Y, normal.Z))
            m_session->invalidateBlock(getNodeBlockPos(m_carve_pos));
        m_carve_active = true;
    } else if (m_carve_active) {
        // The dig is over, by breaking through or by letting go. Tell the
        // server what was carved before dropping it, so the other players keep
        // seeing it; a server without goanna_shared_dig_damage discards this
        // and nothing here depends on an answer.
        //
        // On the END of the dig rather than every step: a carve is reported
        // once, not sixteen times, and the only state worth sharing is the
        // state it was left in.
        const std::string bytes = goanna::encodeForm(m_carve.damage);
        if (!bytes.empty())
            m_session->reportCarve(m_carve_pos, bytes);
        // The same replacement removes both cut geometry and neighbour reveals.
        m_session->invalidateBlock(getNodeBlockPos(m_carve_pos));
        m_carve_active = false;
        m_carve = goanna::FormDig();
        m_carve_pos = v3s16(-32768, -32768, -32768);
    }
    if (pt.type == POINTEDTHING_NODE) {
        d["type"] = "node";
        d["node"] = Vector3(pt.node_undersurface.X, pt.node_undersurface.Y, -pt.node_undersurface.Z);
        d["above"] = Vector3(pt.node_abovesurface.X, pt.node_abovesurface.Y, -pt.node_abovesurface.Z);
        d["point"] = Vector3(pt.intersection_point.X / BS, pt.intersection_point.Y / BS, -pt.intersection_point.Z / BS);
        d["node_name"] = String::utf8(m_session->nodeDefs()->get(m_session->map().getNode(pt.node_undersurface)).name.c_str());
        // Game::handlePointingAtNode shows the node's "infotext" metadata in
        // the top left corner, raw, escapes and all, for the HUD to colour.
        if (NodeMetadata *meta = m_session->map().getNodeMetadata(pt.node_undersurface))
            d["infotext"] = String::utf8(meta->getString("infotext").c_str());
    } else if (pt.type == POINTEDTHING_OBJECT) {
        d["type"] = "object";
        d["object_id"] = (int)pt.object_id;
        auto it = m_session->objects().find(pt.object_id);
        if (it != m_session->objects().end()) {
            d["object_name"] = String::utf8(it->second->name().c_str());
            // Game::handlePointingAtObject: the object's own infotext.
            d["infotext"] = String::utf8(it->second->props().infotext.c_str());
        }
    }
    d["digging"] = st.digging;
    d["dig_impact"] = st.dig_impact;
    d["impact_progress"] = st.impact_progress;
    d["carve_volume"] = m_carve_active ? m_carve.remaining_volume :
            (st.dig_impact && st.impact_progress >= 1 ? 0.0f : 1.0f);
    d["mining_swing"] = (st.digging && st.dig_time_complete < 100000) || st.dig_impact;
    d["swing"] = st.swing;
    d["progress"] = st.dig_time_complete > 0 && st.dig_time_complete < 100000.0f
            ? std::min(1.0f, st.dig_time / st.dig_time_complete) : 0.0f;
    d["crack_level"] = st.crack_level;
    return d;
}

bool GoannaClient::is_underwater(const Vector3 &eye) {
    const bool under = isUnderwaterAt(eye);
    // The water shader drops back faces unless the eye is in the water, and
    // learns where the eye is from this global; main.gd asks every frame.
    set_view_shader_parameter("goanna_eye_underwater", under ? 1.0f : 0.0f);
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

Vector2i GoannaClient::shader_pack_light_at(const Vector3 &pos) {
    if (!m_session || !m_session->nodeDefs()) return Vector2i(-1, -1);
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    v3s16 np((s16)floorf(pos.x + 0.5f), (s16)floorf(pos.y + 0.5f), (s16)floorf(-pos.z + 0.5f));
    MapNode n = m_session->map().getNode(np);
    if (n.getContent() == CONTENT_IGNORE) return Vector2i(-1, -1);
    const ContentFeatures &f = m_session->nodeDefs()->get(n);
    const auto flags = f.getLightingFlags();
    const v2f light = shaderPackLight(n.getLight(LIGHTBANK_NIGHT, flags),
            n.getLight(LIGHTBANK_DAY, flags));
    return Vector2i((int)std::lround(light.X * 240), (int)std::lround(light.Y * 240));
}

String GoannaClient::node_name_at(const Vector3 &pos) {
    if (!m_session)
        return String();
    // Water optics can query during joining. Definitions are replaced on
    // the session thread until ContentReady, so do not read them earlier.
    const SessionState state = m_session->stats().state;
    if (state != SessionState::ContentReady && state != SessionState::Ready)
        return String();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    v3s16 np((s16)floorf(pos.x + 0.5f), (s16)floorf(pos.y + 0.5f), (s16)floorf(-pos.z + 0.5f));
    MapNode n = m_session->map().getNode(np);
    if (n.getContent() == CONTENT_IGNORE)
        return String();
    return String::utf8(m_session->nodeDefs()->get(n).name.c_str());
}

// The shader the near mesh would give the node's top face, by the same
// tests keyForIrr applies (arrayPathTile, the array having built) and the
// one arrayTileKey and materialFor make between the two array shaders: the
// face's own layer decides, not the array. Upstream bunches tiles into
// arrays by size alone, 256 at a time, so on a game with many cut-out
// textures (63 per cent of Mineclonia's 16 pixel ones) every bunch has one,
// and choosing by the array drew all the ground with the scissor shader,
// which has no parallax march. A live check reads this to know which
// shader it is looking at; array_alpha is still reported, because the far
// tiers do choose by the array.
Dictionary GoannaClient::top_surface_at(const Vector3 &pos) {
    Dictionary out;
    if (!m_session)
        return out;
    content_t c;
    {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        v3s16 np((s16)floorf(pos.x + 0.5f), (s16)floorf(pos.y + 0.5f), (s16)floorf(-pos.z + 0.5f));
        c = m_session->map().getNode(np).getContent();
    }
    const ContentFeatures &f = m_session->nodeDefs()->get(c);
    out["node"] = String::utf8(f.name.c_str());
    out["shader"] = "none";
    if (!f.visuals)
        return out;
    // Tile 0 is the top (+Y) face.
    const TileLayer &l = f.visuals->tiles[0].layers[0];
    const bool culled = (l.material_flags & MATERIAL_FLAG_BACKFACE_CULLING) != 0;
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(l.texture_id);
    const bool is_array = gt && gt->isArray();
    const bool array_path = arrayPathTile(l.material_type, culled) &&
            !specialLayer(gt, l.texture_layer_idx);
    out["texture"] = String::utf8(m_session->tsrc()->imageName(l.texture_id, l.texture_layer_idx).c_str());
    out["array"] = is_array;
    out["array_path"] = array_path;
    out["array_alpha"] = is_array && gt->hasAlpha();
    out["layer_alpha"] = is_array && gt->tileHasAlpha(l.texture_layer_idx);
    if (is_array && array_path && m_session->shsrc().usesArrayTexture(l.shader_id)
            && gt->godotArray().is_valid()) {
        MaterialKey k;
        k.texture_id = l.texture_id;
        k.array_texture = true;
        k = arrayTileKey(k, gt, l.texture_layer_idx);
        out["shader"] = gt->hasAlpha() && !k.opaque_tile ? "nodes_array_scissor" : "nodes_array";
    } else
        out["shader"] = "other";
    return out;
}

// What colour the ground around the given point would throw back: the tile
// colour of the surface found under a coarse grid of columns, palette tint
// included (Mineclonia's grass is a grey texture; the green is param2).
// main.gd feeds it to the bounce light and the shader ground fill, so an
// object's underside is tinted by what it actually stands on: red desert,
// green plain, blue over open sea (weighted down: water throws back little
// diffuse light). Alpha carries the share of columns that answered, so a
// caller can hold its last tint when nothing is loaded.
// Mean surface height of the loaded columns just under the given point, or
// -1e9 when none answer (the scan reaches only a little below the camera, so
// high flight keeps the caller's last answer). main.gd anchors the haze
// layer with it, so the depth fog thins as the camera climbs above the
// terrain instead of drowning the whole ground from altitude.
float GoannaClient::ground_height(const Vector3 &center) {
    if (!m_session)
        return -1e9f;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    const s16 cx = (s16)floorf(center.x + 0.5f);
    const s16 cy = (s16)floorf(center.y + 0.5f);
    const s16 cz = (s16)floorf(-center.z + 0.5f);
    float sum = 0.0f;
    int n = 0;
    for (int dz = -4; dz <= 4; ++dz)
        for (int dx = -4; dx <= 4; ++dx)
            for (s16 y = cy + 8; y >= cy - 24; --y) {
                MapNode nd = m_session->map().getNode(v3s16(cx + dx * 3, y, cz + dz * 3));
                const content_t c = nd.getContent();
                if (c == CONTENT_AIR)
                    continue;
                if (c == CONTENT_IGNORE)
                    break;
                sum += (float)y;
                ++n;
                break;
            }
    return n >= 20 ? sum / (float)n : -1e9f;
}

// The top face of the highest node that would stop rain, per column, for a
// band of `rows` rows of `width` columns starting at Godot (x0, z0), row
// major along x. Each column is scanned from y_top down to y_bottom; one
// with nothing in the way answers y_bottom - 0.5, which reads as open sky
// all the way down to the scan's floor. Unloaded blocks are skipped rather
// than treated as solid, so an edge of the loaded world never shelters
// anything. project/game/effects/rain_cover.gd calls this a band at a time, so one
// call holds the map lock for a few hundred columns and no more.
//
// What stops rain is what a player would see stop it: anything walkable
// (roofs, glass, leaves in every game checked) and liquids, whose surface is
// where rain lands. Plants, torches and other see-through, walk-through
// nodes do not, so rain reaches the ground in a meadow. Presentation only:
// it reads the map the client already holds and asks the server nothing.
PackedFloat32Array GoannaClient::rain_cover_rows(int x0, int z0, int width, int rows,
        int y_top, int y_bottom) {
    PackedFloat32Array out;
    if (width <= 0 || rows <= 0 || y_top < y_bottom)
        return out;
    out.resize(width * rows);
    const float open = (float)y_bottom - 0.5f;
    float *dst = out.ptrw();
    for (int i = 0; i < width * rows; ++i)
        dst[i] = open;
    if (!m_session)
        return out;
    const NodeDefManager *ndef = m_session->nodeDefs();
    // Per content answer, filled as contents turn up: 0 unknown, 1 open,
    // 2 blocks. A band meets a handful of contents, so this is a few lookups.
    std::vector<u8> blocks;
    auto stops_rain = [&](content_t c) -> bool {
        if (c >= blocks.size())
            blocks.resize((size_t)c + 1, 0);
        if (blocks[c] == 0) {
            const ContentFeatures &f = ndef->get(c);
            const bool stop = c != CONTENT_AIR && c != CONTENT_IGNORE
                    && (f.walkable || f.isLiquid()
                        || f.drawtype == NDT_ALLFACES_OPTIONAL);
            blocks[c] = stop ? 2 : 1;
        }
        return blocks[c] == 2;
    };
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    for (int j = 0; j < rows; ++j) {
        // Godot z runs the other way to Luanti's.
        const s16 lz = (s16)(-(z0 + j));
        for (int i = 0; i < width; ++i) {
            const s16 lx = (s16)(x0 + i);
            int y = y_top;
            while (y >= y_bottom) {
                const v3s16 np(lx, (s16)y, lz);
                const v3s16 bp = getNodeBlockPos(np);
                const v3s16 rel = np - bp * MAP_BLOCKSIZE;
                MapBlock *block = m_session->map().getBlockNoCreateNoEx(bp);
                // Walk down to the bottom of this block, or the scan's floor.
                const int stop_y = std::max(y_bottom, (int)bp.Y * MAP_BLOCKSIZE);
                if (!block) {
                    y = stop_y - 1;
                    continue;
                }
                bool found = false;
                for (int ry = rel.Y; y >= stop_y; --ry, --y) {
                    if (stops_rain(block->getNodeNoCheck(rel.X, ry, rel.Z).getContent())) {
                        found = true;
                        break;
                    }
                }
                if (found) {
                    dst[j * width + i] = (float)y + 0.5f;
                    break;
                }
            }
        }
    }
    return out;
}

Color GoannaClient::ground_albedo(const Vector3 &center) {
    return surfaceColour(center, 4, 3, false);
}

// The colour of the dust dry ground gives off (game/effects/
// climate_particles.gd and the fog volume's dust): the face under the
// surface, not its top, so a dry grass block gives the soil's colour and
// not green, and sand or stone their own. `wide` averages the 27 nodes
// round `center` as ground_albedo does; otherwise the one column under it.
Color GoannaClient::ground_dust(const Vector3 &center, bool wide) {
    return wide ? surfaceColour(center, 4, 3, true) : surfaceColour(center, 0, 1, true);
}

// The average colour of the surface nodes of (2 * half + 1) squared
// columns `spacing` apart round `center`: their top face, or their bottom
// face when `under`; alpha the share of columns that answered.
Color GoannaClient::surfaceColour(const Vector3 &center, int half, int spacing, bool under) {
    if (!m_session)
        return Color(0.5f, 0.5f, 0.5f, 0.0f);
    // Two phases, because composing a tile image to average it is
    // milliseconds and this runs twice a second forever: the map walk under
    // its lock only gathers each column's surface (content, param2), and
    // colours come from a per content cache afterwards. At most a few
    // uncached contents are composed per call, so entering a new biome
    // warms the cache over a couple of samples instead of hitching one
    // frame; unresolved columns simply sit this sample out. The uncached
    // path was the difference between 90 and under 30 frames a second.
    struct Sample {
        content_t c;
        u16 param2;
    };
    std::vector<Sample> samples;
    int cols = 0;
    {
        std::lock_guard<std::mutex> lk(m_session->mapLock());
        const NodeDefManager *ndef = m_session->nodeDefs();
        const s16 cx = (s16)floorf(center.x + 0.5f);
        const s16 cy = (s16)floorf(center.y + 0.5f);
        const s16 cz = (s16)floorf(-center.z + 0.5f);
        for (int dz = -half; dz <= half; ++dz)
            for (int dx = -half; dx <= half; ++dx) {
                ++cols;
                for (s16 y = cy + 8; y >= cy - 16; --y) {
                    MapNode n = m_session->map().getNode(v3s16(cx + dx * spacing, y, cz + dz * spacing));
                    const content_t c = n.getContent();
                    if (c == CONTENT_AIR)
                        continue;
                    if (c == CONTENT_IGNORE)
                        break;
                    const ContentFeatures &f = ndef->get(n);
                    if (!f.visuals || !f.visuals->tiles[0].layers[0].texture_id)
                        break;
                    samples.push_back({c, n.getParam2()});
                    break;
                }
            }
    }
    const NodeDefManager *ndef = m_session->nodeDefs();
    int budget = 4;
    float r = 0.0f, g = 0.0f, b = 0.0f, w = 0.0f;
    int answered = 0;
    auto &cache = under ? m_ground_dust_cache : m_ground_albedo_cache;
    const int tile = under ? 1 : 0;
    for (const Sample &s : samples) {
        auto it = cache.find(s.c);
        if (it == cache.end()) {
            if (budget <= 0)
                continue;
            --budget;
            const ContentFeatures &f = ndef->get(s.c);
            const TileLayer &tl = f.visuals->tiles[tile].layers[0];
            const std::string tname = m_session->tsrc()->imageName(tl.texture_id, tl.texture_layer_idx);
            video::SColor avg(0, 0, 0, 0);
            if (!tname.empty())
                avg = m_session->tsrc()->getTextureAverageColor(tname);
            it = cache.emplace(s.c, avg.color).first;
        }
        const video::SColor avg(it->second);
        if (avg.getAlpha() == 0)
            continue;
        const ContentFeatures &f = ndef->get(s.c);
        // A tile with its own colour keeps it: a grass block's dirt sides
        // and underside are white against the palette that greens its top.
        const TileLayer &tl = f.visuals->tiles[tile].layers[0];
        const video::SColor pc = tl.has_color ? tl.color : f.visuals->getColor(f, s.param2);
        const float wt = f.isLiquid() ? 0.35f : 1.0f;
        r += (avg.getRed() / 255.0f) * (pc.getRed() / 255.0f) * wt;
        g += (avg.getGreen() / 255.0f) * (pc.getGreen() / 255.0f) * wt;
        b += (avg.getBlue() / 255.0f) * (pc.getBlue() / 255.0f) * wt;
        w += wt;
        ++answered;
    }
    if (w <= 0.0f)
        return Color(0.5f, 0.5f, 0.5f, 0.0f);
    return Color(r / w, g / w, b / w, (float)answered / (float)cols);
}

// How far one movement direction is held, from 0 to 1. A key arrives as a
// bool; a controller stick (project/input/gamepad.gd) arrives as a float, already
// past its deadzone. The type is tested rather than converted, because a
// Variant holding an int or a bool does not convert to double reliably in
// godot-cpp.
static float movementAmount(const Dictionary &keys, const char *name) {
    Variant v = keys.get(name, false);
    float amount = 0.0f;
    switch (v.get_type()) {
    case Variant::BOOL:
        amount = (bool)v ? 1.0f : 0.0f;
        break;
    case Variant::INT:
        amount = (float)(int64_t)v;
        break;
    case Variant::FLOAT:
        amount = (float)(double)v;
        break;
    default:
        break;
    }
    return std::clamp(amount, 0.0f, 1.0f);
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
        // TOCLIENT_MOVE_PLAYER carries the look as well as the position, and
        // the vanilla client turns to it (Client::handleCommand_MovePlayer
        // hands it to the camera). set_look_horizontal and
        // set_look_vertical send nothing else. Until 2026-10-06 Goanna moved
        // and kept the caller's look, so a mod framing a view for the player
        // (DorfCraft's engraving scene) was ignored. The caller takes the
        // new look from "server_look" and keeps it from then on.
        pitch_deg = -spitch;
        yaw_deg = syaw;
        out["server_look"] = Vector2(pitch_deg, yaw_deg);
    }
    // Luanti: pitch positive = looking down; yaw matches Godot after z-mirror.
    PlayerControl &c = p->control;
    // Luanti 5.17 keeps each direction as an analogue amount; keys are 0 or 1
    // and a controller stick anything between, as upstream's getAxisValue
    // feeds PlayerControl.
    c.up = movementAmount(keys, "up");
    c.down = movementAmount(keys, "down");
    c.left = movementAmount(keys, "left");
    c.right = movementAmount(keys, "right");
    // Autojump sets a flag on the player; the vanilla client feeds it back in
    // as a jump press on the next frame (game.cpp: isKeyDown(JUMP) ||
    // player->getAutojump()). Without this the flag was set and ignored.
    c.jump = (bool)keys.get("jump", false) || p->getAutojump();
    c.sneak = keys.get("sneak", false);
    c.aux1 = keys.get("aux1", false);
    c.pitch = -pitch_deg;
    c.yaw = yaw_deg;
    setViewAngles(pitch_deg, yaw_deg);
    // Upstream seeds these from the joystick each frame (0 with no stick), then
    // setMovementFromKeys() only overrides them while a direction key is held,
    // leaving them untouched otherwise. Goanna's stick arrives through the
    // direction amounts above, which setMovementFromKeys turns into speed and
    // direction as it does for keys. Goanna also reuses the persistent
    // control, so without this reset the last movement_speed sticks
    // and the player keeps walking after the key is released.
    c.movement_speed = 0.0f;
    c.movement_direction = 0.0f;
    c.setMovementFromKeys();

    if (dt > 0.1) dt = 0.1;
    if (dt > 0)
        m_session->stepPlayer((float)dt);
    if (std::getenv("GOANNA_DEBUG_MANTLE")) {
        static int n = 0;
        if (dt > 0 && (c.getKeysPressed() & 0xf) != 0 && ++n % 20 == 0)
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

// The entity renderer, made on first use with every setting it mirrors. The
// held item, item previews and model previews can make it before the first
// entity sync, and those three set only parallax and hair, so a held item
// drawn first took EntityRenderer's own auto bump default, not the client's.
void GoannaClient::ensureEntityRenderer() {
    if (m_entities)
        return;
    m_entities = std::make_unique<EntityRenderer>(this);
    m_entities->setParallax(material_strength("parallax"));
    m_entities->setHair(material_strength("hair"));
    m_entities->setHairShader(material_strength("hair_shader"));
    m_entities->setChannel("micro_shadow", material_strength("micro_shadow"));
    m_entities->setChannel("parallax_short", material_strength("parallax_short"));
    m_entities->setShowBody(m_show_body);
    m_entities->setThirdPerson(m_third_person);
    m_entities->setAutoBump(m_auto_bump);
    m_entities->setFlameMaterial(m_flame_material);
}

void GoannaClient::sync_entities(double dt) {
    if (!m_session)
        return;
    auto t0 = clock_t_::now();
    ensureEntityRenderer();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    if (dt > 0.1) dt = 0.1;
    m_session->stepObjects((float)dt);
    m_entities->sync(*m_session, (float)dt, Vector3());
    if (procedural_grass() && has_meta("goanna_grass_material") &&
            (bool)get_meta("goanna_grass_interaction", true) &&
            (int)get_meta("goanna_grass_interactors", 8) > 0)
        goanna::update_grass_interactors(this,m_entities->grass_interactors(*m_session));
    ema(m_ms_entities, ms_since(t0));
}

void GoannaClient::set_arm_swing(float s) {
    m_arm_swing = std::clamp(s, 0.0f, 1.0f);
    if (m_entities)
        m_entities->setArmSwing(m_arm_swing);
}

void GoannaClient::set_third_person(bool on) {
    m_third_person = on;
    if (m_entities)
        m_entities->setThirdPerson(on);
}

bool GoannaClient::node_walkable_at(const Vector3 &pos) {
    if (!m_session)
        return false;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    const v3s16 p((s16)std::floor(pos.x + 0.5f), (s16)std::floor(pos.y + 0.5f),
            (s16)std::floor(-pos.z + 0.5f));
    const MapNode n = m_session->map().getNode(p);
    return m_session->nodeDefs()->get(n).walkable;
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
    ensureEntityRenderer();
    ItemStack item = goanna_wielded_item(m_session.get());
    d["name"] = String::utf8(item.name.c_str());
    v3f sc(1, 1, 1);
    Ref<ArrayMesh> mesh = m_entities->buildItemMesh(*m_session, item, true, &sc);
    d["mesh"] = mesh;
    d["scale"] = Vector3(sc.X, sc.Y, sc.Z);
    return d;
}

// The light the wielded item would cast placed as a node, decoded 0 to 255,
// or 0 for anything unlit. main.gd drives the head light with it, so a torch
// in the hand lights the way. Client side only: nothing is asked of the
// server and nothing shown that is not the player's own flame.
int GoannaClient::wield_light() {
    if (!m_session)
        return 0;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    ItemStack item = goanna_wielded_item(m_session.get());
    if (item.name.empty())
        return 0;
    const NodeDefManager *ndef = m_session->nodeDefs();
    content_t id = CONTENT_IGNORE;
    if (!ndef || !ndef->getId(item.name, id))
        return 0;
    const ContentFeatures &f = ndef->get(id);
    return f.light_source > 0 ? decode_light(f.light_source) : 0;
}

Dictionary GoannaClient::item_mesh(const String &item_name) {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    ensureEntityRenderer();
    ItemStack item(item_name.utf8().get_data(), 1, 0, m_session->getItemDefManager());
    d["name"] = item_name;
    v3f sc(1, 1, 1);
    Ref<ArrayMesh> mesh = m_entities->buildItemMesh(*m_session, item, false, &sc);
    d["mesh"] = mesh;
    d["scale"] = Vector3(sc.X, sc.Y, sc.Z);
    return d;
}

Dictionary GoannaClient::model_preview(const String &mesh_name, const PackedStringArray &textures,
        const Vector2 &frame_loop, float speed) {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    ensureEntityRenderer();
    std::vector<std::string> texs;
    texs.reserve(textures.size());
    for (int i = 0; i < textures.size(); ++i)
        texs.push_back(textures[i].utf8().get_data());
    AABB box;
    Node3D *node = m_entities->buildModelPreview(*m_session, mesh_name.utf8().get_data(), texs,
            frame_loop.x, frame_loop.y, speed, &box);
    if (!node)
        return d;
    d["node"] = node;
    d["aabb"] = box;
    return d;
}

Array GoannaClient::entity_list() {
    if (!m_session || !m_entities)
        return Array();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->list(*m_session);
}

Dictionary GoannaClient::entity_anchor(int id) {
    if (!m_session || !m_entities || id <= 0 || id > 65535)
        return Dictionary();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->anchor(*m_session, (u16)id);
}

Dictionary GoannaClient::entity_animation(int id) {
    if (!m_session || !m_entities || id < 0 || id > 65535)
        return Dictionary();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    return m_entities->animation(*m_session, (u16)id);
}

} // namespace goanna
