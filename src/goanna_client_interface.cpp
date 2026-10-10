// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// What the interface reads and sends: chat, the HUD, inventories and their
// item icons, shown forms and the fields sent back, sounds, particles, dug
// node bursts, media, and the overseer view's channel and meshes. Each take_*
// method swaps a queue out of the session and converts the plain structs to
// Array and Dictionary for GDScript. Item icons are drawn in
// _on_frame_pre_draw, which _notification connects to the rendering
// server's frame_pre_draw signal.
//
// Threads: Godot's main thread only. The session's queues are taken under
// their own mutexes (docs/develop/architecture.md, "From the session to the
// main thread"); inventories and node metadata are read under the map lock.

#include "goanna_client_internal.h"

using namespace godot;

namespace goanna {

// ---- in-game data for the UI layer ----

Array GoannaClient::take_chat() {
    Array out;
    if (!m_session)
        return out;
    for (auto &line : m_session->takeChat()) {
        Dictionary d;
        d["type"] = (int)line.type;
        d["sender"] = String::utf8(wide_to_utf8(unescape_translate(line.sender)).c_str());
        d["message"] = String::utf8(wide_to_utf8(unescape_translate(line.message)).c_str());
        d["raw_message"] = String::utf8(wide_to_utf8(line.message).c_str());
        out.push_back(d);
    }
    return out;
}

void GoannaClient::send_chat(const String &message) {
    if (m_session)
        m_session->sendChat(utf8_to_wide(message.utf8().get_data()));
}

int GoannaClient::hp() const { return m_session ? m_session->hp() : 0; }
int GoannaClient::breath() const { return m_session ? m_session->breath() : 0; }

// The same Luanti mesher and material factory as the near world, supplied
// exclusively with the server's observations. Never copy the ordinary map:
// its adjacent cells can contain a cave the fortress has not discovered.
Ref<ArrayMesh> GoannaClient::overseer_mesh(const Dictionary &layer, Vector3i block_pos) {
    Ref<ArrayMesh> result;
    if (!m_session || !m_session->contentPrepared() || !layer.has("rect"))
        return result;
    const Dictionary rect = layer["rect"];
    const int x0 = rect.get("x0", 0), x1 = rect.get("x1", -1);
    const int z0 = rect.get("z0", 0), z1 = rect.get("z1", -1);
    const int y = layer.get("y", 0);
    const int width = x1 - x0 + 1, depth = z1 - z0 + 1;
    const Array cells = layer.get("cells", Array()), floors = layer.get("floors", Array());
    const Array palette = layer.get("palette", Array());
    const Array below = layer.get("below", Array());
    if (below.size() > 8) return result;
    std::vector<Array> levels{cells};
    if (below.is_empty()) levels.push_back(floors);
    else for (int d = 0; d < below.size(); ++d) {
        if (below[d].get_type() != Variant::DICTIONARY) return result;
        const Dictionary slice = below[d];
        const Array values = slice.get("cells", Array());
        if (values.size() != cells.size()) return result;
        levels.push_back(values);
    }
    const int bottom = y - (int)levels.size() + 1;
    if (width < 1 || width > 64 || depth < 1 || depth > 64 ||
            cells.size() != width * depth || floors.size() != cells.size() ||
            std::abs(y) > 30999 || std::abs(x0) > 30999 || std::abs(x1) > 30999 ||
            std::abs(z0) > 30999 || std::abs(z1) > 30999 || palette.size() > 8192)
        return result;
    const v3s16 bp(block_pos.x, block_pos.y, block_pos.z);
    if (bp.X < getNodeBlockPos(v3s16(x0, bottom, z0)).X ||
            bp.X > getNodeBlockPos(v3s16(x1, y, z1)).X ||
            bp.Z < getNodeBlockPos(v3s16(x0, bottom, z0)).Z ||
            bp.Z > getNodeBlockPos(v3s16(x1, y, z1)).Z ||
            bp.Y < getNodeBlockPos(v3s16(x0, bottom, z0)).Y ||
            bp.Y > getNodeBlockPos(v3s16(x1, y, z1)).Y)
        return result;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    std::vector<MapNode> nodes{MapNode(CONTENT_AIR), MapNode(CONTENT_AIR)};
    for (int i = 0; i < palette.size(); ++i) {
        const Dictionary entry = palette[i];
        const String name = entry.get("name", "");
        const content_t id = m_session->nodeDefs()->getId(name.utf8().get_data());
        nodes.emplace_back(id, 0, (u8)(int)entry.get("param2", 0));
    }
    MeshGrid grid{1};
    MeshMakeData data(m_session->nodeDefs(), MAP_BLOCKSIZE, grid);
    data.fillBlockDataBegin(bp);
    auto &vm = data.m_vmanip;
    for (u32 i = 0; i < vm.m_area.getVolume(); ++i) {
        vm.m_data[i] = MapNode(CONTENT_AIR);
        vm.m_flags[i] = 0;
    }
    for (int z = z0; z <= z1; ++z) {
        for (int x = x0; x <= x1; ++x) {
            const int i = (z - z0) * width + x - x0;
            bool supplied = true;
            for (int d = 0; d < (int)levels.size(); ++d) {
                const int c = levels[d][i];
                if (c < 0 || c >= (int)nodes.size()) return result;
                supplied = supplied && c > 0;
                const v3s16 at(x, y - d, z);
                if (supplied && vm.m_area.contains(at))
                    vm.m_data[vm.m_area.index(at)] = nodes[c];
            }
        }
    }
    // Separate known shaft walls can sit beneath a capped solid column.
    // Never gather their geometry from the ordinary client's map cache.
    for (int d = 0; d < below.size(); ++d) {
        const Dictionary slice = below[d];
        const Array walls = slice.get("walls", Array());
        if (walls.is_empty()) continue;
        if (walls.size() != cells.size()) return result;
        for (int i = 0; i < walls.size(); ++i) {
            const int code = walls[i];
            if (code == 0) continue;
            if (code < 2 || code >= (int)nodes.size()) return result;
            const v3s16 at(x0 + i % width, y - d - 1, z0 + i / width);
            if (vm.m_area.contains(at)) vm.m_data[vm.m_area.index(at)] = nodes[code];
        }
    }
    struct Plant { v3s16 pos; MapNode node; };
    std::vector<Plant> plants;
    for (int z = z0; z <= z1; ++z) for (int x = x0; x <= x1; ++x)
        for (int py = bottom; py <= y; ++py) {
            const v3s16 at(x, py, z);
            if (!vm.m_area.contains(at)) continue;
            const MapNode n = vm.m_data[vm.m_area.index(at)];
            if (m_session->nodeDefs()->get(n).drawtype != NDT_PLANTLIKE) continue;
            if (getNodeBlockPos(at) == bp) plants.push_back({at, n});
            vm.m_data[vm.m_area.index(at)] = MapNode(CONTENT_AIR);
        }
    // No gatherMeshData/meshGathered: those also read live map/carve state.
    MapBlockMesh built(m_session->meshClient(), &data);
    buildFakeLiquidTextures();
    std::map<uint64_t, NearSurface> groups;
    struct Vertex {
        Vector3 p, n;
        Vector2 uv, uv2;
        Color c;
        Vertex mix(const Vertex &b, float t) const {
            return {p.lerp(b.p, t), n.lerp(b.n, t), uv.lerp(b.uv, t),
                    uv2.lerp(b.uv2, t), c.lerp(b.c, t)};
        }
    };
    const Vector3 lo(x0 - 0.5f, bottom - 0.5f, -z1 - 0.5f);
    const Vector3 hi(x1 + 0.5f, y + 0.5f, -z0 + 0.5f);
    for (int tile_layer = 0; tile_layer < MAX_TILE_LAYERS; ++tile_layer) {
        scene::IMesh *mesh = built.getMesh(tile_layer);
        if (!mesh) continue;
        for (u32 b = 0; b < mesh->getMeshBufferCount(); ++b) {
            scene::IMeshBuffer *buf = mesh->getMeshBuffer(b);
            if (!buf || buf->getVertexType() != video::EVT_STANDARD || !buf->getVertexCount()) continue;
            const auto *v = (const video::S3DVertex *)buf->getVertices();
            const auto *indices = (const u16 *)buf->getIndices();
            u16 base = 0;
            MaterialKey key = keyForIrr(buf->getMaterial(), v[0].Aux & GOANNA_VERTEX_TEXTURE_MASK, &base);
            auto *source = dynamic_cast<GoannaTexture *>(buf->getMaterial().getTexture(0));
            auto *array = key.array_texture ? m_session->tsrc()->goannaTexture(key.texture_id) : nullptr;
            for (u32 t = 0; t + 2 < buf->getIndexCount(); t += 3) {
                MaterialKey own = key;
                const u16 tex_layer = (v[indices[t]].Aux & GOANNA_VERTEX_TEXTURE_MASK) + base;
                if (array) {
                    own = arrayTileKey(key, array, tex_layer);
                    const u32 special = specialLayer(array, tex_layer);
                    if (special) { own.array_texture = false; own.texture_id = special; }
                } else if (source && source->isArray() && tex_layer < source->layerNames().size()) {
                    own.texture_id = m_session->tsrc()->getTextureId(source->layerNames()[tex_layer]);
                }
                std::vector<Vertex> polygon;
                for (int k = 0; k < 3; ++k) {
                    const auto &a = v[indices[t + k]];
                    polygon.push_back({Vector3(a.Pos.X / BS + bp.X * MAP_BLOCKSIZE,
                            a.Pos.Y / BS + bp.Y * MAP_BLOCKSIZE, -(a.Pos.Z / BS + bp.Z * MAP_BLOCKSIZE)),
                            Vector3(a.Normal.X, a.Normal.Y, -a.Normal.Z),
                            Vector2(a.TCoords.X, a.TCoords.Y),
                            Vector2(own.array_texture ? (a.Aux & GOANNA_VERTEX_TEXTURE_MASK) + base : 0, 0),
                            Color(a.Color.getRed() / 255.f, a.Color.getGreen() / 255.f,
                                    a.Color.getBlue() / 255.f, a.Color.getAlpha() / 255.f)});
                }
                // Clip genuine triangles, including nodeboxes and mesh nodes
                // that extend beyond their cell, to the selected slice.
                for (int axis = 0; axis < 3; ++axis) {
                    for (int side = 0; side < 2 && !polygon.empty(); ++side) {
                        std::vector<Vertex> clipped;
                        const float bound = side ? hi[axis] : lo[axis];
                        auto distance = [&](const Vertex &a) { return side ? bound - a.p[axis] : a.p[axis] - bound; };
                        Vertex a = polygon.back();
                        float da = distance(a);
                        for (const Vertex &b : polygon) {
                            const float db = distance(b);
                            if ((da >= 0) != (db >= 0)) clipped.push_back(a.mix(b, da / (da - db)));
                            if (db >= 0) clipped.push_back(b);
                            a = b; da = db;
                        }
                        polygon = std::move(clipped);
                    }
                }
                if (polygon.size() < 3) continue;
                NearSurface &acc = groups[own.hash()];
                acc.key = own;
                const int offset = acc.verts.size();
                for (const auto &a : polygon) {
                    acc.verts.push_back(a.p); acc.norms.push_back(a.n.normalized());
                    acc.uvs.push_back(a.uv); acc.uv2s.push_back(a.uv2); acc.cols.push_back(a.c);
                    // Neutral light attributes; the isolated scene supplies
                    // lighting, never the hidden map's light/occlusion field.
                    acc.custom0.push_back(0); acc.custom0.push_back(255);
                    acc.custom0.push_back(255); acc.custom0.push_back(255);
                }
                for (int k = 1; k + 1 < (int)polygon.size(); ++k) {
                    acc.idx.push_back(offset); acc.idx.push_back(offset + k); acc.idx.push_back(offset + k + 1);
                }
            }
        }
    }
    for (const Plant &plant : plants) {
        const auto &f = m_session->nodeDefs()->get(plant.node);
        if (!f.visuals) continue;
        // Keep the real node's texture, animation and colour. Only crossed
        // plantlike cards are flattened; modelled plants keep their mesh.
        for (int layer_index = 0; layer_index < MAX_TILE_LAYERS; ++layer_index) {
            const TileLayer &tile = f.visuals->tiles[0].layers[layer_index];
            if (tile.empty()) continue;
            video::SMaterial material;
            material.MaterialType = m_session->shsrc().getShaderInfo(tile.shader_id).material;
            tile.applyMaterialOptions(material, layer_index);
            material.setTexture(0, tile.texture);
            MaterialKey key = keyForIrr(material, tile.texture_layer_idx);
            key.backface_culling = false;
            NearSurface &acc = groups[key.hash()];
            acc.key = key;
            const auto tint = tile.has_color ? tile.color : f.visuals->getColor(f, plant.node.param2);
            const Color colour(tint.getRed()/255.f, tint.getGreen()/255.f, tint.getBlue()/255.f, 1);
            const float half = std::min(0.5f, 0.5f * f.visual_scale);
            const Vector3 centre(plant.pos.X, plant.pos.Y + 0.05f + layer_index * 0.002f, -plant.pos.Z);
            const int offset = acc.verts.size();
            for (const Vector2 uv : {Vector2(0,0), Vector2(1,0), Vector2(1,1), Vector2(0,1)}) {
                acc.verts.push_back(centre + Vector3((uv.x-.5f)*2*half, 0, (uv.y-.5f)*2*half));
                acc.norms.push_back(Vector3(0,1,0)); acc.uvs.push_back(uv);
                acc.uv2s.push_back(Vector2(key.array_texture ? tile.texture_layer_idx : 0, 0));
                acc.cols.push_back(colour);
                acc.custom0.push_back(0); acc.custom0.push_back(255);
                acc.custom0.push_back(255); acc.custom0.push_back(255);
            }
            for (int i : {0,1,2,0,2,3}) acc.idx.push_back(offset+i);
        }
    }
    result.instantiate();
    for (auto &entry : groups) {
        auto &acc = entry.second;
        Array arrays;
        arrays.resize(Mesh::ARRAY_MAX);
        arrays[Mesh::ARRAY_VERTEX] = acc.verts; arrays[Mesh::ARRAY_NORMAL] = acc.norms;
        arrays[Mesh::ARRAY_TANGENT] = node_tangents(acc.verts, acc.norms, acc.uvs, acc.idx);
        arrays[Mesh::ARRAY_TEX_UV] = acc.uvs; arrays[Mesh::ARRAY_TEX_UV2] = acc.uv2s;
        arrays[Mesh::ARRAY_COLOR] = acc.cols; arrays[Mesh::ARRAY_CUSTOM0] = acc.custom0;
        arrays[Mesh::ARRAY_INDEX] = acc.idx;
        uint64_t flags = kNodeSurfaceFlags;
        if (m_lava_tex.count(acc.key.texture_id)) {
            prepareLavaSurface(arrays, *m_session, &vm);
            flags |= uint64_t(Mesh::ARRAY_CUSTOM_RGB_FLOAT) << Mesh::ARRAY_FORMAT_CUSTOM1_SHIFT;
        }
        result->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, Array(), Dictionary(), flags);
        result->surface_set_material(result->get_surface_count() - 1, materialFor(acc.key));
    }
    return result;
}

