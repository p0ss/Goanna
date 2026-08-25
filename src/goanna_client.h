// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

#include <chrono>
#include <deque>
#include <map>
#include <set>
#include <memory>
#include <vector>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/array_occluder3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/occluder_instance3d.hpp>
#include <godot_cpp/classes/omni_light3d.hpp>
#include <godot_cpp/classes/gpu_particles3d.hpp>
#include <godot_cpp/classes/particle_process_material.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include "goanna_entities.h"
#include "goanna_lod.h"
#include "goanna_mesh_pool.h"
#include "irrlichttypes_bloated.h"
#include <SMaterial.h>

class MapBlock;

namespace goanna {

class GoannaSession;

// Root node of a Goanna session. Owns the transplanted Luanti client and
// feeds what it produces (mapblock meshes, player pose) into the scene.
// What a world material is keyed on: Luanti texture id, Goanna shader id
// (which carries Luanti's material type) and culling.
struct MaterialKey {
    u32 texture_id = 0;
    u32 shader_id = 0;
    bool backface_culling = true;
    bool array_texture = false; // sample a Texture2DArray, layer from UV2.x
    // texture_id already names a generated image (a crack composite), so the
    // array fallback must not overwrite it with the plain layer.
    bool composited = false;
    // A far tier's copy of an array material: the same shader and arrays,
    // with block light added as emission because the node lights do not
    // reach that far. See docs/far-rendering.md.
    bool lod = false;
    uint64_t hash() const {
        // composited is in here because it changes which material is built,
        // and leaving it out put a crack composite and the plain layer in the
        // same cache slot, where whichever was built first won. Bits 18 to 23
        // were free; this takes one of them rather than disturbing the
        // existing layout.
        return ((uint64_t)texture_id << 24) | ((uint64_t)(shader_id & 0xffff) << 2) |
                (composited ? (uint64_t)1 << 18 : 0) | (lod ? (uint64_t)1 << 19 : 0) |
                (backface_culling ? 2 : 0) | (array_texture ? 1 : 0);
    }
};

class GoannaClient : public godot::Node3D {
    GDCLASS(GoannaClient, godot::Node3D)

public:
    GoannaClient();
    ~GoannaClient() override;

    godot::String hello() const;
    godot::String luanti_version() const;

    // A local directory searched, by filename, before anything the server
    // sends: the same "texture_path" override Luanti's own client has had
    // since 2013 (src/transplant/client/imagesource.cpp's
    // SourceImageCache::insert(..., prefer_local=true)), unmodified here,
    // just never previously exposed. A file here with a game texture's own
    // name replaces what the server sent; a same-stem "_n"/"_s" companion
    // alongside it is picked up as LabPBR data by the usual lookup. Must be
    // called before connect_to: texture requests can start as soon as the
    // session does, and this only takes effect for ones made after it runs.
    // Per channel scaling of a LabPBR pack's decoded material data: "normal",
    // "ao", "roughness", "specular", "emission", "sss". A pack is authored for
    // another renderer and another art style, so its channels often arrive too
    // strong for the game being dressed. Applied live to every material
    // already built, so a slider shows its effect at once.
    void set_material_strength(const godot::String &channel, float value);
    float material_strength(const godot::String &channel) const;
    // A game_texture,pack_path CSV, so set_texture_path may point at an
    // unmodified Minecraft resource pack. Set before connect_to.
    // What a paired server mod said this server permits, empty against a
    // server without it. See goanna_server_mod/.
    godot::Dictionary server_options() const;
    // Draw nodes that use a liquid drawtype without being one as opaque. See
    // set_solid_ice in the implementation for the trade it makes.
    void set_shadow_lamps(int n);
    int shadow_lamps() const { return m_shadow_lamps; }
    void set_solid_ice(bool on);
    bool solid_ice() const;
    void set_texture_map(const godot::String &csv);
    void set_texture_path(const godot::String &path);
    godot::String texture_path() const;

    void connect_to(const godot::String &host, int port, const godot::String &player_name,
            const godot::String &password);
    void disconnect_from_server();
    godot::Dictionary status() const;

