// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

#include "goanna_item_icons.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include "client/item_visuals_manager.h"
#include "goanna_luanti_client.h"
#include "goanna_mesh_flags.h"
#include "goanna_session.h"
#include "goanna_textures.h"
#include "inventory.h"
#include "itemdef.h"
#include "nodedef.h"
#include "transplant/client/wieldmesh.h"
#include <IMesh.h>
#include <IMeshBuffer.h>

using namespace godot;

// Declared in goanna_mesh_flags.h; Goanna's own state, so defined here rather
// than in the transplanted mesher.
thread_local bool g_goanna_plain_solids = false;

namespace goanna {

namespace {

using Clock = std::chrono::steady_clock;

double msSince(Clock::time_point t) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

// The images a material's texture samples: its own image, or every layer of
// an array texture, which the vertex Aux indexes as the inventory shader's
// varTexLayer does.
std::vector<const video::IImage *> textureImages(video::ITexture *t) {
    std::vector<const video::IImage *> out;
    auto *gt = dynamic_cast<GoannaTexture *>(t);
    if (!gt)
        return out;
    if (gt->isArray()) {
        for (u32 i = 0; i < gt->layerCount(); ++i)
            out.push_back(gt->layerImage(i));
    } else if (gt->image()) {
        out.push_back(gt->image());
    }
    return out;
}

// How the inventory shader draws a buffer, from the base material its shader
// was registered with. getAdHocNodeShader chose that shader from the node's
// alpha mode and the buffer's layer; extruded meshes that skip it keep
// getExtrudedMesh's EMT_TRANSPARENT_ALPHA_CHANNEL_REF.
IconBlend blendFor(GoannaShaderSource &shsrc, video::E_MATERIAL_TYPE mt) {
    video::E_MATERIAL_TYPE base = mt;
    if (GoannaShaderSource::isShaderMaterial(mt))
        base = shsrc.baseMaterial(GoannaShaderSource::shaderIdFromMaterial(mt));
    switch (base) {
    case video::EMT_TRANSPARENT_ALPHA_CHANNEL:
        return IconBlend::AlphaBlend;
    case video::EMT_TRANSPARENT_ALPHA_CHANNEL_REF:
        return IconBlend::AlphaRef;
    default:
        return IconBlend::Opaque;
    }
}

} // namespace

u32 itemIconSizeFor(float short_side) {
    // The slot size project/ui/formspec.gd lays out whenever a form fits the
    // window, which is the usual case: a fifteenth of the shorter side less
    // the default 5% padding at each edge, floored, in doubles as it does it.
    // (GUIFormSpecMenu::calculateImgsize has the same rule, worked in
    // integers and floored at 0.5555 inch, so the two can be a pixel apart.)
    // Vanilla rasterises the item mesh at exactly the slot's size, so drawing
    // at this one puts Goanna's list slots at one icon pixel per screen pixel.
    const double px = std::floor((double)short_side * (1.0 - 0.05 * 2.0) / 15.0);
    return (u32)std::clamp(px, 32.0, 256.0);
}

bool itemIconKey(Client *client, const ItemStack &stack, std::string &key) {
    IItemDefManager *idef = client->idef();
    const ItemDefinition &def = stack.getDefinition(idef);
    // drawItemStack draws the mesh only when there is no inventory image
    // (inventory_items_animations, off by default, would add the rest).
    if (def.type != ITEM_NODE || !stack.getInventoryImage(idef).name.empty())
        return false;
    if (!client->ndef()->get(def.name).visuals)
        return false;
    // What changes the picture: the item (its mesh, tiles and tile colours),
    // an overlay from its definition or metadata, and the base colour, which
    // metadata sets through its colour or palette index keys.
    ItemVisualsManager *visuals = client->getItemVisualsManager();
    const video::SColor base = visuals->getItemstackColor(stack, client);
    char colour[16];
    std::snprintf(colour, sizeof(colour), "\n%08x", base.color);
    key = def.name + "\n" + stack.getInventoryOverlay(idef).name + colour;
    return true;
}

bool buildItemIconJob(Client *client, GoannaShaderSource &shsrc, const ItemStack &stack,
        IconJob &job) {
    IItemDefManager *idef = client->idef();
    ItemVisualsManager *visuals = client->getItemVisualsManager();
    ItemMesh *im = visuals->getItemMesh(stack, client);
    if (!im || !im->mesh)
        return false;
    // drawItemStack's colours: getItemstackColor for the stack, replaced per
    // buffer by the tile's own colour where the buffer info carries one.
    const video::SColor base = visuals->getItemstackColor(stack, client);
    job = IconJob();
    job.needs_shading = im->needs_shading;
    const u32 count = std::min<u32>(im->mesh->getMeshBufferCount(), (u32)im->buffer_info.size());
    for (u32 j = 0; j < count; ++j) {
        scene::IMeshBuffer *buf = im->mesh->getMeshBuffer(j);
        const video::SMaterial &mat = buf->getMaterial();
        IconBuffer b;
        b.buffer = buf;
        b.color = base;
        im->buffer_info[j].applyOverride(b.color);
        b.blend = blendFor(shsrc, mat.MaterialType);
        b.cull_back = mat.BackfaceCulling;
        b.clamp_u = mat.TextureLayers[0].TextureWrapU != video::ETC_REPEAT;
        b.clamp_v = mat.TextureLayers[0].TextureWrapV != video::ETC_REPEAT;
        b.depth_bias = mat.PolygonOffsetDepthBias != 0 || mat.PolygonOffsetSlopeScale != 0;
        b.layers = textureImages(mat.getTexture(0));
        job.buffers.push_back(std::move(b));
    }
    if (!stack.getInventoryOverlay(idef).name.empty()) {
        std::vector<const video::IImage *> o =
                textureImages(visuals->getInventoryOverlayTexture(stack, client));
        if (!o.empty())
            job.overlay = o[0];
    }
    return true;
}

ItemIconCache::ItemIconCache() = default;
ItemIconCache::~ItemIconCache() = default;

Ref<Texture2D> ItemIconCache::icon(GoannaSession &session, const ItemStack &stack) {
    const auto t0 = Clock::now();
    // Before anything reaches ItemVisualsManager: even the colour lookup
    // builds the item's visuals, mesh included, and createItemMesh is a
    // fatal error without the extrusion mesh cache.
    if (!m_extrusion_holder)
        m_extrusion_holder = std::make_unique<WieldMesh>();
    Client *client = session.meshClient();
    std::string key;
    if (!itemIconKey(client, stack, key))
        return Ref<Texture2D>();
    auto it = m_entries.find(key);
    if (it != m_entries.end())
        return it->second->texture;

    auto e = std::make_unique<Entry>();
    if (!buildItemIconJob(client, session.shsrc(), stack, e->job))
        return Ref<Texture2D>();
    // A blank of the right size until flush() draws it, so anything that
    // lays out by the texture's size sees the final size at once.
    Ref<Image> blank = Image::create_empty((int32_t)m_size, (int32_t)m_size, false, Image::FORMAT_RGBA8);
    e->texture = ImageTexture::create_from_image(blank);
    e->texture_size = m_size;
    Entry *entry = e.get();
    m_entries.emplace(key, std::move(e));
    m_pending.push_back(entry);
    m_build_ms += msSince(t0);
    return entry->texture;
}

void ItemIconCache::setSize(u32 px) {
    if (px == 0 || px == m_size)
        return;
    m_size = px;
    m_pending.clear();
    for (auto &kv : m_entries)
        m_pending.push_back(kv.second.get());
}

void ItemIconCache::flush() {
    if (m_pending.empty())
        return;
    const auto t0 = Clock::now();
    std::vector<Entry *> jobs;
    jobs.swap(m_pending);
    const u32 size = m_size;
    std::vector<std::vector<u8>> pixels(jobs.size());

    // Each icon is independent and only reads shared data, so the batch
    // splits across threads by taking the next job from a counter.
    std::atomic<size_t> next{0};
    auto work = [&]() {
        for (size_t i = next.fetch_add(1); i < jobs.size(); i = next.fetch_add(1))
            rasteriseItemIcon(jobs[i]->job, size, pixels[i]);
    };
    const size_t hw = std::max(1u, std::thread::hardware_concurrency());
    const size_t threads = std::min(hw, (jobs.size() + 15) / 16);
    std::vector<std::thread> pool;
    for (size_t t = 1; t < threads; ++t)
        pool.emplace_back(work);
    work();
    for (std::thread &th : pool)
        th.join();
    const auto t1 = Clock::now();
    m_raster_ms += std::chrono::duration<double, std::milli>(t1 - t0).count();

    for (size_t i = 0; i < jobs.size(); ++i) {
        Entry *e = jobs[i];
        PackedByteArray bytes;
        bytes.resize((int64_t)pixels[i].size());
        std::memcpy(bytes.ptrw(), pixels[i].data(), pixels[i].size());
        Ref<Image> img = Image::create_from_data((int32_t)size, (int32_t)size, false,
                Image::FORMAT_RGBA8, bytes);
        // update() keeps the texture and only replaces its pixels; a new
        // size needs set_image(), which still keeps the RID, so every
        // control already drawing this icon picks the change up.
        if (e->texture_size == size) {
            e->texture->update(img);
        } else {
            e->texture->set_image(img);
            e->texture_size = size;
        }
    }
    m_upload_ms += msSince(t1);
    m_drawn += jobs.size();
    m_flushes++;
    m_last_flush_count = (u32)jobs.size();
    m_last_flush_ms = msSince(t0);
}

void ItemIconCache::clear() {
    m_pending.clear();
    m_entries.clear();
}

Dictionary ItemIconCache::stats() const {
    Dictionary d;
    d["size"] = (int)m_size;
    d["icons"] = (int64_t)m_entries.size();
    d["pending"] = (int64_t)m_pending.size();
    d["drawn"] = (int64_t)m_drawn;
    d["flushes"] = (int64_t)m_flushes;
    d["build_ms"] = m_build_ms;
    d["raster_ms"] = m_raster_ms;
    d["upload_ms"] = m_upload_ms;
    d["last_flush_ms"] = m_last_flush_ms;
    d["last_flush_count"] = (int)m_last_flush_count;
    d["frames"] = (int64_t)m_frames;
    d["frame_ms"] = m_frame_ms;
    return d;
}

} // namespace goanna
