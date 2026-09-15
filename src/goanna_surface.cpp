// SPDX-License-Identifier: LGPL-2.1-or-later
// Baked surface tiles: validation, overview-first scheduling and stepped mesh.
#include "goanna_surface.h"
#include "util/base64.h"
#include <algorithm>
#include <cmath>
#include <set>
#include <sstream>
#include <zlib.h>
#include <tuple>

namespace goanna {
int surfaceFloor(int value, int divisor) {
    return value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor);
}
int surfaceForestCell(double distance) {
    return distance < 512 ? 1 : distance < 1024 ? 2 : distance < 2048 ? 4 : 64;
}
std::vector<ForestSpan> forestVisibleRuns(const ForestSpan &span,
        const std::map<v3s16,int> &blocks,int x,int z) {
    std::vector<ForestSpan> out;
    for (int bottom=span.bottom;bottom<span.top;) {
        const int by=surfaceFloor(bottom,16);
        const int top=std::min<int>(span.top,(by+1)*16);
        auto block=blocks.find(v3s16(surfaceFloor(x,16),by,surfaceFloor(z,16)));
        if (block==blocks.end() || block->second>span.size) {
            if (!out.empty() && out.back().top==bottom) out.back().top=top;
            else {auto next=span;next.bottom=bottom;next.top=top;out.push_back(next);}
        }
        bottom=top;
    }
    return out;
}

bool surfaceStep(int step) { return step == 4 || step == 8 || step == 16 || step == 64 || step == 128; }

bool SurfaceAssembler::accept(const std::string &wire,const std::string &who,
        const std::string &revision,const std::function<bool(const SurfaceKey&)> &wanted,
        std::string &complete) {
    if (wire.size()>65535) return false;
    if (wire.compare(0,13,"surface_part ")!=0) {complete=wire;return true;}
    std::istringstream in(wire);
    std::string tag,recipient,rev,body,extra;
    SurfaceKey key;int version,part,count;
    if (!(in>>tag>>recipient>>version>>rev>>key.step>>key.x>>key.z>>part>>count>>body) ||
            (in>>extra) || recipient!=who || rev!=revision || version!=2 ||
            !surfaceStep(key.step) || key.x < -512 || key.x > 512 || key.z < -512 || key.z > 512 ||
            count<2 || count>128 || part<0 || part>=count || body.size()>60000 ||
            !wanted(key)) return false;
    if (!pending.count(key) && pending.size()>=8) return false;
    auto &pieces=pending[key];
    if (pieces.data.empty()) pieces.data.resize(count);
    if (pieces.data.size()!=(size_t)count) {pending.erase(key);return false;}
    if (!pieces.data[part].empty()) {
        if (pieces.data[part]!=body) pending.erase(key);
        return false;
    }
    size_t bytes=body.size();
    for (const auto &entry:pending) bytes+=entry.second.bytes;
    if (bytes>16*1024*1024) {pending.erase(key);return false;}
    pieces.bytes+=body.size();pieces.data[part]=std::move(body);++pieces.received;
    if (pieces.received!=count) return false;
    complete="surface "+who+" 2 "+revision+" "+std::to_string(key.step)+" "+
            std::to_string(key.x)+" "+std::to_string(key.z)+" ";
    for (const auto &piece:pieces.data) complete+=piece;
    pending.erase(key);
    return true;
}