    // Mesh up to max_blocks newly received blocks into regional near meshes.
    // Returns how many were processed.
    int poll_blocks(int max_blocks);
    int block_mesh_count() const { return (int)m_near_blocks.size(); }
    int material_count() const { return (int)m_materials.size(); }

    // Camera/player pose in Godot space; reported to the server so it
    // streams blocks around us. Position in nodes.
    void set_player_pose(const godot::Vector3 &pos, float pitch_deg, float yaw_deg);
    // Initial player position from the server, in Godot space (nodes).
    godot::Vector3 server_player_position() const;

    // Advance the local player by dt using Luanti's own movement code.
    // keys: {up,down,left,right,jump,sneak,aux1}; pitch/yaw in Godot degrees
    // (pitch positive = looking up). Returns {eye_pos, pos, pitch, yaw,
    // on_ground, in_liquid} in Godot space (nodes).
    // Digging/placing: call once per frame with button state. Returns
    // {type: "nothing"|"node"|"object", node, above, object_id, progress}.
    godot::Dictionary step_interact(double dt, bool dig, bool place, bool place_pressed, bool sneak = false);
    // Fields of a node's own formspec, for a "nodemeta:x,y,z" context.
    void send_nodemeta_fields(const godot::String &context, const godot::String &formname, const godot::Dictionary &fields);
    void set_wield_index(int index);
    int wield_index() const;
    // Raw Luanti inventory action string, e.g. "Move 1 current_player main 3 current_player main 5".
    void inventory_action(const godot::String &action);

    // Step and draw active objects (players, mobs, items).
    void sync_entities(double dt);
    int entity_count() const { return m_entities ? m_entities->count() : 0; }
    godot::Array entity_positions() const { return m_entities ? m_entities->positions() : godot::Array(); }
    godot::Array entity_list();
    // Frame-time telemetry: where the client's own time goes, and what the
    // renderer is being asked to draw. Milliseconds are exponential moving
    // averages so the numbers are readable rather than jittering per frame.
    godot::Dictionary render_stats();
    // First-person body (the local player's own model, head shrunk away).
    void set_show_body(bool show);
    // First-person arm swing phase (0..1), driven from the input side.
    void set_arm_swing(float s);
    bool show_body() const { return m_show_body; }
    // Currently wielded item: its name (cheap; poll for changes), and its
    // wield mesh as {name, mesh: ArrayMesh or null, scale: Vector3}.
    godot::String wield_item_name();
    int wield_light();
    godot::Dictionary wield_info();
    // Mesh for an arbitrary item name: {name, mesh: ArrayMesh or null,
    // scale: Vector3}, for rendering 3D inventory icons. Node items get their
    // real node mesh (stairs, slabs, torches), so this is not cube-only.
    // Unlike wield_info this ignores wield_image, which is the wielded
    // override rather than the inventory representation.
    godot::Dictionary item_mesh(const godot::String &item_name);

    // Point lights for light-emitting nodes: keeps up to max_lights OmniLight3Ds
    // on the nearest bright nodes to `around` (Godot space, nodes).
    void update_lights(const godot::Vector3 &around, int max_lights);
    // Ambient motes: pooled particle emitters that follow nearby leaf, flora
    // and sand/gravel nodes, coloured from the node's texels. density scales
    // the count and per-emitter amount (0 = off). update_motes drives the pool.
    void set_motes(float density);
    float motes() const { return m_motes; }
    void update_motes(const godot::Vector3 &around, int max_emitters);

