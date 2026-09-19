// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#pragma once

// Inventory icons for node items that have no inventory image. Luanti's
// client draws such an item as its 3D item mesh in the slot (drawItemStack
// in luanti/src/gui/drawItemStack.cpp), not as a cube folded out of its
// tiles, so a chest shows its model and a stair its steps. This cache asks
// upstream's ItemVisualsManager for that mesh, draws it with
// goanna_icon_raster, and hands out one ImageTexture per icon.
//
// icon() returns a texture at once and queues the drawing; flush() draws
// everything queued, on several threads when there is a lot of it. The
// client calls flush() from RenderingServer's frame_pre_draw, so a formspec
// that asks for hundreds of icons while it is being built has every one of
// them before its first frame is drawn, and no request draws twice.
//
// Icons are drawn at one pixel size, the slot size a formspec uses on this
// window, and redrawn in place when that changes, so the textures already
// handed out stay valid and sharp. Smaller uses (the hotbar, a form too big
// for the window) scale them down, unfiltered.

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "goanna_icon_raster.h"

struct ItemStack;
class Client;
class WieldMesh;

namespace goanna {

class GoannaSession;
class GoannaShaderSource;

// What distinguishes one node item icon from another, if this stack is one
// upstream draws as its item mesh (a node item with no inventory image,
// whose visuals are built). False for anything else. Main thread, with the
// session's mapLock() held, as for everything that reads definitions. Both
// this and buildItemIconJob reach ItemVisualsManager, which builds the item
// mesh on first sight of an item and needs upstream's extrusion mesh cache
// for it, that is a live WieldMesh.
bool itemIconKey(Client *client, const ItemStack &stack, std::string &key);

// The draw of that icon: upstream's item mesh from ItemVisualsManager, with
// drawItemStack's colours and each buffer's material resolved. False if
// there is no mesh. Same thread, lock and WieldMesh as itemIconKey.
bool buildItemIconJob(Client *client, GoannaShaderSource &shsrc, const ItemStack &stack,
        IconJob &job);

class ItemIconCache {
public:
    ItemIconCache();
    ~ItemIconCache();

    // The icon of a node item that upstream draws as its item mesh, that is
    // one with no inventory image. Null for anything else, and for a node
    // whose visuals have not been built yet (media still arriving), so the
    // caller can fall back and ask again later. Caller holds mapLock().
    godot::Ref<godot::Texture2D> icon(GoannaSession &session, const ItemStack &stack);

    // Draws everything queued. Main thread; the caller need not hold
    // mapLock(), since the jobs only read meshes and images the session
    // never changes once built.
    void flush();

    // The pixel size of an icon. A change redraws every icon already handed
    // out, at the next flush.
    void setSize(u32 px);
    u32 size() const { return m_size; }

    // Forget everything: the jobs point into the session's item meshes and
    // texture images, so this must run before a session is destroyed.
    void clear();

    // Counters for measuring the cost: icons drawn, and milliseconds spent
    // building jobs (in icon()), rasterising and uploading (in flush()), and
    // in the per-frame hook as a whole (see countFrame).
    godot::Dictionary stats() const;
    // The client's frame_pre_draw hook reports what it spent, sizing and
    // flushing included, so the steady cost per frame can be read off.
    void countFrame(double ms) {
        m_frames++;
        m_frame_ms += ms;
    }

private:
    struct Entry {
        IconJob job;
        godot::Ref<godot::ImageTexture> texture;
        u32 texture_size = 0; // the size of the image the texture holds
    };
    std::unordered_map<std::string, std::unique_ptr<Entry>> m_entries;
    std::vector<Entry *> m_pending;
    // createItemMesh needs upstream's extrusion mesh cache, which exists only
    // while some WieldMesh does; this one keeps it alive.
    std::unique_ptr<WieldMesh> m_extrusion_holder;
    u32 m_size = 64;

    uint64_t m_drawn = 0;
    uint64_t m_flushes = 0;
    uint64_t m_frames = 0;
    double m_frame_ms = 0;
    double m_build_ms = 0, m_raster_ms = 0, m_upload_ms = 0, m_last_flush_ms = 0;
    u32 m_last_flush_count = 0;
};

// The icon size for a window whose shorter side is this long: the slot size
// a formspec lays out there when it fits (a fifteenth of the shorter side
// less the default 5% padding at each edge), kept between 32 and 256.
u32 itemIconSizeFor(float window_short_side);

} // namespace goanna