void GoannaClient::overseer_entities(Node3D *parent, const Dictionary &layer) {
    ensureEntityRenderer();
    m_entities->setOverseer(parent, layer);
}

bool GoannaClient::overseer_channel(const String &channel) {
    return m_session && m_session->setOverseerChannel(channel.utf8().get_data());
}

void GoannaClient::overseer_send(const String &message) {
    if (m_session) m_session->sendOverseer(message.utf8().get_data());
}

Array GoannaClient::overseer_take() {
    Array out;
    if (m_session)
        for (const auto &message : m_session->takeOverseer())
            out.push_back(String::utf8(message.c_str()));
    return out;
}

Dictionary GoannaClient::hud_state() const {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->hudLock());
    Array elems;
    for (auto &kv : m_session->hudElements()) {
        const HudElement &e = kv.second;
        Dictionary h;
        h["id"] = (int)kv.first;
        h["type"] = (int)e.type;
        h["pos"] = Vector2(e.pos.X, e.pos.Y);
        h["name"] = String::utf8(e.name.c_str());
        h["scale"] = Vector2(e.scale.X, e.scale.Y);
        h["text"] = String::utf8(e.text.c_str());
        h["number"] = (int)e.number;
        h["item"] = (int)e.item;
        h["dir"] = (int)e.dir;
        h["align"] = Vector2(e.align.X, e.align.Y);
        h["offset"] = Vector2(e.offset.X, e.offset.Y);
        h["world_pos"] = Vector3(e.world_pos.X, e.world_pos.Y, -e.world_pos.Z);
        h["size"] = Vector2(e.size.X, e.size.Y);
        h["z_index"] = (int)e.z_index;
        h["text2"] = String::utf8(e.text2.c_str());
        h["style"] = (int)e.style;
        h["hideable"] = e.hideable;
        elems.push_back(h);
    }
    d["elements"] = elems;
    d["flags"] = (int)m_session->hudFlags();
    d["version"] = (int)m_session->hudVersion();
    d["hotbar_itemcount"] = (int)m_session->hotbarItemCount();
    d["hotbar_image"] = String::utf8(m_session->hotbarImage().c_str());
    d["hotbar_selected_image"] = String::utf8(m_session->hotbarSelectedImage().c_str());
    d["hp"] = (int)m_session->hp();
    d["breath"] = (int)m_session->breath();
    return d;
}