    // --- in-game data for the UI layer ---
    // Chat lines received since last call: [{type, sender, message}].
    godot::Array take_chat();
    void send_chat(const godot::String &message);
    int hp() const;
    int breath() const;
    // HUD elements: [{id, type, pos, name, scale, text, number, item, dir, align,
    // offset, world_pos, size, z_index, text2, style}], plus flags/hotbar info.
    godot::Dictionary hud_state() const;
    // Player inventory: {version, lists: {name: [{name, count, wear, description,
    // inventory_image, stack_max}]}}. Empty item names are empty slots.
    godot::Dictionary inventory_state();
    // Inventory at "current_player", "detached:<name>" or "nodemeta:x,y,z":
    // {found, version, lists}. version changes when detached inventories or
    // node metadata change, so callers can poll cheaply.
    godot::Dictionary inventory_state_at(const godot::String &location);
    godot::PackedStringArray detached_inventory_names();
    // Answer the death screen (builtin's "__builtin:death" formspec).
    void respawn();
    // Texture (ImageTexture) for a Luanti texture string (item icons, HUD images);
    // null if unavailable. Goes through the texture-modifier DSL.
    godot::Ref<godot::Texture2D> texture(const godot::String &name);
    // Inventory icon for an item name: its inventory_image texture if it has
    // one (tools, most items), else the item's own texture; null if unknown.
    // Node items without an inventory image return null (the UI keeps its
    // coloured-tile placeholder; a rendered node icon needs an offscreen pass).
    godot::Ref<godot::Texture2D> item_icon(const godot::String &item_name);
    // Formspecs
    godot::String inventory_formspec() const;
    godot::Array take_shown_formspecs(); // [{formspec, formname}]
    void send_inventory_fields(const godot::String &formname, const godot::Dictionary &fields);

    // --- sound ---
    // Sounds the server asked for since the last call:
    // [{id, name, gain, pitch, loop, positional, position, object_id, start_time}].
    godot::Array take_sounds();
    godot::PackedInt32Array take_stopped_sounds();
    godot::PackedStringArray media_names();
    // Particle spawners the server asked for since the last call, the ids
    // it cancelled, and one-shot particles.
    godot::Array take_particle_spawners();
    godot::Array take_dug_nodes();
    godot::PackedInt32Array take_deleted_spawners();
    godot::Array take_particles();
    // Name of the node at a Godot-space position, "" if unknown.
    godot::String node_name_at(const godot::Vector3 &pos);
    // Raw bytes of a received media file (an .ogg for sounds), empty if absent.
    godot::PackedByteArray media_bytes(const godot::String &name);
    // A node's own sound: kind is "footstep", "dig" or "dug".
    // Returns {name, gain, pitch} or an empty dictionary.
    godot::Dictionary node_sound(const godot::String &node_name, const godot::String &kind);

    // Sky/sun/fog/lighting state from the server, in Godot terms (see goanna_sky.h).
    godot::Dictionary sky_state() const;
    void set_time_of_day_override(float tod);
    // True if the given eye position (Godot space, nodes) is inside a liquid
    // node; for underwater fog/tint. Cheap map lookup.
    bool is_underwater(const godot::Vector3 &eye);
    bool isUnderwaterAt(const godot::Vector3 &eye);
    // Auto-bump strength: normal maps derived from diffuse luminance. 0 = off.
    // Rebuilds world materials so the change takes effect immediately.
    // Block edge bevel width as a fraction of a node (0 = off). Re-meshes.
    void set_bevel(float width);
    float bevel() const;
    void set_auto_bump(float strength);
    float auto_bump() const { return m_auto_bump; }
    // How far to ask the server to stream, in mapblocks, and the camera
    // FOV reported with our position (both affect what the server sends).
    // Drop blocks further than this many mapblocks from the player (and
    // tell the server), so a long session does not grow without bound.
    // Returns how many were dropped.
    int prune_blocks(int radius);
    int resident_blocks();
    // Distance in mapblocks past which blocks are drawn coarsely: merged
    // cells on the node array shader, in per region meshes, one tier per
    // doubling of distance (docs/far-rendering.md rungs 2 and 3). 0 disables.
    // update_lod re-meshes blocks whose tier changed as the player moves,
    // bounded per call so it cannot stall a frame. lod_cell is the cell size
    // of the first tier in nodes, a power of two from 2 to 16; each further
    // tier doubles it.
    void set_lod_distance(int blocks);
    int lod_distance() const { return m_lod_distance; }
    void set_lod_cell(int nodes);
    int lod_cell() const { return m_lod_cell; }
    void set_lod_terrace(bool on);
    bool lod_terrace() const { return m_lod_terrace; }
    // How many threads mesh the far field. 0 means pick from the hardware,
    // which is what the pool does when it is started without a number; -1
    // means mesh on the main thread, the comparison to make when a far field
    // fault looks like a threading one. Takes effect immediately: the pool is
    // stopped and restarted, and every region is captured again.
    void set_mesh_threads(int threads);
    int mesh_threads() const { return m_mesh_threads; }
    int update_lod(const godot::Vector3 &around, int max_rebuild);
    // The local block store (docs/far-rendering.md rung 5). The root
    // directory; each server gets its own subdirectory beneath it. Empty
    // turns the store off. Set before connect_to. Blocks are written as they
    // arrive; they are drawn beyond the server's range only when the server
    // grants far rendering over the goanna:v1 channel, and then out to the
    // lesser of the grant and far_distance (nodes).
    void set_store_path(const godot::String &root);
    godot::String store_path() const { return m_store_root; }
    void set_far_distance(int nodes);
    int far_distance() const { return m_far_distance; }
    void set_view_range(int blocks);
    int view_range() const;
    void set_view_fov(float degrees);
    // Mantle over single-block ledges (Luanti's autojump). On by default.
    void set_mantle(bool on) { m_mantle = on; }
    bool mantle() const { return m_mantle; }
    // Movement option flags, applied to the local player's PlayerSettings each
    // step (the transplanted movement code reads them).
    void set_aux1_descends(bool on) { m_aux1_descends = on; }
    bool aux1_descends() const { return m_aux1_descends; }
    void set_pitch_move(bool on) { m_pitch_move = on; }
    bool pitch_move() const { return m_pitch_move; }
    void set_always_fly_fast(bool on) { m_always_fly_fast = on; }
    bool always_fly_fast() const { return m_always_fly_fast; }
    // Interaction options (forwarded to the session, read in stepInteract).
    void set_safe_dig(bool on);
    bool safe_dig() const;
    void set_repeat_dig_interval(float s);
    float repeat_dig_interval() const;
    void set_repeat_place_interval(float s);
    float repeat_place_interval() const;

