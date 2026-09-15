// SPDX-License-Identifier: LGPL-2.1-or-later
// Main-thread ownership of the baked surface stream and its published mesh.
#include "goanna_client.h"
#include "goanna_session.h"
#include "nodedef.h"
#include <algorithm>
#include <cmath>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;
using namespace goanna;

void GoannaClient::surfaceStage(MeshInstance3D *node) {
    if (!node || m_surface_uploading || !m_surface_published || !surfaceOffered()) return;
    node->set_visible(false);
    m_surface_waiting[++m_surface_retired_serial]=node->get_instance_id();
    ++m_surface_source_revision;
}

void GoannaClient::surfaceRetire(MeshInstance3D *&node) {
    if (!node || !m_surface_published || !surfaceOffered()) return;
    ++m_surface_source_revision;
    // A surface job may already have captured this staged node. Keep its
    // original reveal serial when a newer mesh overtakes it: the older job
    // must still have a visible replacement when it removes the prediction.
    // A published surface may have a hole for this mesh. Keep that mesh
    // until the next surface publication has observed its replacement or
    // filled its footprint. This also covers movement out of the near field.
    node->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
    node->set_gi_mode(GeometryInstance3D::GI_MODE_DISABLED);
    m_surface_retired.emplace_back(++m_surface_retired_serial, node);
    node = nullptr;
}

void GoannaClient::surfacePublish() {
    if (!m_surface_ready) return;
    const auto start = std::chrono::steady_clock::now();
    // One small chunk at a time, hidden until the entire replacement is
    // uploaded. Old geometry keeps drawing throughout the upload budget.
    while (!m_surface_uploads.empty()) {
        const auto key = m_surface_uploads.back();
        m_surface_uploads.pop_back();
        auto &next = m_surface_staged[key];
        const auto &chunk = m_surface_ready->chunks.at(key);
        m_surface_uploading = true;
        lodPublishRegion({}, next.region, chunk.mesh, std::chrono::steady_clock::now(), 0, 0);
        m_surface_uploading = false;
        next.signature = chunk.signature;
        if (next.region.node) {
            next.region.node->set_name("BakedSurface");
            next.region.node->set_visible(false);
        }
        if (std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() >= 2)
            return;
    }
    for (auto it = m_surface_regions.begin(); it != m_surface_regions.end();) {
        if (!m_surface_ready->chunks.count(it->first) || m_surface_staged.count(it->first)) {
            if (it->second.region.node) it->second.region.node->queue_free();
            it = m_surface_regions.erase(it);
        } else ++it;
    }
    for (auto &kv : m_surface_staged) {
        if (kv.second.region.node) kv.second.region.node->set_visible(true);
        m_surface_regions.emplace(kv.first, std::move(kv.second));
    }
    m_surface_staged.clear();
    for (auto it = m_surface_retired.begin(); it != m_surface_retired.end();) {
        if (it->first <= m_surface_ready->retired_serial) {
            const auto id=it->second->get_instance_id();
            for (auto waiting=m_surface_waiting.begin();waiting!=m_surface_waiting.end();)
                if (waiting->second==id) waiting=m_surface_waiting.erase(waiting); else ++waiting;
            it->second->queue_free();
            it = m_surface_retired.erase(it);
        } else ++it;
    }
    for (auto it=m_surface_waiting.begin();it!=m_surface_waiting.end();) {
        if (it->first>m_surface_ready->retired_serial) {++it;continue;}
        auto *node=Object::cast_to<MeshInstance3D>(UtilityFunctions::instance_from_id(it->second));
        if (node) node->set_visible(true);
        it=m_surface_waiting.erase(it);
    }
    m_surface_reach = m_surface_ready->reach;
    m_surface_cells = m_surface_ready->cells;
    m_surface_covered = m_surface_ready->covered;
    m_surface_quads = m_surface_ready->result.quads;
    m_surface_forest_quads = m_surface_ready->forest_quads;
    m_surface_forest_columns = m_surface_ready->forest_columns_count;
    const double elapsed = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - m_surface_started).count();
    if (m_surface_first_ms < 0) m_surface_first_ms = elapsed;
    if (m_surface_overview_ms < 0 && m_surface_reach >= m_surface_ready->radius)
        m_surface_overview_ms = elapsed;
    m_surface_published = true;
    m_surface_ready.reset();
    m_surface_building = false;
}

