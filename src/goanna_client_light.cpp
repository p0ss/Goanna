// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// Light and sky. harvestLights notes bright nodes as blocks are meshed;
// update_lights keeps a budget of OmniLight3Ds on the nearest, and
// updateLampOcclusion the box that shades them. harvestMotes and
// update_motes do the same for ambient motes. sky_state hands the server's
// sky, sun, moon, stars, clouds, lighting and time of day to main.gd and the
// sky director.
//
// Threads: Godot's main thread only. poll_blocks calls the two harvests with
// the session's map lock held; sky_state copies the session's sky state
// under its own mutex.

#include "goanna_client_internal.h"

using namespace godot;

namespace goanna {

void GoannaClient::set_shadow_lamps(int n) {
    m_shadow_lamps = std::max(0, std::min(64, n));
}

Color toColor(const video::SColor &c) {
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
    // Definitions become immutable at ContentReady. The bridge declares
    // its mirrored world coordinate in a normal node group; other servers
    // retain their original orbit. Reflect both bodies before any consumer
    // derives lighting, shadows or shader uniforms from their directions.
    const SessionState state = m_session->stats().state;
    bool mirror_x = false;
    if (state == SessionState::ContentReady || state == SessionState::Ready) {
        // BridgeTest reserves ID 120. This node has no inventory item, so
        // Luanti's item-alias name index omits it after updateAliases().
        const ContentFeatures &marker = m_session->nodeDefs()->get(content_t(120));
        mirror_x = marker.name == "bridgetest:glowing_air" &&
            marker.getGroup("goanna_sky_mirror_x") != 0;
    }
    Vector3 sun_dir = toGodotDir(sunDirection(st.time_of_day, st.sky.body_orbit_tilt));
    Vector3 moon_dir = toGodotDir(moonDirection(st.time_of_day, st.sky.body_orbit_tilt));
    if (mirror_x) {
        sun_dir.x = -sun_dir.x;
        moon_dir.x = -moon_dir.x;
    }
    d["sky_mirror_x"] = mirror_x;
    d["version"] = (int)st.version;
    d["time_of_day"] = st.time_of_day;
    d["time_speed"] = st.time_speed;
    d["wicked_time_of_day"] = getWickedTimeOfDay(st.time_of_day);
    float ratio = st.day_night_override ? st.day_night_override_ratio : dayNightRatio(st.time_of_day) / 1000.0f;
    d["day_night_ratio"] = ratio;
    d["sun_direction"] = sun_dir;
    d["moon_direction"] = moon_dir;
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
    // The ridge probe's latest answer (lodUpdateFar): the terrain horizon
    // toward the sun's azimuth. main.gd smooths it and derives the cloud
    // deck's own horizon from height and distance.
    Dictionary ridge;
    ridge["sin"] = m_ridge_sin;
    ridge["height"] = m_ridge_height;
    ridge["distance"] = m_ridge_dist;
    d["ridge"] = ridge;
    return d;
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
        // Emissive geometry is excluded by the lamp shadow caster mask.
        // The old 0.6-node escape offset therefore detached the light from
        // its visible source for no benefit. Torches use the upper part of
        // their oriented selection box. A lantern uses its body box, keeping
        // the source inside its glass rather than at the node's origin/chain.
        l.node_pos = l.pos;
        l.liquid = f.isLiquid();
        if (l.liquid) {
            auto node_at = [&](v3s16 p) {
                v3s16 bpos = getNodeBlockPos(p);
                MapBlock *neighbour = m_session->getBlock(bpos);
                return neighbour ? neighbour->getNodeNoCheck(p - bpos * MAP_BLOCKSIZE)
                                 : MapNode(CONTENT_IGNORE);
            };
            const v3s16 p = bp * MAP_BLOCKSIZE + v3s16(x,y,z);
            auto exposed = [&](v3s16 offset) {
                MapNode other = node_at(p + offset);
                const auto &of = ndef->get(other);
                return other.getContent() != CONTENT_IGNORE && !of.walkable && !of.isLiquid();
            };
            // A lamp at the cell centre sits below the top of the bank.
            // Put it just outside an exposed emitting surface. Buried liquid
            // must not consume shadow slots or put lamps inside the terrain.
            if (exposed(v3s16(0,1,0))) {
                l.pos.y += 1.15f;
            } else {
                bool visible = false;
                for (const auto &side : {v3s16(1,0,0), v3s16(-1,0,0),
                        v3s16(0,0,1), v3s16(0,0,-1)}) {
                    if (!exposed(side))
                        continue;
                    l.pos += Vector3(side.X * 0.65f, 0.15f, -side.Z * 0.65f);
                    visible = true;
                    break;
                }
                if (!visible)
                    continue;
            }
        }
        auto torch = f.groups.find("torch");
        if (f.drawtype == NDT_TORCHLIKE ||
                (torch != f.groups.end() && torch->second > 0)) {
            std::vector<aabb3f> boxes;
            n.getSelectionBoxes(ndef, &boxes);
            if (!boxes.empty()) {
                aabb3f box = boxes[0];
                for (size_t i = 1; i < boxes.size(); ++i)
                    box.addInternalBox(boxes[i]);
                v3f tip = box.getCenter() / BS;
                tip.Y = (box.MaxEdge.Y - 0.12f * box.getExtent().Y) / BS;
                l.pos += Vector3(tip.X, tip.Y, -tip.Z);
            }
        } else if (itemgroup_get(f.groups, "lantern") > 0) {
            std::vector<aabb3f> boxes;
            n.getSelectionBoxes(ndef, &boxes);
            if (!boxes.empty()) {
                auto volume = [](const aabb3f &b) {
                    v3f e = b.getExtent();
                    return e.X * e.Y * e.Z;
                };
                const auto body = std::max_element(boxes.begin(), boxes.end(),
                        [&](const aabb3f &a, const aabb3f &b) { return volume(a) < volume(b); });
                v3f centre = body->getCenter() / BS;
                l.pos += Vector3(centre.X, centre.Y, -centre.Z);
            }
        }
        l.level = f.light_source / 14.0f;
        // colour from the node's first tile (torch textures average to warm orange)
        video::SColor c(255, 255, 220, 160);
        if (f.visuals) {
            const TileLayer &tl = f.drawtype == NDT_FLOWINGLIQUID
                    ? f.visuals->special_tiles[0].layers[0] : f.visuals->tiles[0].layers[0];
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

void GoannaClient::updateLampOcclusion(const Vector3 &around) {
    const auto started = clock_t_::now();
    if (!m_lamp_occlusion || !m_session ||
            std::none_of(m_light_slot.begin(), m_light_slot.end(),
                    [](const auto &slot) { return slot.key != 0; })) {
        set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4());
        return;
    }
    // Changes are refreshed at most ten times a second, independently of
    // the player's frame rate. Static frames do not rebuild or upload data.
    if (m_lamp_occlusion_grid.is_valid() && ms_since(m_lamp_occlusion_updated) < 100.0) return;
    m_lamp_occlusion_updated = started;
    constexpr int edge = 64;
    const int ox = (int)std::floor(around.x / 16.0f) * 16 - edge / 2;
    const int oy = (int)std::floor(around.y / 16.0f) * 16 - edge / 2;
    const int oz = (int)std::floor(around.z / 16.0f) * 16 - edge / 2;
    const v3s16 low = getNodeBlockPos(v3s16(ox, oy, -(oz + edge - 1)));
    const v3s16 high = getNodeBlockPos(v3s16(ox + edge - 1, oy + edge - 1, -oz));
    std::unique_lock<std::mutex> lock(m_session->mapLock());
    std::string signature = m_session->terrainPeer() + ":" + std::to_string(m_session->terrainDefinitions()) + ":" +
            std::to_string(ox) + ":" + std::to_string(oy) + ":" + std::to_string(oz);
    // Include all boundary blocks, including absent ones. An arrival or edit
    // refreshes the grid even when neither the camera nor lamps moved.
    for (int z = low.Z; z <= high.Z; ++z)
        for (int y = low.Y; y <= high.Y; ++y)
            for (int x = low.X; x <= high.X; ++x)
                signature += m_session->blockContentDigest(v3s16(x, y, z)) + ":" +
                        std::to_string(m_session->blockRevision(v3s16(x, y, z)));
    PackedByteArray sources;
    sources.resize(std::max(1, (int)m_light_slot.size()) * 16);
    float *source = reinterpret_cast<float *>(sources.ptrw());
    for (size_t i = 0; i < m_light_slot.size(); ++i) {
        const auto &slot = m_light_slot[i];
        const Vector3 p = slot.pos;
        source[i * 4] = p.x; source[i * 4 + 1] = p.y; source[i * 4 + 2] = p.z;
        source[i * 4 + 3] = slot.key ? 1.0f : 0.0f;
    }
    signature.append((const char *)sources.ptr(), sources.size());
    signature = hashing::sha256(signature);
    if (signature == m_lamp_occlusion_signature) {
        set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4(ox - 0.5f, oy - 0.5f, oz - 0.5f, edge));
        ema(m_ms_lamp_occlusion, ms_since(started));
        return;
    }
    std::vector<float> cells(edge * edge * edge, 0.0f);
    // Full opaque cubes only. Partial nodes retain their shadow-map path;
    // treating a door or stair as a whole cube would close visible openings.
    MapBlock *last = nullptr;
    v3s16 last_bp(-32768, -32768, -32768);
    for (int z = 0; z < edge; ++z)
        for (int y = 0; y < edge; ++y)
            for (int x = 0; x < edge; ++x) {
                const v3s16 np(ox + x, oy + y, -(oz + z));
                const v3s16 bp = getNodeBlockPos(np);
                if (bp != last_bp) { last = m_session->getBlock(bp); last_bp = bp; }
                if (!last) continue;
                const MapNode node = last->getNodeNoCheck(np - bp * MAP_BLOCKSIZE);
                if (node.getContent() == CONTENT_IGNORE) continue;
                const auto &f = m_session->nodeDefs()->get(node);
                if (f.drawtype == NDT_NORMAL && !f.light_propagates && f.light_source == 0)
                    cells[(z * edge + y) * edge + x] = -1.0f;
            }
    if (!m_session->carves().empty()) {
        for (int z = low.Z; z <= high.Z; ++z)
            for (int y = low.Y; y <= high.Y; ++y)
                for (int x = low.X; x <= high.X; ++x) {
                    CarveSnapshot carves;
                    m_session->carves().snapshot(x * 16, y * 16, z * 16, carves);
                    for (const auto &entry : carves.entries) {
                        const int gx = x * 16 + entry.x - ox, gy = y * 16 + entry.y - oy, gz = -(z * 16 + entry.z) - oz;
                        if (gx >= 0 && gx < edge && gy >= 0 && gy < edge && gz >= 0 && gz < edge)
                            cells[(gz * edge + gy) * edge + gx] = 0;
                    }
                }
    }
    for (size_t i = 0; i < m_light_slot.size(); ++i) {
        if (!m_light_slot[i].key) continue;
        const Vector3 p = m_light_slot[i].pos;
        const int x = (int)std::floor(p.x + 0.5f) - ox;
        const int y = (int)std::floor(p.y + 0.5f) - oy;
        const int z = (int)std::floor(p.z + 0.5f) - oz;
        if (x >= 0 && x < edge && y >= 0 && y < edge && z >= 0 && z < edge)
            cells[(z * edge + y) * edge + x] = (float)(i + 1);
    }
    lock.unlock();
    TypedArray<Ref<Image>> slices;
    for (int z = 0; z < edge; ++z) {
        PackedByteArray bytes;
        bytes.resize(edge * edge * sizeof(float));
        std::memcpy(bytes.ptrw(), cells.data() + z * edge * edge, bytes.size());
        slices.push_back(Image::create_from_data(edge, edge, false, Image::FORMAT_RF, bytes));
    }
    if (m_lamp_occlusion_grid.is_null()) {
        m_lamp_occlusion_grid.instantiate();
        if (m_lamp_occlusion_grid->create(Image::FORMAT_RF, edge, edge, edge, false, slices) != OK) {
            m_lamp_occlusion_grid.unref();
            set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4());
            return;
        }
    } else m_lamp_occlusion_grid->update(slices);
    const auto source_image = Image::create_from_data(std::max(1, (int)m_light_slot.size()), 1,
            false, Image::FORMAT_RGBAF, sources);
    // Pool size can change with the tier; set_image permits a new width.
    if (m_lamp_occlusion_sources.is_null()) m_lamp_occlusion_sources.instantiate();
    m_lamp_occlusion_sources->set_image(source_image);
    m_lamp_occlusion_signature = signature;
    set_view_shader_parameter("goanna_lamp_occlusion_grid", m_lamp_occlusion_grid);
    set_view_shader_parameter("goanna_lamp_occlusion_sources", m_lamp_occlusion_sources);
    set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4(ox - 0.5f, oy - 0.5f, oz - 0.5f, edge));
    ema(m_ms_lamp_occlusion, ms_since(started));
}