bool decodeSurface(const std::string &wire, const std::string &who,
        const std::string &revision, const std::function<content_t(const std::string &)> &resolve,
        SurfaceTile &out) {
    if (wire.size() > 8*1024*1024) return false;
    std::istringstream in(wire);
    std::string tag, recipient, rev, body, extra;
    int version;
    SurfaceTile tile;
    if (!(in >> tag >> recipient >> version >> rev >> tile.key.step >> tile.key.x >>
            tile.key.z >> body) || (in >> extra) || tag != "surface" || recipient != who ||
            (version != 1 && version != 2) || rev != revision || !surfaceStep(tile.key.step) ||
            tile.key.x < -512 || tile.key.x > 512 || tile.key.z < -512 || tile.key.z > 512) return false;
    const size_t split = body.find('|');
    if (split == std::string::npos) return false;
    const std::string encoded = body.substr(split + 1);
    if (!base64_is_valid(encoded)) return false;
    std::string raw = base64_decode(encoded);
    if (version == 2) {
        // An explicit decoded bound protects against malformed compressed tiles.
        std::string unpacked(8 * 1024 * 1024, '\0');
        uLongf size = unpacked.size();
        if (uncompress(reinterpret_cast<Bytef *>(unpacked.data()), &size,
                reinterpret_cast<const Bytef *>(raw.data()), raw.size()) != Z_OK) return false;
        unpacked.resize(size);
        raw = std::move(unpacked);
    }
    if (raw.size() < 256 * 7 || (version == 1 && raw.size() != 256 * 7) ||
            (raw.size() - 256 * 7) % 12 != 0) return false;
    std::vector<content_t> names{CONTENT_AIR};
    std::istringstream palette(body.substr(0, split));
    std::string name;
    while (std::getline(palette, name, ',')) {
        if (name.empty() || name.size() > 256 || names.size() >= 255) return false;
        names.push_back(resolve(name));
    }
    auto signed16 = [&](size_t i) -> int16_t {
        return (int16_t)((uint8_t)raw[i] * 256 + (uint8_t)raw[i + 1]);
    };
    for (size_t i = 0; i < 256; ++i) {
        const size_t at = i * 7;
        const unsigned top = (uint8_t)raw[at + 4], side = (uint8_t)raw[at + 5];
        const unsigned water = (uint8_t)raw[at + 6];
        if (top >= names.size() || side >= names.size() || water >= names.size()) return false;
        tile.samples[i] = {signed16(at), signed16(at + 2), names[top], names[side], names[water]};
    }
    for (size_t at = 256 * 7; at < raw.size(); at += 12) {
        const int x = signed16(at), z = signed16(at + 2);
        const int bottom = signed16(at + 4), top = signed16(at + 6);
        const unsigned material = (uint8_t)raw[at + 8], param2 = (uint8_t)raw[at + 9];
        const unsigned size = (uint8_t)raw[at + 10], coverage = (uint8_t)raw[at + 11];
        const int width = tile.key.step * 16;
        if (x < 0 || z < 0 || x >= width || z >= width || top <= bottom || top-bottom > 128 ||
                material == 0 || material >= names.size() || coverage == 0 ||
                (size != 1 && size != 2 && size != 4 && size != (unsigned)tile.key.step) ||
                (size <= 4 && coverage != 255) ||
                x + size > width || z + size > width ||
                tile.key.x*width+x < -32768 || tile.key.x*width+x+(int)size > 32767 ||
                tile.key.z*width+z < -32768 || tile.key.z*width+z+(int)size > 32767 ||
                (size > 1 && (x % size || z % size))) return false;
        tile.samples[(z/tile.key.step)*16+x/tile.key.step].forest.push_back({
                (int16_t)(tile.key.x*width+x), (int16_t)(tile.key.z*width+z),
                (int16_t)bottom, (int16_t)top, names[material], (uint8_t)param2,
                (uint8_t)size, (uint8_t)coverage});
    }
    out = std::move(tile);
    return true;
}

static double boxDistance(int x, int z, int size, int cx, int cz) {
    const double dx = std::max({x - cx, 0, cx - x - size});
    const double dz = std::max({z - cz, 0, cz - z - size});
    return std::sqrt(dx * dx + dz * dz);
}

std::vector<SurfaceKey> surfaceWanted(int x, int z, int radius) {
    std::vector<SurfaceKey> out;
    // Cover the complete grant first, then spend samples on local shape.
    for (int step : {128, 64, 16, 8, 4}) {
        const int reach = std::min(radius, step == 128 ? radius :
                step == 64 ? 4096 : step == 16 ? 2048 : step == 8 ? 1024 : 512);
        const int width = step * 16;
        std::vector<SurfaceKey> level;
        for (int tz = surfaceFloor(z - reach, width); tz <= surfaceFloor(z + reach, width); ++tz)
            for (int tx = surfaceFloor(x - reach, width); tx <= surfaceFloor(x + reach, width); ++tx)
                if (std::abs(tx) <= 512 && std::abs(tz) <= 512 &&
                        boxDistance(tx * width, tz * width, width, x, z) <= reach)
                    level.push_back({step, tx, tz});
        std::sort(level.begin(), level.end(), [&](const SurfaceKey &a, const SurfaceKey &b) {
            return boxDistance(a.x * width, a.z * width, width, x, z) <
                    boxDistance(b.x * width, b.z * width, width, x, z);
        });
        out.insert(out.end(), level.begin(), level.end());
    }
    // Broad terrain/canopy first. Then refine near to far across all three
    // forest rungs; a complete outer ring must not delay nearby silhouettes.
    auto geometry = std::find_if(out.begin(), out.end(), [](const auto &key) { return key.step <= 16; });
    std::stable_sort(geometry, out.end(), [&](const auto &a, const auto &b) {
        const auto distance = [&](const auto &k) {
            return boxDistance(k.x*k.step*16,k.z*k.step*16,k.step*16,x,z);
        };
        const double da=distance(a), db=distance(b);
        return da==db ? a.step<b.step : da<db;
    });
    return out;
}