// What to hand item_icon() for this stack: its name, or, when its metadata
// can change the picture (the colour and palette index keys drawItemStack
// reads, and the inventory image and overlay keys ItemStack reads), the item
// string with that metadata, so tinted candles and the like are told apart.
// Count and wear never change an icon and are left out.
static String iconItemString(const ItemStack &st) {
    const ItemStackMetadata &m = st.metadata;
    if (m.getString("color").empty() && m.getString("palette_index").empty() &&
            m.getString("inventory_image").empty() && m.getString("inventory_overlay").empty())
        return String::utf8(st.name.c_str());
    ItemStack one = st;
    one.count = 1;
    one.wear = 0;
    return String::utf8(one.getItemString().c_str());
}

static Dictionary inventoryLists(Inventory *inv, IItemDefManager *idef) {
    Dictionary lists;
    if (!inv)
        return lists;
    for (InventoryList *list : inv->getLists()) {
        Array items;
        for (u32 i = 0; i < list->getSize(); ++i) {
            const ItemStack &st = list->getItem(i);
            Dictionary it;
            it["name"] = String::utf8(st.name.c_str());
            it["count"] = (int)st.count;
            it["wear"] = (int)st.wear;
            if (!st.name.empty() && idef) {
                const ItemDefinition &def = st.getDefinition(idef);
                // The stack's own description when its metadata sets one
                // (a named or enchanted item), as GUIInventoryList's tooltip
                // reads it.
                it["description"] = String::utf8(st.getDescription(idef).c_str());
                it["inventory_image"] = String::utf8(def.inventory_image.name.c_str());
                it["icon_item"] = iconItemString(st);
                it["stack_max"] = (int)def.stack_max;
                it["type"] = (int)def.type;
            }
            items.push_back(it);
        }
        lists[String::utf8(list->getName().c_str())] = items;
    }
    return lists;
}

