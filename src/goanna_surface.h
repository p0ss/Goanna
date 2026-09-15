// SPDX-License-Identifier: LGPL-2.1-or-later
// Two-dimensional baked terrain, independent of mapblock delivery.
#pragma once

#include "goanna_lod.h"
#include "goanna_mesh_pool.h"
#include <string>
#include <set>

namespace goanna {
struct SurfaceKey {
    int step = 128, x = 0, z = 0;
    bool operator<(const SurfaceKey &o) const {
        if (step != o.step) return step < o.step;
        if (x != o.x) return x < o.x;
        return z < o.z;
    }
};
struct ForestSpan {
    int16_t x = 0, z = 0, bottom = 0, top = 0;
    content_t content = CONTENT_AIR;
    uint8_t param2 = 0, size = 1, coverage = 255;
};
struct SurfaceSample {
    int16_t height = 0, water_height = -32768;
    content_t top = CONTENT_AIR, side = CONTENT_AIR, water = CONTENT_AIR;
    std::vector<ForestSpan> forest;
    bool known() const { return top != CONTENT_AIR && top != CONTENT_IGNORE; }
};
// Assemble bounded parts only for tiles requested by this client. Immutable
// revision/key identities allow retries and out-of-order parts to coalesce.
class SurfaceAssembler {
    struct Parts {std::vector<std::string> data;size_t bytes=0;int received=0;};
    std::map<SurfaceKey,Parts> pending;
public:
    void clear() {pending.clear();}
    void erase(const SurfaceKey &key) {pending.erase(key);}
    bool accept(const std::string &wire,const std::string &who,const std::string &revision,
            const std::function<bool(const SurfaceKey&)> &wanted,std::string &complete);
};

struct SurfaceTile {
    SurfaceKey key;
    std::array<SurfaceSample, 256> samples;
    bool complete() const {
        for (const auto &sample : samples) if (!sample.known()) return false;
        return true;
    }
};
using SurfaceTiles = std::map<SurfaceKey, std::shared_ptr<const SurfaceTile>>;
// Four-node column footprints of ground already published by the voxel
// renderer. Heights use the same unshifted node boundaries as LodSurface.
using SurfaceCoverage = std::map<std::pair<int, int>, float>;
int surfaceFloor(int value, int divisor);
bool surfaceStep(int step);
int surfaceForestCell(double distance);
std::vector<ForestSpan> forestVisibleRuns(const ForestSpan &span,
        const std::map<v3s16,int> &blocks, int x, int z);
bool decodeSurface(const std::string &wire, const std::string &who,
        const std::string &revision, const std::function<content_t(const std::string &)> &resolve,
        SurfaceTile &out);
std::vector<SurfaceKey> surfaceWanted(int x, int z, int radius);

struct SurfaceChunk {
    LodRegionMesh mesh;
    uint64_t signature = 1469598103934665603ULL;
};
struct SurfaceJob : MeshJob {
    SurfaceTiles tiles;
    SurfaceCoverage coverage;
    // Ground-only provider shells cannot claim to replace forest geometry.
    std::map<v3s16,int> forest_blocks;
    struct Source {
        v3s16 position;
        int cell;
        std::shared_ptr<const BlockLodChain> chain;
        bool ground_from_chain=true; // near meshes only; LODs report emitted faces
    };
    std::vector<Source> sources;
    std::vector<LodGroundPatch> ground;
    int x = 0, z = 0, radius = 0, reach = 0;
    const NodeDefManager *ndef = nullptr;
    GoannaTextureSource *tsrc = nullptr;
    const MaterialTable *materials = nullptr;
    LodTileCache *tile_cache = nullptr;
    LodRegionMesh result; // counts only; geometry is partitioned below
    std::map<SurfaceKey, SurfaceChunk> chunks;
    uint64_t retired_serial = 0;
    int cells = 0, covered = 0, forest_quads = 0, forest_columns_count = 0;
    void run() override;
};
} // namespace goanna
