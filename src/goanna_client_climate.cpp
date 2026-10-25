// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The server's temperature and wetness field, as a 3D texture round the
// camera for the frost, wet ground, dust and mist shaders
// (docs/systems/climate.md). The store and the sampling are in
// goanna_climate.cpp; this joins the channel, decodes the messages and
// uploads the grid.
//
// The grid is built on a thread of its own: 100 by 24 by 100 texels take
// about 10 ms, and the grid moves every map block the camera crosses. While
// a build runs the store is the thread's, so messages wait in
// m_climate_pending and are applied between builds.

#include "goanna_client_internal.h"
#include "goanna_climate.h"

#include <godot_cpp/classes/image_texture3d.hpp>
#include <godot_cpp/classes/json.hpp>

using namespace godot;

namespace goanna {

namespace {

// 25 by 6 by 25 map blocks round the camera's, at 4 nodes a texel: the
// range the server sends (12 blocks round, 2 below and 3 above).
constexpr int kClimateNX = 100, kClimateNY = 24, kClimateNZ = 100;
constexpr float kClimateCell = 4.0f;

std::vector<float> floats(const Variant &v) {
    std::vector<float> out;
    if (v.get_type() != Variant::ARRAY)
        return out;
    const Array a = v;
    for (int i = 0; i < a.size(); ++i)
        out.push_back((float)(double)a[i]);
    return out;
}

} // namespace

// One message: the header with the bands, a batch of blocks, or blocks the
// player has left. Anything else, or another version, is ignored.
void GoannaClient::applyClimate(const std::string &message) {
    const Variant parsed = JSON::parse_string(String::utf8(message.c_str(), (int)message.size()));
    if (parsed.get_type() != Variant::DICTIONARY)
        return;
    const Dictionary d = parsed;
    if ((int)d.get("v", 0) != 1)
        return;
    const String kind = d.get("kind", "");
    if (kind == "header") {
        auto rep = [&](const char *name) {
            const Variant band = d.get(name, Variant());
            return band.get_type() == Variant::DICTIONARY ? floats(Dictionary(band).get("rep", Variant()))
                                                          : std::vector<float>();
        };
        const String order = d.get("order", "x,y,z");
        if (order != "x,y,z" || !m_climate.setBands(rep("temp"), rep("wet"), rep("hum")))
            UtilityFunctions::push_warning("climate: header not understood, field left off");
        return;
    }
    const Variant list = d.get("b", Variant());
    if (list.get_type() != Variant::ARRAY)
        return;
    const Array blocks = list;
    for (int i = 0; i < blocks.size(); ++i) {
        if (blocks[i].get_type() != Variant::ARRAY)
            continue;
        const Array b = blocks[i];
        if (kind == "drop" && b.size() >= 3) {
            m_climate.drop((int)b[0], (int)b[1], (int)b[2]);
        } else if (kind == "blocks" && b.size() >= 5 && b[4].get_type() == Variant::STRING) {
            const CharString text = String(b[4]).utf8();
            const std::string_view encoded(text.get_data(), text.length());
            if (base64_is_valid(encoded))
                m_climate.put((int)b[0], (int)b[1], (int)b[2], (int)b[3], base64_decode(encoded));
        }
    }
}

void GoannaClient::climate_inject(const String &message) {
    const CharString text = message.utf8();
    m_climate_pending.emplace_back(text.get_data(), text.length());
}

void GoannaClient::updateClimate(const Vector3 &around) {
    static const char *kBox = "goanna_climate_box";
    static const char *kSize = "goanna_climate_size";
    if (m_session && m_session->syncFieldChannel()) {
        // A new or withdrawn grant: what the old channel sent is not this one's.
        m_climate_pending.clear();
        m_climate_reset = true;
    }
    if (m_session)
        for (auto &message : m_session->takeField())
            m_climate_pending.push_back(std::move(message));
    if (m_climate_busy) {
        if (!m_climate_done.load(std::memory_order_acquire))
            return;
        m_climate_thread.join();
        m_climate_busy = false;
        ema(m_ms_climate, m_climate_build_ms);
        TypedArray<Ref<Image>> slices;
        PackedByteArray bytes;
        bytes.resize(kClimateNX * kClimateNY * 4);
        for (int z = 0; z < kClimateNZ; ++z) {
            std::memcpy(bytes.ptrw(), m_climate_rgba.data() + (size_t)z * kClimateNX * kClimateNY * 4, bytes.size());
            slices.push_back(Image::create_from_data(kClimateNX, kClimateNY, false, Image::FORMAT_RGBA8, bytes));
        }
        bool ok = true;
        if (m_climate_tex.is_null()) {
            m_climate_tex.instantiate();
            ok = m_climate_tex->create(Image::FORMAT_RGBA8, kClimateNX, kClimateNY, kClimateNZ, false, slices) == OK;
            if (!ok)
                m_climate_tex.unref();
            else
                set_view_shader_parameter("goanna_climate", m_climate_tex);
        } else {
            m_climate_tex->update(slices);
        }
        const ClimateGrid &g = m_climate_built_grid;
        set_view_shader_parameter(kBox, ok ? Vector4(g.ox, g.oy, g.oz, g.cell) : Vector4());
        set_view_shader_parameter(kSize, Vector4(g.nx, g.ny, g.nz, ok ? 1.0f : 0.0f));
    }
    if (m_climate_reset) {
        m_climate.clear();
        m_climate_reset = false;
    }
    for (const auto &message : m_climate_pending)
        applyClimate(message);
    m_climate_pending.clear();
    if (!m_climate.hasBands() || m_climate.blocks() == 0) {
        // Nothing to draw from: a server without the field, or not yet sent.
        if (m_climate_built_revision != 0) {
            set_view_shader_parameter(kBox, Vector4());
            set_view_shader_parameter(kSize, Vector4(kClimateNX, kClimateNY, kClimateNZ, 0.0f));
            m_climate_built_revision = 0;
        }
        return;
    }
    // In Luanti's coordinates, z unflipped: the shaders flip it back.
    ClimateGrid grid;
    grid.cell = kClimateCell;
    grid.nx = kClimateNX;
    grid.ny = kClimateNY;
    grid.nz = kClimateNZ;
    const int bx = (int)std::floor((around.x + 0.5f) / 16.0f);
    const int by = (int)std::floor((around.y + 0.5f) / 16.0f);
    const int bz = (int)std::floor((-around.z + 0.5f) / 16.0f);
    grid.ox = (bx - 12) * 16 - 0.5f;
    grid.oy = (by - 2) * 16 - 0.5f;
    grid.oz = (bz - 12) * 16 - 0.5f;
    const bool moved = grid.ox != m_climate_built_grid.ox || grid.oy != m_climate_built_grid.oy ||
            grid.oz != m_climate_built_grid.oz;
    if (!moved && m_climate.revision() == m_climate_built_revision)
        return;
    m_climate_built_grid = grid;
    m_climate_built_revision = m_climate.revision();
    m_climate_busy = true;
    m_climate_done.store(false, std::memory_order_relaxed);
    m_climate_thread = std::thread([this, grid]() {
        const auto started = clock_t_::now();
        m_climate.build(grid, m_climate_rgba);
        m_climate_build_ms = ms_since(started);
        m_climate_done.store(true, std::memory_order_release);
    });
}

Dictionary GoannaClient::climate_stats() const {
    Dictionary d;
    d["joined"] = m_session && m_session->fieldJoined();
    d["bands"] = m_climate.hasBands();
    d["blocks"] = (int64_t)(m_climate_busy ? -1 : (int64_t)m_climate.blocks());
    d["build_ms"] = m_ms_climate;
    d["texture"] = m_climate_tex.is_valid();
    return d;
}

// The field at a Godot world position, from the store, for tests and the
// control channel: temperature, wetness, humidity and how known, or an
// empty dictionary while a build holds the store.
Dictionary GoannaClient::climate_at(const Vector3 &world) const {
    Dictionary d;
    if (m_climate_busy)
        return d;
    const ClimateValue v = m_climate.sample(world.x, world.y, -world.z);
    d["temp"] = v.temp;
    d["wet"] = v.wet;
    d["hum"] = v.hum;
    d["known"] = v.known;
    return d;
}

} // namespace goanna