Dictionary GoannaClient::inventory_state() {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    d["version"] = (int)m_session->inventoryVersion();
    d["lists"] = inventoryLists(m_session->inventory(), m_session->getItemDefManager());
    return d;
}

Dictionary GoannaClient::inventory_state_at(const String &location) {
    Dictionary d;
    if (!m_session)
        return d;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    Inventory *inv = m_session->inventoryAt(location.utf8().get_data());
    d["found"] = inv != nullptr;
    d["version"] = (int)(m_session->inventoryVersion() + m_session->detachedVersion());
    d["lists"] = inventoryLists(inv, m_session->getItemDefManager());
    return d;
}

PackedStringArray GoannaClient::detached_inventory_names() {
    PackedStringArray names;
    if (!m_session)
        return names;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    for (auto &kv : m_session->detachedInventories())
        names.push_back(String::utf8(kv.first.c_str()));
    return names;
}

void GoannaClient::respawn() {
    // 5.16 servers show builtin's "__builtin:death" formspec; closing it
    // with quit set is what respawns the player (builtin/game/death_screen.lua).
    if (m_session)
        m_session->sendInventoryFields("__builtin:death", {{"quit", "true"}});
}

Ref<Texture2D> GoannaClient::texture(const String &name) {
    if (!m_session)
        return Ref<Texture2D>();
    u32 id = m_session->tsrc()->getTextureId(name.utf8().get_data());
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(id);
    if (!gt)
        return Ref<Texture2D>();
    return gt->godotTexture();
}