    godot::Dictionary step_player(double dt, const godot::Dictionary &keys, float pitch_deg, float yaw_deg);

    // World materials (shared by mapblocks and item entities): by key, or
    // straight from a Luanti SMaterial as the mesher leaves it.
    godot::Ref<godot::Material> materialFor(const MaterialKey &key);
    godot::Ref<godot::Material> materialForIrr(const video::SMaterial &m, u16 layer = 0);
    MaterialKey keyForIrr(const video::SMaterial &m, u16 layer);
    // live: the server is sending this block, so inside the wanted range it
    // is never coarsened. A block from the store or a summary is tiered by
    // the detail distance alone.
    int lodTierFor(const v3s16 &bp, const godot::Vector3 &around, bool live) const;

protected:
    static void _bind_methods();

private:
    void harvestLights(v3s16 bp, MapBlock *block);
    void harvestMotes(v3s16 bp, MapBlock *block);
    void ensureMoteMaterials();

    std::unique_ptr<GoannaSession> m_session;
    godot::String m_texture_path; // see set_texture_path
    godot::String m_texture_map;  // see set_texture_map
    // Exact tier-0 geometry is cached per block on the CPU, then compatible
    // array-material surfaces are combined into one GPU mesh per 4-cubed
    // region. Water and other order-sensitive special shaders remain in a
    // per-block node. One GPU instance per ordinary mapblock produced 4,000
    // to 15,000 draw calls in measured play, even when most were hidden by a
    // cave wall.
    struct NearSurface {
        MaterialKey key;
        godot::PackedVector3Array verts, norms;
        godot::PackedVector2Array uvs, uv2s;
        godot::PackedColorArray cols;
        godot::PackedByteArray custom0;
        godot::PackedInt32Array idx;
        bool glow = false;
    };
    struct NearBlock {
        std::vector<NearSurface> surfaces;
        godot::MeshInstance3D *special_node = nullptr;
        int source_surfaces = 0;
    };
    struct NearRegion {
        godot::MeshInstance3D *node = nullptr;
        godot::MeshInstance3D *glow_node = nullptr;
        godot::OccluderInstance3D *occluder_node = nullptr;
        std::set<v3s16> members;
        bool dirty = false;
        std::chrono::steady_clock::time_point dirty_at;
        int surfaces = 0, occluder_triangles = 0;
    };
    static constexpr int kNearRegionBlocks = 4;
    std::map<v3s16, NearBlock> m_near_blocks;
    std::map<v3s16, NearRegion> m_near_regions;
    std::map<v3s16, v3s16> m_near_member;
    v3s16 nearRegionFor(const v3s16 &bp) const;
    bool nearCanBatch(const MaterialKey &key) const;
    bool nearCanOcclude(const MaterialKey &key) const;
    void nearMarkDirty(NearRegion &region);
    void nearAssign(const v3s16 &bp);
    void nearDrop(const v3s16 &bp);
    void nearBuildRegion(const v3s16 &key, NearRegion &region);
    void nearRebuild(double budget_ms);
    void nearClear();
    double m_ms_near_batch = 0;
    int m_near_regions_built_last = 0;
    std::map<v3s16, int> m_block_tier; // 0 = full detail, 1 and up = LOD tiers
    godot::Ref<godot::StandardMaterial3D> m_lod_material; // flat colour fallback
    std::map<u32, godot::Ref<godot::Material>> m_lod_water; // water shader per liquid tile
    godot::Vector3 m_lod_centre; // last camera position seen by update_lod
    // Existing blocks only need their distance tier reconsidered after the
    // camera crosses a mapblock boundary (or a setting changes). New blocks
    // are assigned against m_lod_centre as they arrive. Walking the complete
    // retained far-summary map while standing still made frame cost grow with
    // terrain knowledge rather than with anything being drawn.
    v3s16 m_lod_retier_centre{32767, 32767, 32767};
    bool m_lod_retier_pending = true;
    // Snapshot of retained blocks still to reconsider after the camera moves.
    // The old loop restarted at map.begin() after each eight changes, turning
    // a linear scan into repeated O(n) work while terrain streamed.
    std::deque<v3s16> m_lod_retier_queue;
    // Distance scale, in blocks, at which coarse cell sizes begin doubling.
    // Resident blocks are always full detail; a non-resident block starts at
    // the finest coarse tier even inside this distance, so server delivery
    // holes cannot become a circular trench. Everything far gates on this
    // being above zero; 0 turns it off. docs/launch-target.md.
    int m_lod_distance = 12;
    int m_lod_cell = 4;
    // The smoothed surface reads as melted terrain wherever the far field
    // meets a cliff or a coastline (docs/far-rendering.md, "Terraces or
    // slopes" and "Stop the far surface averaging across cliffs"), and it
    // is a Minecraft world underneath either way, so the honest default is
    // the one that looks like the blocks actually there.
    bool m_lod_terrace = true;
    // --- far rendering (docs/far-rendering.md rungs 2 and 3) ---
    // Blocks at a tier of 1 or more are not meshed one by one: each belongs
    // to a region at its tier, and the region is one mesh built from the
    // blocks' coarse chains (goanna_lod.h). A region is rebuilt when any of
    // its members, or a block next to one, changes.
    struct LodRegionKey {
        int tier = 0;
        v3s16 pos; // in units of lodRegionBlocks(tier)
        bool operator<(const LodRegionKey &o) const {
            return tier != o.tier ? tier < o.tier : pos < o.pos;
        }
        bool operator==(const LodRegionKey &o) const { return tier == o.tier && pos == o.pos; }
        bool operator!=(const LodRegionKey &o) const { return !(*this == o); }
    };
    struct LodRegion {
        godot::MeshInstance3D *node = nullptr;
        std::set<v3s16> members;
        bool dirty = false;
        std::chrono::steady_clock::time_point dirty_at;
        int faces = 0, quads = 0, surfaces = 0, partial = 0;
        // Atomic publication. The node above keeps drawing the last mesh
        // that finished while a worker builds the next, so a region is never
        // half meshed on screen and a tier hand-off never shows a hole.
        // `generation` stamps each capture: a result arriving with an older
        // stamp was overtaken while it was building and is dropped.
        uint64_t generation = 0;
        bool building = false;
    };
    std::map<LodRegionKey, LodRegion> m_lod_regions;
    std::map<v3s16, LodRegionKey> m_lod_member; // which region draws a block
    // Built lazily, dropped when the block changes. Shared and immutable
    // once published, so a mesh worker can hold the chains its region needs
    // while the main thread erases and rebuilds others: replacing a chain
    // means erasing the entry and building a new one, never writing through
    // one that is already in the map. See goanna_mesh_pool.h.
    std::map<v3s16, std::shared_ptr<const BlockLodChain>> m_lod_chains;
    // Chains are built a few per poll inside a time budget, never inside a
    // region build: a coarse region touches thousands of blocks, and building
    // their chains in one poll was the frame stall of the first version. A
    // region builds with the chains that exist and is dirtied again as the
    // rest arrive, so terrain fills in progressively.
    std::deque<v3s16> m_lod_chain_queue;
    std::set<v3s16> m_lod_chain_queued;
    std::map<v3s16, std::set<LodRegionKey>> m_lod_chain_waiters;
    // Exact near meshes retained across prune until their asynchronously
    // derived far region has actually been uploaded (atomic handoff).
    std::set<v3s16> m_lod_handoff_near;
    // Blocks that have no chain source, neither live nor stored: asked for
    // once and not again until something arrives for them, or a region that
    // touches one rebuilds every quarter second for nothing.
    std::set<v3s16> m_lod_chain_missing;
    void lodEnqueueChain(const v3s16 &bp);
    LodTileCache m_lod_tiles;
    // Mesh workers. Far regions are captured on this thread, meshed on those,
    // and published back here. Started with the client and stopped before the
    // session goes, because a job holds the session's node definitions,
    // texture source and material table.
    MeshPool m_mesh_pool;
    // The requested worker count, which is not the running one: 0 asks the
    // pool to choose. MeshPool::stats() reports what it actually started.
    int m_mesh_threads = 0;
    // How many finished regions to publish per poll. Uploading an ArrayMesh
    // is main thread work no matter who meshed it, so a backlog is spread
    // rather than spent at once.
    int m_lod_publish_budget = 4;
    double m_ms_lod = 0; // EMA of one region build
    double m_ms_lod_update = 0; // complete update_lod call, including lock wait
    double m_ms_lod_tier_scan = 0;
    double m_ms_lod_summaries = 0;
    double m_ms_lod_requests = 0;
    double m_ms_lod_far_scan = 0;
    double m_ms_lod_chain = 0; // EMA of one lazily derived exact hierarchy
    int m_lod_chains_built_last = 0;
    double m_ms_stats = 0;
    int m_lod_last_built = 0;
    double m_ms_poll_max = 0, m_ms_poll_max_last = 0; // worst poll_blocks call, per second
    double m_ms_poll_lock = 0, m_ms_poll_queue = 0, m_ms_poll_blocks = 0;
    double m_ms_poll_near = 0, m_ms_poll_lod = 0;
    std::chrono::steady_clock::time_point m_poll_window;
    // Blocks drawn from the store rather than received: they sit in
    // m_block_tier like any other, flagged here so a tier change is applied
    // directly (there is no live block to requeue) and so they can be let go
    // when they pass out of range.
    godot::String m_store_root;
    // Default is the grant, not a fixed number: lodUpdateFar raises this to
    // match farRenderingGrant() the first time one is seen, so a fresh
    // install draws out to whatever the server actually allowed rather than
    // to half of it. set_far_distance (an explicit env var or settings panel
    // choice) turns that off, docs/launch-target.md task 2d.
    int m_far_distance = 512;
    // Nodes: how far the far field actually reaches around the player, the
    // ninetieth percentile ring of what is drawn, recomputed on each far
    // rescan. What the haze closes at, so the world is never seen ending in
    // clear air. 0 when nothing far is drawn at all.
    //
    // Two numbers, because one cannot describe a ragged frontier. The extent
    // is the lower quartile across the eight sectors, how far a poor
    // direction reaches; the reach is the upper quartile, how far a good one
    // does. A depth fog takes a begin and an end, so it can have both: the
    // haze starts where the sparse directions run out and closes where the
    // rich ones do, instead of flattening real terrain to sky colour because
    // some other bearing is empty (docs/far-rendering.md, "Haze over the
    // ragged frontier").
    int m_far_extent = 0;
    int m_far_reach = 0;
    // The full camera cone reported by main.gd. It may be set before a
    // GoannaSession exists, so retain it across connection and reconnection.
    float m_view_fov = 70.0f;
    bool m_far_distance_explicit = false;
    std::set<v3s16> m_far_blocks;
    // Blocks whose chain came from a server far summary rather than the
    // store. This also retains summaries currently inside the near-field
    // floor, so moving away can assign them without requesting the area again.
    std::set<v3s16> m_far_remote;
    // Area origins (block coords, 8 block aligned) already asked of the
    // server, so a slow answer is not asked for again every scan.
    // Areas whose summary has been asked for, and what came back. A server
    // answers from terrain it has already generated and reports the rest as
    // ungenerated, so an area asked while it was half made stays half made
    // for the whole session unless it is asked again: that is why distant
    // patches never filled in. `complete` is set when every record in the
    // reply was generated; anything less is retried once the delay below has
    // passed, and `asked` is when it last went out.
    struct FarAsk {
        std::chrono::steady_clock::time_point asked;
        bool complete = false;
        // Progress in the most recent answer. A partly generated area can
        // take many seconds to finish; retrying it at a fixed high rate used
        // all four request slots and starved never-seen areas at the moving
        // frontier. Consecutive answers with no progress back off, while a
        // newly completed slice makes the area responsive again.
        uint16_t available_records = 0;
        uint16_t complete_records = 0;
        uint8_t stalled_replies = 0;
        // A reply for this area has been read, so the two flags below mean
        // something. They are what decides whether the layer above or below
        // is worth asking for at all, rather than a fixed window of layers
        // (docs/far-rendering.md, "Lids, layers and the vertical walk").
        bool answered = false;
        // Terrain reaches the top face of this area, so it may carry on into
        // the layer above.
        bool open_above = false;
        // Some column is air at the bottom face of this area, so whatever is
        // in the layer below could be seen. False for a layer that is solid
        // along its floor, which is the whole of the ground under a normal
        // landscape: nothing there is ever visible, and asking for it cost
        // one request in nine and half a million buried cells.
        bool open_below = false;
        // Nothing in the area was generated at all. The walk below must not
        // treat that as a reason to look further down: a layer the server
        // has never made says nothing about the layer under it, and taking
        // it as an invitation walked the request queue straight out of the
        // bottom of the world (docs/far-rendering.md, "Where the summary
        // budget actually went").
        bool empty = false;
        // Every generated record in the reply was air from top to bottom: the
        // area is sky the server has made. A layer like that costs nothing to
        // walk through when the request loop ranks areas, so the ground under
        // a flying player ranks as though the player stood on it rather than
        // behind every area of sky around them.
        bool air = false;
    };
    std::map<v3s16, FarAsk> m_far_requested;
    int m_far_inflight = 0;
    std::chrono::steady_clock::time_point m_far_asked; // when the oldest in flight was sent
    std::chrono::steady_clock::time_point m_far_scan; // when lodRequestSummaries last looked
    v3s16 m_far_centre{32767, 32767, 32767};
    int m_far_radius = 0; // blocks, what lodUpdateFar last scanned with
    std::chrono::steady_clock::time_point m_far_last;
    bool m_far_dirty = true;
    void lodUpdateFar(const godot::Vector3 &around);
    void lodRequestSummaries(const v3s16 &centre, int radius);
    void lodTakeSummaries(const godot::Vector3 &around);
    int lodTierCount() const;
    int lodCellFor(int tier) const;
    int lodRegionBlocks(int tier) const;
    LodRegionKey lodRegionFor(int tier, const v3s16 &bp) const;
    // All of these are called with the session's mapLock() held.
    const BlockLodChain *lodChain(v3s16 bp);
    void lodMarkDirty(const LodRegionKey &key);
    void lodDirtyAround(const v3s16 &bp, const LodRegionKey *except);
    void lodAssign(const v3s16 &bp, int tier);
    void lodForget(const v3s16 &bp);
    void lodBuildRegion(const LodRegionKey &key, LodRegion &r);
    // Capture what a worker needs to mesh this region, main thread. Uses the
    // same lookups the synchronous path does, side effects included, so a
    // chain that is missing is still asked for here.
    void lodCaptureRegion(const LodRegionKey &key, const LodRegionSpec &exact,
            const LodRegionSpec &coarse, LodRegionSnapshot &out);
    // Turn a finished LodRegionMesh into the region's ArrayMesh and put it on
    // screen. Main thread, whether the mesh came from a worker or was built
    // inline because the pool is not running.
    void lodPublishRegion(const LodRegionKey &key, LodRegion &r, const LodRegionMesh &lm,
            std::chrono::steady_clock::time_point t0, int exact_cell, int coarse_cell);
    // Collect whatever the mesh workers have finished. Main thread, once a
    // poll, bounded so a large backlog is spread over frames rather than
    // spent in one.
    void lodCollectMeshes();
    void lodRebuild(double budget_ms);
    void lodReset();
    std::map<uint64_t, godot::Ref<godot::Material>> m_materials;
    std::map<std::string, float> m_mat_strength; // see set_material_strength
    // Texture ids belonging to nodes drawn as a liquid that are not one. See
    // buildFakeLiquidTextures.
    std::set<u32> m_fake_liquid_tex;
    // Lights that currently cast shadows, kept between frames so the set does
    // not churn as their distance order changes. See update_lights.
    std::set<int64_t> m_light_shadowed;
    bool m_fake_liquid_built = false;
    bool m_solid_ice = false;
    void buildFakeLiquidTextures();