void GoannaClient::update_lights(const Vector3 &around, int max_lights) {
    auto t0 = clock_t_::now();
    if (max_lights <= 0) {
        // No candidate traversal or ranking for the fallback path. Negative
        // reach makes the existing baked-light blend complete even nearby.
        for (auto *light : m_light_pool) {
            light->set_visible(false);
            light->queue_free();
        }
        m_light_pool.clear();
        m_light_slot.clear();
        set_view_shader_parameter("goanna_lamp_occlusion_box", Vector4());
        m_lights_in_range = 0;
        m_light_churn = 0;
        set_view_shader_parameter("goanna_lamp_reach", -64.0f);
        ema(m_ms_lights, ms_since(t0));
        return;
    }
    static const bool no_light_shadows = getenv("GOANNA_NO_LIGHT_SHADOWS") != nullptr;
    const bool shadowed_pool = !no_light_shadows && m_shadow_lamps > 0;
    // Light admission is independent of shadow maps. Unselected lamps remain
    // lit; propagated node light supplies the world beyond the direct pool.

    // A lamp's identity is where it is. Node aligned positions make the
    // rounding exact, so this key is stable for as long as the lamp exists and
    // survives the pool being rebuilt.
    auto key_of = [](const NodeLight *l) {
        return ((int64_t)llroundf(l->node_pos.x) * 73856093LL) ^
                ((int64_t)llroundf(l->node_pos.y) * 19349663LL) ^
                ((int64_t)llroundf(l->node_pos.z) * 83492791LL);
    };
    // Steeper than linear so a level-2 firefly bush is a soft glow while a
    // level-14 torch gets the full calibrated energy.
    auto range_of = [](float level) { return 3.0f + 11.0f * level; };
    auto energy_of = [](float level) { return 4.0f * std::pow(level, 1.6f); };

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
            all.push_back({ &l, key_of(&l), score });
        }
    m_lights_in_range = (int)all.size();
    m_light_churn = 0;

    // Break ties on the key. A symmetrical build gives you equally ranked
    // lamps constantly, and without a tie-break their order comes from however
    // the block map happened to iterate, so they can swap between frames with
    // nothing having moved.
    std::sort(all.begin(), all.end(), [](const Cand &a, const Cand &b) {
        return a.key < b.key;
    });

    // A pool has hundreds of emitting cells. Sixteen adjacent lamps waste
    // the entire shadow budget on one small patch. Keep a spatially spread
    // subset of exposed liquid lamps. Choose in world-key order BEFORE
    // camera ranking/culling, or walking changes the emitting cells.
    std::vector<Cand> spread;
    std::map<v3s16, std::vector<Vector3>> liquid_cells;
    for (const Cand &candidate : all) {
        bool covered = false;
        if (candidate.l->liquid) {
            const Vector3 p = candidate.l->pos;
            const v3s16 cell((s16)std::floor(p.x/4), (s16)std::floor(p.y/4), (s16)std::floor(p.z/4));
            for (int z = -1; z <= 1 && !covered; ++z)
                for (int y = -1; y <= 1 && !covered; ++y)
                    for (int x = -1; x <= 1 && !covered; ++x) {
                        auto found = liquid_cells.find(cell + v3s16(x,y,z));
                        if (found == liquid_cells.end())
                            continue;
                        for (const Vector3 &kept : found->second)
                            if (p.distance_squared_to(kept) < 12.25f) {
                                covered = true;
                                break;
                            }
                    }
            if (!covered)
                liquid_cells[cell].push_back(p);
        }
        if (!covered)
            spread.push_back(candidate);
    }
    all.swap(spread);
    all.erase(std::remove_if(all.begin(), all.end(), [](const Cand &c) {
        return c.score >= 64.0f;
    }), all.end());
    m_lights_in_range = (int)all.size();
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

    // Where the pooled lights end, for the node shaders. A distant village
    // used to pass through three states: far tiers bake block light as
    // emission (lit), the near mesh relies on the light pool (dark, because
    // its lamps did not make the pool), then close up the pool admits them
    // (lit again). The shaders fade the same baked emission in past this
    // distance, so the middle state is lit by the bake the far field would
    // have used. The score is the camera's distance to a lamp's lit region,
    // which is what a surface's view distance approximates; unsaturated
    // pools light everything they consider, so only the 64-node candidate
    // window bounds it then.
    float unlit_from = 64.0f;
    if (all.size() > admit_limit)
        unlit_from = std::min(unlit_from, std::max(0.0f, all[admit_limit].score));
    set_view_shader_parameter(
            "goanna_lamp_reach", unlit_from);

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
        // Neither pass above ever displaces a holder that is merely inside
        // keep_limit: retaining looks at the holder's own rank alone, and
        // filling only ever touches an already free slot. So a lamp that is
        // the single best candidate in the world, freshly placed, can sit
        // outside the pool indefinitely if every slot happens to already
        // hold something still under keep_limit, which a torch placed
        // anywhere already reasonably lit does. That is the gap between "is
        // ranked within admit_limit" and "is given a slot" the comment above
        // promises does not exist. Close it: evict the worst-ranked holder
        // (never one mid fade-out) for each top-admit_limit lamp still
        // without a slot.
        for (size_t i = 0; i < admit_limit; ++i) {
            if (held.count(all[i].key))
                continue;
            size_t victim = slots, worst_rank = 0;
            for (size_t s = 0; s < slots; ++s) {
                // A held slot's fade only ever ramps up (the render loop
                // below counts it down only once holder[s] goes null), so
                // there is no fade-out to interrupt here: unlike the free
                // slot search above, excluding fade > 0 would exclude every
                // stable, fully lit lamp, which is every eviction target
                // there is.
                if (!holder[s])
                    continue;
                auto it = rank_of.find(holder[s]->key);
                const size_t r = it != rank_of.end() ? it->second : all.size();
                if (victim == slots || r > worst_rank) {
                    worst_rank = r;
                    victim = s;
                }
            }
            if (victim == slots)
                break; // nothing evictable: every slot is free
            // Only trade up. The worst holder can still rank better than
            // this candidate, and candidates only get worse from here, so
            // stop rather than swap a brighter lamp for a dimmer one.
            if (worst_rank <= i)
                break;
            // Nearby samples of one broad liquid emitter should not trade
            // places for tiny camera-distance improvements. Keep ordinary
            // newly placed torches' immediate admission unchanged.
            if (all[i].l->liquid && holder[victim]->l->liquid &&
                    holder[victim]->score - all[i].score < 2.0f)
                continue;
            held.erase(holder[victim]->key);
            holder[victim] = &all[i];
            held.insert(all[i].key);
        }
    }

    // Rank shadow candidates separately, retaining current owners with a
    // two-node advantage. Distance and emitter reach determine importance;
    // the stable key breaks ties. Fading lights also consume their map slot.
    struct ShadowCandidate { size_t slot; float score; int64_t key; };
    std::vector<ShadowCandidate> shadow_candidates;
    if (shadowed_pool) {
        for (size_t s = 0; s < slots; ++s) {
            const auto *c = holder[s];
            const LightSlot &old = m_light_slot[s];
            if (!c && (!old.key || old.fade <= 0.15f)) continue;
            const Vector3 pos = c ? c->l->pos : old.pos;
            const int64_t key = c ? c->key : old.key;
            const bool retained = m_light_pool[s]->has_shadow() && key == old.key;
            const float distance = pos.distance_to(around);
            if (distance > m_lamp_shadow_distance + (retained ? 2.0f : 0.0f)) continue;
            const float level = c ? c->l->level : old.level;
            shadow_candidates.push_back({s, distance - range_of(level) -
                    (retained ? 2.0f : 0.0f), key});
        }
        std::sort(shadow_candidates.begin(), shadow_candidates.end(),
                [](const ShadowCandidate &a, const ShadowCandidate &b) {
                    return a.score != b.score ? a.score < b.score : a.key < b.key;
                });
    }
    std::vector<bool> selected_shadow(slots, false);
    for (size_t i = 0; i < shadow_candidates.size() && i < (size_t)m_shadow_lamps; ++i)
        selected_shadow[shadow_candidates[i].slot] = true;

    // Admission and eviction ramp rather than step. Even a perfectly stable
    // pool has to drop a lamp eventually, and a lamp that vanishes between one
    // frame and the next is visible as a jump in the lighting of everything it
    // touched. About seven frames is short enough to look immediate and long
    // enough not to read as a switch.
    const float FADE_STEP = rank_pool ? 1.0f : 0.15f;

    // Wall clock, not dtime: update_lights() is called with the camera
    // position only (see the header), and a phase that free-runs off real
    // time keeps flickering even the frames a lamp's own admission or
    // ranking does not otherwise touch.
    const float flicker_t = (float)std::chrono::duration<double>(
            clock_t_::now().time_since_epoch()).count();

    for (size_t s = 0; s < slots; ++s) {
        OmniLight3D *ol = m_light_pool[s];
        LightSlot &slot = m_light_slot[s];
        const Cand *c = holder[s];
        if (c) {
            if (slot.key != c->key) {
                ++m_light_churn;
                slot.key = c->key;
                slot.fade = 0.0f;
                // A stable pseudo-random phase from the key, not the pool
                // slot: two lamps swapping slots must not swap flicker too,
                // or the swap reads as the flame itself jumping.
                slot.flicker_phase = (float)((uint64_t)c->key % 1000003u) *
                        (6.2831853f / 1000003.0f);
            }
            slot.pos = c->l->pos;
            slot.color = c->l->color;
            slot.level = c->l->level;
            slot.liquid = c->l->liquid;
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

        // A living flame, not a strobe: three sine waves at incommensurate
        // frequencies so the sum never repeats on a beat a player can catch,
        // each lamp's own phase keeping a room from pulsing in lockstep. The
        // amplitudes sum to a touch over a tenth of the lamp's energy either
        // way, which reads as restless rather than as motion.
        float flicker = 1.0f;
        if (m_light_flicker) {
            const float p = slot.flicker_phase;
            flicker = 1.0f + 0.04f * std::sin(flicker_t * 3.7f + p)
                            + 0.02f * std::sin(flicker_t * 9.1f + p * 2.3f)
                            + 0.012f * std::sin(flicker_t * 17.0f + p * 0.7f);
        }

        // Only write when something actually differs. Re-setting a light's
        // transform every frame is not free: it dirties the shadow map for a
        // lamp that has not moved since it was placed. Energy is a plain
        // scalar the shadow map does not care about, so the flicker term is
        // free to change it every frame regardless.
        const float want_range = range_of(slot.level);
        // Each spaced liquid lamp represents a patch of glowing surface.
        // Compensate for the spacing so flat banks receive useful spill.
        const float want_energy = energy_of(slot.level) * slot.fade * flicker
                * (slot.liquid ? 2.5f : 1.0f);
        if (ol->get_position() != slot.pos)
            ol->set_position(slot.pos);
        if (ol->get_color() != slot.color)
            ol->set_color(slot.color);
        if (ol->get_param(Light3D::PARAM_RANGE) != want_range)
            ol->set_param(Light3D::PARAM_RANGE, want_range);
        if (ol->get_param(Light3D::PARAM_ENERGY) != want_energy)
            ol->set_param(Light3D::PARAM_ENERGY, want_energy);
        // A point lamp approximates a broad emitting patch. Its sharp
        // specular hotspot otherwise slides across the cave as the eye moves.
        const float want_specular = slot.liquid ? 0.0f : 1.0f;
        if (ol->get_param(Light3D::PARAM_SPECULAR) != want_specular)
            ol->set_param(Light3D::PARAM_SPECULAR, want_specular);
        // Keep pools of lamplight distinct. A shallower falloff fills the
        // dark gaps between sources and flattens the room's lighting.
        if (ol->get_param(Light3D::PARAM_ATTENUATION) != 1.5f)
            ol->set_param(Light3D::PARAM_ATTENUATION, 1.5f);
        if (!ol->is_visible())
            ol->set_visible(true);
        const bool want_shadow = selected_shadow[s];
        if (ol->has_shadow() != want_shadow)
            ol->set_shadow(want_shadow);
    }
    updateLampOcclusion(around);
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
            pc = f.visuals->getColor(f, n.getParam2());
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

} // namespace goanna