String GoannaClient::item_description(const String &item_string) {
    if (!m_session)
        return String();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    IItemDefManager *idef = m_session->getItemDefManager();
    ItemStack stack;
    stack.deSerialize(item_string.utf8().get_data(), idef);
    if (stack.name.empty())
        return String();
    return String::utf8(stack.getDefinition(idef).description.c_str());
}

Ref<Texture2D> GoannaClient::item_icon(const String &item_name) {
    if (!m_session)
        return Ref<Texture2D>();
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    IItemDefManager *idef = m_session->getItemDefManager();
    // A bare name or a whole item string; the metadata of the latter can
    // carry a colour, which the node item icon below honours.
    ItemStack stack;
    try {
        stack.deSerialize(item_name.utf8().get_data(), idef);
    } catch (std::exception &) {
        return Ref<Texture2D>();
    }
    if (stack.name.empty())
        return Ref<Texture2D>();
    ItemImageDef img = stack.getInventoryImage(idef);
    std::string tex = img.name;
    if (tex.empty()) {
        const ItemDefinition &def = stack.getDefinition(idef);
        if (def.type != ITEM_NODE && !def.inventory_image.name.empty())
            tex = def.inventory_image.name;
    }
    if (tex.empty()) {
        // A node item with no inventory image: drawItemStack draws its item
        // mesh, and so does this, whatever its drawtype. Folding tiles into
        // an [inventorycube read a mesh node's texture atlas as cube faces
        // (Mineclonia's chest came out as a see-through box), took a faced
        // node's side where upstream shows its front, and lost overlay tiles
        // and colours; a plain cube drawn both ways differs too (the mesh is
        // drawn smaller, with its own shading), which is why cubes come this
        // way as well.
        return m_item_icons.icon(*m_session, stack);
    }
    u32 id = m_session->tsrc()->getTextureId(tex);
    GoannaTexture *gt = m_session->tsrc()->goannaTexture(id);
    if (!gt)
        return Ref<Texture2D>();
    return gt->godotTexture();
}