bool GoannaClient::surfaceOffered() const {
    if (!m_session || m_session->farRenderingGrant() <= 0 || m_lod_distance <= 0 ||
            m_far_distance <= 0) return false;
    const auto options = m_session->serverOptions();
    auto capability = options.find("surface_tiles"), revision = options.find("surface_revision");
    return capability != options.end() && (capability->second == "1" || capability->second == "2") &&
            revision != options.end() && revision->second.size() == 40;
}

void GoannaClient::surfaceClear() {
    ++m_surface_generation;
    m_mesh_pool.cancelKind(MeshJobKey::kSurface);
    for (auto &kv : m_surface_regions) if (kv.second.region.node) kv.second.region.node->queue_free();
    for (auto &kv : m_surface_staged) if (kv.second.region.node) kv.second.region.node->queue_free();
    for (auto &entry : m_surface_retired) entry.second->queue_free();
    m_surface_regions.clear();
    m_surface_staged.clear();
    m_surface_retired.clear();
    for (const auto &entry:m_surface_waiting) {
        auto *node=Object::cast_to<MeshInstance3D>(UtilityFunctions::instance_from_id(entry.second));
        if (node) node->set_visible(true);
    }
    m_surface_waiting.clear();
    m_surface_ready.reset();
    m_surface_uploads.clear();
    m_surface_published = false;
    m_surface_first_ms = m_surface_overview_ms = -1;
    m_surface_tiles.clear();
    m_surface_assembler.clear();
    m_surface_pending.clear();
    m_surface_revision.clear();
    m_surface_building = false;
    m_surface_received = m_surface_reach = m_surface_cells = m_surface_covered = 0;
    m_surface_forest_quads = m_surface_forest_columns = 0;
    m_surface_signature = m_surface_input_signature = 0;
}