void SurfaceJob::run() {
    std::map<std::pair<int,int>,float> exact_coverage;
    // Derive footprints on the worker, from immutable chains associated with
    // published meshes. A wide visited world must not rasterise all of its
    // ground columns on the main thread each time a tile arrives.
    for (const auto &source : sources) {
        if (!source.chain->surface_shell && source.chain->hasCell(source.cell))
            forest_blocks[source.position]=source.cell;
        if (!source.ground_from_chain) continue;
        if (source.cell < 4 && source.chain->hasCell(1)) {
            // A coarse mip can cover an entire four-node square because of
            // one ground column. Mask the preview on the grid actually drawn;
            // otherwise fine slopes acquire holes around their narrow ledges.
            for (int z=0;z<16;++z) for (int x=0;x<16;++x) {
                int top=0;
                if (source.cell==1) {
                    for (int y=0;y<16;++y) {
                        if (!source.chain->filledAt(1,x,y,z)) break;
                        const auto *c=source.chain->cellAt(1,x,y,z);
                        if (c && lodIsVegetation(ndef,c->face[0])) break;
                        top=y+1;
                    }
                } else {
                    const auto *lv=source.chain->forCell(2);
                    if (lv) top=lv->terrainAt(x/2,z/2);
                }
                if (top>0) {
                    auto key=std::make_pair(source.position.X*16+x,source.position.Z*16+z);
                    const float height=source.position.Y*16+top;
                    auto found=exact_coverage.emplace(key,height);
                    if (!found.second) found.first->second=std::max(found.first->second,height);
                }
            }
            continue;
        }
        const auto *level = source.chain->forCell(std::max(4,source.cell));
        if (!level || level->terrain.empty()) continue;
        for (int cz = 0; cz < level->n; ++cz) for (int cx = 0; cx < level->n; ++cx) {
            const int top = level->terrainAt(cx, cz);
            if (top <= 0) continue;
            const float height = source.position.Y * 16 + top;
            for (int dz = 0; dz < level->cell; dz += 4)
                for (int dx = 0; dx < level->cell; dx += 4) {
                    const auto key = std::make_pair(source.position.X * 4 + (cx * level->cell + dx) / 4,
                            source.position.Z * 4 + (cz * level->cell + dz) / 4);
                    auto found = coverage.emplace(key, height);
                    if (!found.second) found.first->second = std::max(found.first->second, height);
                }
        }
    }
    // Only emitted, published tops can remove the far surface. A buried
    // block or a column ceded to another tier may have ground in its mip
    // chain while contributing no face at all to the uploaded mesh.
    for (const auto &patch:ground) {
        if (std::abs(patch.x-x)>radius+128 || std::abs(patch.z-z)>radius+128) continue;
        const int step=patch.size>=4 ? 4 : 1;
        for (int dz=0;dz<patch.size;dz+=step) for (int dx=0;dx<patch.size;dx+=step) {
            auto &target=step==4 ? coverage : exact_coverage;
            auto key=std::make_pair(surfaceFloor(patch.x+dx,step),surfaceFloor(patch.z+dz,step));
            auto found=target.emplace(key,patch.height);
            if (!found.second) found.first->second=std::max(found.first->second,patch.height);
        }
    }
    struct Leaf { int x, z, size; SurfaceSample sample; bool cut; float height; };
    std::map<SurfaceKey, Leaf> leaves;
    std::set<SurfaceKey> occupied, exact_occupied;
    for (const auto &kv : coverage)
        for (int size = 4; size <= 128; size *= 2)
            occupied.insert({size, surfaceFloor(kv.first.first * 4, size),
                    surfaceFloor(kv.first.second * 4, size)});
    for (const auto &kv:exact_coverage)
        for (int size=1;size<=128;size*=2) {
            SurfaceKey key{size,surfaceFloor(kv.first.first,size),surfaceFloor(kv.first.second,size)};
            occupied.insert(key);exact_occupied.insert(key);
        }
    // Empty actual blocks also split a fallback canopy's footprint, so an
    // authoritative clearing removes precisely its own volume.
    for (const auto &block : forest_blocks)
        for (int size=4;size<=128;size*=2)
            for (int dz=0;dz<16;dz+=4) for (int dx=0;dx<16;dx+=4)
                occupied.insert({size,surfaceFloor(block.first.X*16+dx,size),
                        surfaceFloor(block.first.Z*16+dz,size)});
    auto sample = [&](int nx, int nz, int minimum) -> const SurfaceSample * {
        for (int step : {4, 8, 16, 64, 128}) {
            if (step < minimum) continue;
            const int cx = surfaceFloor(nx, step), cz = surfaceFloor(nz, step);
            auto it = tiles.find({step, surfaceFloor(cx, 16), surfaceFloor(cz, 16)});
            if (it == tiles.end()) continue;
            const auto &s = it->second->samples[(cz - it->first.z * 16) * 16 + cx - it->first.x * 16];
            if (s.known()) return &s;
        }
        return nullptr;
    };
    std::function<void(int, int, int)> visit = [&](int nx, int nz, int size) {
        const double distance = boxDistance(nx, nz, size, x, z);
        if (distance > radius || nx < -31000 || nz < -31000 || nx + size > 31000 ||
                nz + size > 31000) return;
        const SurfaceKey key{size, surfaceFloor(nx, size), surfaceFloor(nz, size)};
        const bool has_coverage = occupied.count(key);
        const int forest_cell=surfaceForestCell(distance);
        const int desired = forest_cell<=4 ? forest_cell*4 : distance<4096 ? 64 : 128;
        bool finer = false;
        if (size > desired) {
            // A partially arrived finer tile may replace its own footprint;
            // neighbours keep their parent until they too have data.
            for (int step : {4, 8, 16, 64}) {
                if (step < desired || step >= size) continue;
                const int width = step * 16;
                for (int tz = surfaceFloor(nz, width); tz <= surfaceFloor(nz + size - 1, width); ++tz)
                    for (int tx = surfaceFloor(nx, width); tx <= surfaceFloor(nx + size - 1, width); ++tx)
                        if (tiles.count({step, tx, tz})) finer = true;
            }
        }
        if ((size > 4 && (has_coverage || finer)) ||
                (size > 1 && exact_occupied.count(key))) {
            const int half = size / 2;
            for (int dz : {0, half}) for (int dx : {0, half}) visit(nx + dx, nz + dz, half);
            return;
        }
        auto exact=exact_coverage.find({nx,nz});
        if (size==1 && exact!=exact_coverage.end()) {
            const auto *s=sample(nx,nz,4);
            leaves.emplace(key,Leaf{nx,nz,size,s?*s:SurfaceSample{},true,exact->second});
            ++covered;
            return;
        }
        auto ci = coverage.find({surfaceFloor(nx, 4), surfaceFloor(nz, 4)});
        if (size <= 4 && ci != coverage.end()) {
            const auto *s = sample(nx + size / 2, nz + size / 2, 4);
            leaves.emplace(key, Leaf{nx, nz, size, s ? *s : SurfaceSample{}, true, ci->second});
            ++covered;
            return;
        }
        const auto *s = sample(nx + size / 2, nz + size / 2, std::min(size, desired));
        if (s) leaves.emplace(key, Leaf{nx, nz, size, *s, false, float(s->height + 1)});
    };
    for (int nz = surfaceFloor(z - radius, 128) * 128; nz <= z + radius; nz += 128)
        for (int nx = surfaceFloor(x - radius, 128) * 128; nx <= x + radius; nx += 128)
            visit(nx, nz, 128);
    auto neighbour = [&](int nx, int nz) -> const Leaf * {
        for (int size = 1; size <= 128; size *= 2) {
            auto it = leaves.find({size, surfaceFloor(nx, size), surfaceFloor(nz, size)});
            if (it != leaves.end()) return &it->second;
        }
        return nullptr;
    };
    std::map<SurfaceKey, std::map<std::pair<u32, bool>, size_t>> surface_indices;
    SurfaceKey chunk_key;

    auto quad = [&](content_t content, int side, const std::array<v3f, 4> &p, v3f n, uint8_t param2 = 0) {
        SurfaceChunk &chunk = chunks[chunk_key];
        auto &surfaces = surface_indices[chunk_key];
        auto &mesh = chunk.mesh;
        auto hash = [&](uint64_t value) {
            chunk.signature = (chunk.signature ^ value) * 1099511628211ULL;
        };
        hash(content); hash(side); hash(param2);
        for (const auto &v : p) {
            hash((int64_t)std::lround(v.X * 10));
            hash((int64_t)std::lround(v.Y * 10));
            hash((int64_t)std::lround(v.Z * 10));
        }
        const auto te = lodSurfaceTile(*tile_cache, ndef, tsrc, materials, content, side, param2);
        auto inserted = surfaces.emplace(std::make_pair(te.texture_id, te.liquid), mesh.surfaces.size());
        if (inserted.second) {
            mesh.surfaces.emplace_back();
            mesh.surfaces.back().texture_id = te.texture_id;
            mesh.surfaces.back().liquid = te.liquid;
        }
        LodSurface &sf = mesh.surfaces[inserted.first->second];
        const u32 base = sf.pos.size();
        for (const auto &v : p) {
            sf.pos.emplace_back(v.X, v.Y, -v.Z);
            sf.nrm.emplace_back(n.X, n.Y, -n.Z);
            sf.uv.emplace_back(side == 0 ? v.X : (side <= 3 ? v.Z : v.X),
                    side == 0 ? -v.Z : -v.Y);
            sf.uv2.emplace_back(te.layer, te.block_id);
            sf.col.push_back(te.texture_id ? te.tint : te.fallback);
            sf.custom0.insert(sf.custom0.end(), {0, 255, 255, 255});
        }
        // Mirroring Z changes handedness; Godot front faces are clockwise.
        const v3f cross = (p[1] - p[0]).crossProduct(p[2] - p[0]);
        if (cross.dotProduct(n) > 0)
            for (u32 i : {0u, 1u, 2u, 0u, 2u, 3u}) sf.idx.push_back(base + i);
        else
            for (u32 i : {0u, 2u, 1u, 0u, 3u, 2u}) sf.idx.push_back(base + i);
        ++result.quads;
        ++result.faces;
        ++mesh.quads;
        ++mesh.faces;
        mesh.max_span = chunk_key.step;
    };
    // Vertical runs retain exact crown outlines without expanding a forest
    // into millions of interior voxel records. Only exposed run faces are drawn.
    std::map<SurfaceKey, std::vector<ForestSpan>> forest_columns;
    struct ForestFace {
        SurfaceKey chunk;
        content_t content;
        uint8_t param2;
        int side;
        float plane, u0, v0, u1, v1;
    };
    std::vector<ForestFace> forest_faces;
    auto forest_face = [&](const ForestSpan &s, int side, float plane,
            float u0, float v0, float u1, float v1) {
        if (u1 > u0 && v1 > v0)
            forest_faces.push_back({chunk_key,s.content,s.param2,side,plane,u0,v0,u1,v1});
    };
    for (const auto &kv : leaves) {
        const Leaf &c = kv.second;
        if (!c.cut) ++cells;
        const double distance = boxDistance(c.x, c.z, c.size, x, z);
        const int chunk_size = distance < 768 ? 128 : distance < 2048 ? 512 : 1024;
        chunk_key = {chunk_size, surfaceFloor(c.x, chunk_size), surfaceFloor(c.z, chunk_size)};
        const float x0 = c.x, z0 = c.z, x1 = c.x + c.size, z1 = c.z + c.size;
        const float h = c.height;
        for (const auto &candidate : c.sample.forest)
        for (auto span : forestVisibleRuns(candidate,forest_blocks,
                candidate.size<=4?candidate.x:c.x,candidate.size<=4?candidate.z:c.z)) {
            if (span.content == CONTENT_AIR || span.content == CONTENT_IGNORE) continue;
            if (span.size <= 4) {
                if (span.x < c.x || span.x >= c.x+c.size || span.z < c.z || span.z >= c.z+c.size) continue;
                // Keep trunks rooted in the rendered terrain when the ground's
                // coarse sample is a little higher than the predicted root.
                span.bottom = std::max<int>(span.bottom, (int)h);
                if (span.top > span.bottom)
                    forest_columns[{span.size,span.x,span.z}].push_back(span);
            } else {
                // Statistical crowns are shallow floating slabs. Coverage
                // controls their footprint; ground stays at its own height.
                const float width = span.size * std::sqrt(span.coverage / 255.0f);
                const float inset = (span.size-width)*0.5f;
                const float fx0 = std::max(x0,span.x+inset), fz0 = std::max(z0,span.z+inset);
                const float fx1 = std::min(x1,span.x+span.size-inset), fz1 = std::min(z1,span.z+span.size-inset);
                const float bottom = std::max(h+1, float(span.bottom)), top = std::max(bottom+1,float(span.top));
                if (fx1<=fx0 || fz1<=fz0) continue;
                forest_face(span,0,top,fx0,fz0,fx1,fz1);
                forest_face(span,1,bottom,fx0,fz0,fx1,fz1);
                forest_face(span,2,fx1,fz0,bottom,fz1,top);
                forest_face(span,3,fx0,fz0,bottom,fz1,top);
                forest_face(span,4,fz1,fx0,bottom,fx1,top);
                forest_face(span,5,fz0,fx0,bottom,fx1,top);
            }
        }

        if (c.cut) continue;
        quad(c.sample.top, 0, {{{x0,h,z0}, {x1,h,z0}, {x1,h,z1}, {x0,h,z1}}}, {0,1,0});
        if (c.sample.water != CONTENT_AIR && c.sample.water != CONTENT_IGNORE &&
                c.sample.water_height >= c.sample.height) {
            const float wh = c.sample.water_height + 0.9f;
            quad(c.sample.water, 0, {{{x0,wh,z0}, {x1,wh,z0}, {x1,wh,z1}, {x0,wh,z1}}}, {0,1,0});
        }
        // Split only where a neighbour changes. This seals fine/coarse joins
        // without long skirts hanging below unknown terrain or into the sky.
        for (int edge = 0; edge < 4; ++edge) {
            for (int a = 0; a < c.size;) {
                const int nx = edge == 0 ? c.x + c.size : edge == 1 ? c.x - 1 : c.x + a;
                const int nz = edge == 2 ? c.z + c.size : edge == 3 ? c.z - 1 : c.z + a;
                const Leaf *other = neighbour(nx, nz);
                const int span = other ? std::min(c.size - a, other->size -
                        ((edge < 2 ? nz - other->z : nx - other->x) % other->size)) : 4;
                const int end = std::min(c.size, a + span);
                if (other && (h > other->height || (other->cut && h != other->height))) {
                    const float lo = std::min(h, other->height), hi = std::max(h, other->height);
                    v3f normal(edge == 0 ? 1 : edge == 1 ? -1 : 0, 0,
                            edge == 2 ? 1 : edge == 3 ? -1 : 0);
                    if (h < other->height) normal *= -1;
                    if (edge < 2) {
                        const float ex = edge == 0 ? x1 : x0;
                        quad(c.sample.side, edge + 2, {{{ex,lo,z0+a}, {ex,lo,z0+end},
                                {ex,hi,z0+end}, {ex,hi,z0+a}}}, normal);
                    } else {
                        const float ez = edge == 2 ? z1 : z0;
                        quad(c.sample.side, edge + 2, {{{x0+a,lo,ez}, {x0+end,lo,ez},
                                {x0+end,hi,ez}, {x0+a,hi,ez}}}, normal);
                    }
                }
                a = end;
            }
        }
    }
    for (auto &entry : forest_columns)
        std::sort(entry.second.begin(),entry.second.end(),[](const ForestSpan &a,const ForestSpan &b) {
            return a.bottom<b.bottom;
        });
    auto forest_at = [&](int nx, int nz) -> const std::vector<ForestSpan> * {
        for (int size : {1,2,4}) {
            auto it=forest_columns.find({size,surfaceFloor(nx,size)*size,surfaceFloor(nz,size)*size});
            if (it!=forest_columns.end()) return &it->second;
        }
        return nullptr;
    };
    for (const auto &entry : forest_columns) {
        const int fx=entry.first.x, fz=entry.first.z, size=entry.first.step;
        chunk_key={128,surfaceFloor(fx,128),surfaceFloor(fz,128)};
        const auto &runs=entry.second;
        for (size_t i=0;i<runs.size();++i) {
            const auto &s=runs[i];
            if (i+1==runs.size() || runs[i+1].bottom>s.top)
                forest_face(s,0,s.top,fx,fz,fx+size,fz+size);
            if (i==0 || runs[i-1].top<s.bottom)
                forest_face(s,1,s.bottom,fx,fz,fx+size,fz+size);
            for (int side=2;side<6;++side) {
              for (int edge=0;edge<size;++edge) {
                const int nx=side==2?fx+size:side==3?fx-1:fx+edge;
                const int nz=side==4?fz+size:side==5?fz-1:fz+edge;
                const auto *other=forest_at(nx,nz);
                int bottom=s.bottom;
                auto expose = [&](int lo,int hi) {
                    if (side<4) forest_face(s,side,fx+(side==2?size:0),fz+edge,lo,fz+edge+1,hi);
                    else forest_face(s,side,fz+(side==4?size:0),fx+edge,lo,fx+edge+1,hi);
                };
                if (other) for (const auto &n : *other) {
                    if (n.top<=bottom) continue;
                    if (n.bottom>=s.top) break;
                    expose(bottom,std::min<int>(n.bottom,s.top));
                    bottom=std::max<int>(bottom,n.top);
                    if (bottom>=s.top) break;
                }
                expose(bottom,s.top);
              }
            }
        }
    }
    // Greedy rectangles preserve one-node silhouettes and gaps while avoiding
    // a separate quad for every coplanar leaf block in a dense crown.
    for (bool vertical : {false,true}) {
        auto key = [vertical](const ForestFace &f) {
            return std::make_tuple(f.chunk.step,f.chunk.x,f.chunk.z,f.content,f.param2,f.side,f.plane,
                    vertical?f.u0:f.v0,vertical?f.u1:f.v1,vertical?f.v0:f.u0,vertical?f.v1:f.u1);
        };
        std::sort(forest_faces.begin(),forest_faces.end(),[&](const auto &a,const auto &b){return key(a)<key(b);});
        std::vector<ForestFace> merged;
        for (const auto &f : forest_faces) {
            if (!merged.empty()) {
                auto &p=merged.back();
                const bool same=p.chunk.step==f.chunk.step && p.chunk.x==f.chunk.x && p.chunk.z==f.chunk.z &&
                        p.content==f.content && p.param2==f.param2 && p.side==f.side && p.plane==f.plane;
                if (same && (vertical ? p.u0==f.u0 && p.u1==f.u1 && p.v1==f.v0 :
                        p.v0==f.v0 && p.v1==f.v1 && p.u1==f.u0)) {
                    if (vertical) p.v1=f.v1; else p.u1=f.u1;
                    continue;
                }
            }
            merged.push_back(f);
        }
        forest_faces=std::move(merged);
    }
    for (const auto &f : forest_faces) {
        chunk_key=f.chunk;
        const float p=f.plane,u0=f.u0,v0=f.v0,u1=f.u1,v1=f.v1;
        if (f.side<2)
            quad(f.content,f.side,{{{u0,p,v0},{u1,p,v0},{u1,p,v1},{u0,p,v1}}},
                    {0,f.side==0?1.f:-1.f,0},f.param2);
        else if (f.side<4)
            quad(f.content,f.side,{{{p,v0,u0},{p,v0,u1},{p,v1,u1},{p,v1,u0}}},
                    {f.side==2?1.f:-1.f,0,0},f.param2);
        else
            quad(f.content,f.side,{{{u0,v0,p},{u1,v0,p},{u1,v1,p},{u0,v1,p}}},
                    {0,0,f.side==4?1.f:-1.f},f.param2);
    }
    forest_quads = (int)forest_faces.size();
    forest_columns_count = (int)forest_columns.size();
    result.surface_cells = cells;
    result.max_span = 128;
}
} // namespace goanna