void GoannaClient::flush_item_icons() {
    m_item_icons.flush();
}

Dictionary GoannaClient::item_icon_stats() const {
    return m_item_icons.stats();
}

void GoannaClient::_on_frame_pre_draw() {
    // Size icons for the slot a formspec lays out on this window, then draw
    // whatever was asked for since the last frame, so a form built this
    // frame is drawn complete.
    const auto t0 = std::chrono::steady_clock::now();
    if (is_inside_tree()) {
        Vector2 vs = get_viewport()->get_visible_rect().size;
        m_item_icons.setSize(goanna::itemIconSizeFor(std::min(vs.x, vs.y)));
    }
    m_item_icons.flush();
    m_item_icons.countFrame(std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count());
}

void GoannaClient::_notification(int p_what) {
    RenderingServer *rs = RenderingServer::get_singleton();
    if (!rs)
        return;
    Callable cb = callable_mp(this, &GoannaClient::_on_frame_pre_draw);
    if (p_what == NOTIFICATION_ENTER_TREE) {
        if (!rs->is_connected("frame_pre_draw", cb))
            rs->connect("frame_pre_draw", cb);
    } else if (p_what == NOTIFICATION_EXIT_TREE) {
        if (rs->is_connected("frame_pre_draw", cb))
            rs->disconnect("frame_pre_draw", cb);
    }
}

String GoannaClient::inventory_formspec() const {
    return m_session ? String::utf8(m_session->inventoryFormspec().c_str()) : String();
}

String GoannaClient::formspec_prepend() const {
    return m_session ? String::utf8(m_session->formspecPrepend().c_str()) : String();
}

Array GoannaClient::take_shown_formspecs() {
    Array out;
    if (!m_session)
        return out;
    for (auto &fs : m_session->takeShownFormspecs()) {
        Dictionary d;
        d["formspec"] = String::utf8(fs.formspec.c_str());
        d["formname"] = String::utf8(fs.formname.c_str());
        d["context"] = String::utf8(fs.context.c_str());
        out.push_back(d);
    }
    return out;
}