    godot::Ref<godot::Shader> m_sh_water, m_sh_leaves, m_sh_plants, m_sh_glass, m_sh_array,
            m_sh_array_scissor;
    bool m_shaders_loaded = false;
    float m_auto_bump = 0.35f;
    bool m_show_body = true;
    // telemetry (EMA in milliseconds, plus last-frame counters)
    double m_ms_mesh = 0, m_ms_upload = 0, m_ms_lights = 0, m_ms_motes = 0, m_ms_entities = 0;
    int m_last_meshed = 0, m_last_queue = 0;
    float m_arm_swing = 0.0f;
    bool m_mantle = true;
    bool m_aux1_descends = false;
    bool m_pitch_move = false;
    bool m_always_fly_fast = false;

    std::unique_ptr<EntityRenderer> m_entities;
    struct NodeLight { godot::Vector3 pos; float level; godot::Color color; };
    std::map<v3s16, std::vector<NodeLight>> m_block_lights;
    std::vector<godot::OmniLight3D *> m_light_pool;
    // Which light currently owns each pool slot, so a lamp keeps the same
    // OmniLight3D between frames instead of being reshuffled by rank. The
    // parameters are copied rather than pointed at, because a slot goes on
    // fading out after its lamp has left the candidate set.
    struct LightSlot {
        int64_t key = 0;
        godot::Vector3 pos;
        godot::Color color;
        float level = 0.0f;
        float fade = 0.0f;
    };
    std::vector<LightSlot> m_light_slot;
    // How many node lights may cast a shadow at once. An omni shadow is a cube
    // map, so this is the expensive knob, but too low a budget is visible:
    // a lantern is a solid node and occludes its own upward light, so one that
    // loses its shadow lights the eave directly above it through itself.
    int m_shadow_lamps = 16;
    int m_lights_in_range = 0;
    // Slots whose lamp changed on the last update: the churn that makes
    // lighting step as the player walks.
    int m_light_churn = 0;
    // kind: 0 = leaves (drift down), 1 = flora/pollen, 2 = sand/gravel dust
    struct MoteNode { godot::Vector3 pos; int kind; godot::Color color; };
    std::map<v3s16, std::vector<MoteNode>> m_block_motes;
    struct MoteEmitter { godot::GPUParticles3D *node = nullptr; godot::Vector3 at; int kind = -1; };
    std::vector<MoteEmitter> m_mote_pool;
    godot::Ref<godot::ParticleProcessMaterial> m_mote_proc[3];
    float m_motes = 0.5f;
};

} // namespace goanna