void GoannaClient::surfaceUpdate() {
    using Clock = std::chrono::steady_clock;
    if (!surfaceOffered()) {
        if (!m_surface_revision.empty()) surfaceClear();
        return;
    }
    surfacePublish();
    const auto now = Clock::now();
    const auto revision = m_session->serverOptions().at("surface_revision");
    if (revision != m_surface_revision) {
        surfaceClear();
        m_surface_revision = revision;
        m_surface_started = now;
        m_far_dirty = true;
    }
    bool arrived = false;
    for (const std::string &wire : m_session->takeSurfaces()) {
        std::string complete;
        if (!m_surface_assembler.accept(wire,m_session->playerName(),revision,
                [&](const SurfaceKey &key){return m_surface_pending.count(key)!=0;},complete)) continue;
        auto tile = std::make_shared<SurfaceTile>();
        if (!decodeSurface(complete, m_session->playerName(), revision, [&](const std::string &name) {
                content_t id = CONTENT_IGNORE;
                m_session->nodeDefs()->getId(name, id);
                return id;
            }, *tile)) continue;
        // Unsolicited, stale and out-of-grant replies cannot expand coverage.
        if (!m_surface_pending.erase(tile->key)) continue;
        m_surface_tiles[tile->key] = std::move(tile);
        ++m_surface_received;
        arrived = true;
    }
    if (!arrived && std::chrono::duration<double>(now - m_surface_scan).count() < 0.25) return;
    m_surface_scan = now;
    const int x = (int)std::floor(m_lod_centre.x), z = (int)std::floor(-m_lod_centre.z);
    const int radius = std::min(m_far_distance, m_session->farRenderingGrant());
    const auto wanted = surfaceWanted(x, z, radius);
    m_surface_wanted = wanted.size();
    const std::set<SurfaceKey> wanted_set(wanted.begin(), wanted.end());
    for (auto it = m_surface_pending.begin(); it != m_surface_pending.end();) {
        if (!wanted_set.count(it->first) ||
                std::chrono::duration<double>(now - it->second).count() > 30.0) {
            m_surface_assembler.erase(it->first);
            it = m_surface_pending.erase(it);
        } else ++it;
    }
    int reach = radius;
    for (const auto &key : wanted) {
        const auto have = m_surface_tiles.find(key);
        if (have != m_surface_tiles.end() && have->second->complete()) continue;
        if (key.step == 128) {
            const int width = key.step * 16;
            const int dx = std::max({key.x * width - x, 0, x - (key.x + 1) * width});
            const int dz = std::max({key.z * width - z, 0, z - (key.z + 1) * width});
            reach = std::min(reach, (int)std::sqrt(double(dx) * dx + double(dz) * dz));
        }
        // Unknown samples are immutable for this bake revision. They keep
        // the reported horizon short without becoming an endless retry.
        if (have != m_surface_tiles.end()) continue;
        if (m_surface_pending.size() < 8 && !m_surface_pending.count(key)) {
            m_session->requestSurface(revision, key.step, key.x, key.z);
            m_surface_pending[key] = now;
        }
    }
    // Keep a small travel cache, but not an ever-growing copy of the world.
    for (auto it = m_surface_tiles.begin(); it != m_surface_tiles.end() && m_surface_tiles.size() > 1024;)
        if (!wanted_set.count(it->first)) it = m_surface_tiles.erase(it); else ++it;
    if (m_surface_building || m_surface_tiles.empty() ||
            std::chrono::duration<double>(now - m_surface_mesh_time).count() < 0.75) return;

    uint64_t input_signature = 1469598103934665603ULL;
    auto input_hash = [&](uint64_t value) {
        input_signature = (input_signature ^ value) * 1099511628211ULL;
    };
    input_hash(surfaceFloor(x, 32)); input_hash(surfaceFloor(z, 32));
    input_hash(radius); input_hash(reach); input_hash(m_surface_received);
    input_hash(m_surface_source_revision);
    if (input_signature == m_surface_input_signature) return;
    auto job = std::make_unique<SurfaceJob>();
    job->tiles = m_surface_tiles;
    job->x = surfaceFloor(x, 32) * 32;
    job->z = surfaceFloor(z, 32) * 32;
    job->radius = radius;
    job->reach = reach;
    job->retired_serial = m_surface_retired_serial;
    job->ndef = m_session->nodeDefs();
    job->tsrc = m_session->tsrc();
    job->materials = &m_session->materialTable();
    job->tile_cache = &m_lod_tiles;
    auto cover = [&](const v3s16 &bp, int drawn_cell,
            std::shared_ptr<const BlockLodChain> chain,bool near=false) {
        if (std::abs(bp.X*16-x)>radius+128 || std::abs(bp.Z*16-z)>radius+128) return;
        if (chain) job->sources.push_back({bp,std::max(1,drawn_cell),std::move(chain),near});
    };
    // These are the immutable chains actually captured by the published mesh,
    // not newer logical data which may still be waiting in a worker.
    for (const auto &kv:m_lod_regions) {
        const auto &region=kv.second;
        if (!region.published) continue; // known empty publication counts too
        job->ground.insert(job->ground.end(),region.published_ground.begin(),region.published_ground.end());
        for (const auto &entry:region.published_chains)
            cover(entry.first,entry.second->hasCell(1)?region.published_exact_cell:
                    region.published_coarse_cell,entry.second);
    }
    for (const auto &kv:m_near_regions)
        for (const auto &bp:kv.second.published_members) {
            auto it=m_lod_chains.find(bp);
            if (it!=m_lod_chains.end()) cover(bp,1,it->second,true);
        }

    uint64_t signature = 1469598103934665603ULL;
    auto hash = [&](uint64_t value) { signature = (signature ^ value) * 1099511628211ULL; };
    hash(job->x); hash(job->z); hash(radius); hash(reach); hash(m_surface_received);
    hash(m_surface_retired_serial);
    hash(m_surface_source_revision);
    for (const auto &kv : job->coverage) {
        hash(kv.first.first); hash(kv.first.second); hash((int)kv.second);
    }
    if (signature == m_surface_signature) {
        m_surface_input_signature = input_signature;
        return;
    }
    const MeshJobKey key{MeshJobKey::kSurface, v3s16(0, 0, 0), 0};
    if (!m_mesh_pool.running()) {
        // The explicit serial-meshing debug mode obeys the same publication
        // contract, though it deliberately pays CPU meshing on this thread.
        job->run();
        m_surface_ready = std::move(job);
        for (const auto &kv : m_surface_ready->chunks) {
            const auto old = m_surface_regions.find(kv.first);
            if (old == m_surface_regions.end() || old->second.signature != kv.second.signature)
                m_surface_uploads.push_back(kv.first);
        }
        m_surface_building = true;
        m_surface_signature = signature;
        m_surface_input_signature = input_signature;
        m_surface_mesh_time = now;
        return;
    }
    if (m_mesh_pool.submit(key, m_surface_generation + 1, MeshWorkStage::kCoverage, 0,
            std::move(job))) {
        ++m_surface_generation;
        m_surface_building = true;
        m_surface_signature = signature;
        m_surface_input_signature = input_signature;
        m_surface_mesh_time = now;
    }
}