void GoannaClient::send_nodemeta_fields(const String &context, const String &formname, const Dictionary &fields) {
    if (!m_session)
        return;
    std::string ctx = context.utf8().get_data();
    if (ctx.rfind("nodemeta:", 0) != 0)
        return;
    std::string coords = ctx.substr(9);
    std::replace(coords.begin(), coords.end(), ',', ' ');
    std::istringstream is(coords);
    v3s16 p;
    is >> p.X >> p.Y >> p.Z;
    if (is.fail())
        return;
    std::map<std::string, std::string> f;
    Array keys = fields.keys();
    for (int i = 0; i < keys.size(); ++i)
        f[String(keys[i]).utf8().get_data()] = String(fields[keys[i]]).utf8().get_data();
    m_session->sendNodemetaFields(p, formname.utf8().get_data(), f);
}

void GoannaClient::send_inventory_fields(const String &formname, const Dictionary &fields) {
    if (!m_session)
        return;
    std::map<std::string, std::string> f;
    Array keys = fields.keys();
    for (int i = 0; i < keys.size(); ++i) {
        String k = keys[i];
        String v = fields[keys[i]];
        f[k.utf8().get_data()] = v.utf8().get_data();
    }
    m_session->sendInventoryFields(formname.utf8().get_data(), f);
}

int GoannaClient::wield_index() const {
    return m_session ? m_session->wieldIndex() : 0;
}

void GoannaClient::inventory_action(const String &action) {
    if (m_session)
        m_session->sendInventoryAction(action.utf8().get_data());
}

void GoannaClient::set_wield_index(int index) {
    if (!m_session)
        return;
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    m_session->setWieldIndex((u16)index);
}

Array GoannaClient::take_sounds() {
    Array out;
    if (!m_session)
        return out;
    for (auto &ev : m_session->takeSounds()) {
        Dictionary d;
        d["id"] = (int)ev.server_id;
        d["name"] = String::utf8(ev.name.c_str());
        d["gain"] = ev.gain;
        d["pitch"] = ev.pitch;
        d["loop"] = ev.loop;
        d["positional"] = ev.positional;
        d["position"] = Vector3(ev.pos.X, ev.pos.Y, ev.pos.Z);
        d["object_id"] = (int)ev.object_id;
        d["start_time"] = ev.start_time;
        d["kind"] = String::utf8(ev.kind.c_str());
        out.push_back(d);
    }
    return out;
}

PackedInt32Array GoannaClient::take_stopped_sounds() {
    PackedInt32Array out;
    if (!m_session)
        return out;
    for (s32 id : m_session->takeStoppedSounds())
        out.push_back(id);
    return out;
}

static inline Vector3 gv(const v3f &v) { return Vector3(v.X, v.Y, v.Z); }

Array GoannaClient::take_particle_spawners() {
    Array out;
    if (!m_session)
        return out;
    for (auto &e : m_session->takeParticleSpawners()) {
        Dictionary d;
        d["id"] = (int)e.id;
        d["amount"] = (int)e.amount;
        d["time"] = e.time;
        d["pos_min"] = gv(e.pos_min); d["pos_max"] = gv(e.pos_max);
        d["vel_min"] = gv(e.vel_min); d["vel_max"] = gv(e.vel_max);
        d["acc_min"] = gv(e.acc_min); d["acc_max"] = gv(e.acc_max);
        d["exp_min"] = e.exp_min; d["exp_max"] = e.exp_max;
        d["size_min"] = e.size_min; d["size_max"] = e.size_max;
        d["texture"] = String::utf8(e.texture.c_str());
        d["vertical"] = e.vertical;
        d["collision"] = e.collision;
        d["attached_id"] = (int)e.attached_id;
        d["glow"] = (int)e.glow;
        d["collision_removal"] = e.collision_removal;
        d["object_collision"] = e.object_collision;
        d["blend_mode"] = (int)e.blend_mode;
        d["anim_type"] = e.anim_type;
        d["anim_a"] = e.anim_a;
        d["anim_b"] = e.anim_b;
        d["anim_frame_length"] = e.anim_frame_length;
        d["node_param0"] = (int)e.node_param0;
        d["node_param2"] = (int)e.node_param2;
        d["node_tile"] = (int)e.node_tile;
        d["drag"] = gv(e.drag);
        d["jitter_min"] = gv(e.jitter_min); d["jitter_max"] = gv(e.jitter_max);
        d["bounce_min"] = e.bounce_min; d["bounce_max"] = e.bounce_max;
        d["radius_min"] = gv(e.radius_min); d["radius_max"] = gv(e.radius_max);
        d["attractor_kind"] = (int)e.attractor_kind;
        d["attract_min"] = e.attract_min; d["attract_max"] = e.attract_max;
        d["attractor_origin"] = gv(e.attractor_origin);
        d["attractor_direction"] = gv(e.attractor_direction);
        d["attractor_kill"] = e.attractor_kill;
        // The pool a spawner picks each particle's texture from. One entry is
        // the ordinary case and means the same thing as "texture".
        Array pool;
        for (const auto &t : e.texpool)
            pool.push_back(String::utf8(t.c_str()));
        d["texpool"] = pool;
        out.push_back(d);
    }
    return out;
}

Array GoannaClient::take_dug_nodes() {
    Array out;
    if (!m_session)
        return out;
    for (auto &e : m_session->takeDugNodes()) {
        Dictionary d;
        d["pos"] = gv(e.pos);
        d["normal"] = gv(e.normal);
        d["texture"] = String::utf8(e.texture.c_str());
        d["count"] = e.count;
        d["colour"] = Color(((e.colour >> 16) & 0xff) / 255.0f, ((e.colour >> 8) & 0xff) / 255.0f,
                (e.colour & 0xff) / 255.0f, ((e.colour >> 24) & 0xff) / 255.0f);
        out.push_back(d);
    }
    return out;
}

PackedInt32Array GoannaClient::take_deleted_spawners() {
    PackedInt32Array out;
    if (!m_session)
        return out;
    for (u32 id : m_session->takeDeletedSpawners())
        out.push_back((int)id);
    return out;
}

Array GoannaClient::take_particles() {
    Array out;
    if (!m_session)
        return out;
    for (auto &e : m_session->takeParticles()) {
        Dictionary d;
        d["position"] = gv(e.pos);
        d["velocity"] = gv(e.vel);
        d["acceleration"] = gv(e.acc);
        d["expirationtime"] = e.expirationtime;
        d["size"] = e.size;
        d["texture"] = String::utf8(e.texture.c_str());
        out.push_back(d);
    }
    return out;
}

PackedStringArray GoannaClient::media_names() {
    PackedStringArray out;
    if (!m_session)
        return out;
    for (const auto &n : m_session->mediaNames())
        out.push_back(String::utf8(n.c_str()));
    return out;
}

PackedStringArray GoannaClient::announced_media_names() {
    PackedStringArray out;
    if (!m_session)
        return out;
    for (const auto &n : m_session->announcedMediaNames())
        out.push_back(String::utf8(n.c_str()));
    return out;
}

// NodeMetadataFormSource::resolveText for a node's own form: a whole
// "${key}" becomes that key's value in the node's metadata, which is how an
// MTG sign's field shows the sign's current text. `context` is the form's
// "nodemeta:x,y,z" in Luanti coordinates; any other text or context comes
// back unchanged.
String GoannaClient::resolve_nodemeta_text(const String &context, const String &text) {
    if (!m_session || !context.begins_with("nodemeta:"))
        return text;
    PackedStringArray p = context.substr(9).split(",");
    if (p.size() != 3)
        return text;
    v3s16 np((s16)p[0].to_int(), (s16)p[1].to_int(), (s16)p[2].to_int());
    std::lock_guard<std::mutex> lk(m_session->mapLock());
    NodeMetadata *meta = m_session->map().getNodeMetadata(np);
    if (!meta)
        return text;
    return String::utf8(meta->resolveString(text.utf8().get_data()).c_str());
}

PackedByteArray GoannaClient::media_bytes(const String &name) {
    PackedByteArray out;
    std::string data;
    if (m_session && m_session->mediaBytes(name.utf8().get_data(), data)) {
        out.resize((int64_t)data.size());
        memcpy(out.ptrw(), data.data(), data.size());
    }
    return out;
}

Dictionary GoannaClient::node_sound(const String &node_name, const String &kind) {
    Dictionary d;
    if (!m_session)
        return d;
    std::string sname;
    float gain = 1.0f, pitch = 1.0f;
    if (!m_session->nodeSound(node_name.utf8().get_data(), kind.utf8().get_data(), sname, gain, pitch))
        return d;
    d["name"] = String::utf8(sname.c_str());
    d["gain"] = gain;
    d["pitch"] = pitch;
    return d;
}

} // namespace goanna
