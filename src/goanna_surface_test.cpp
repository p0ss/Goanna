// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_surface.h"
#include "goanna_fine.h"
#include "nodedef.h"
#include "util/base64.h"
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <zlib.h>

using namespace goanna;
static void expect(bool ok, const char *message) {
    if (!ok) { std::cerr << message << '\n'; std::abort(); }
}
static std::shared_ptr<SurfaceTile> tile(int step, int x, int z, int height) {
    auto out = std::make_shared<SurfaceTile>();
    out->key = {step, x, z};
    for (auto &sample : out->samples)
        sample = {(int16_t)height, -32768, CONTENT_UNKNOWN, CONTENT_UNKNOWN, CONTENT_AIR};
    return out;
}
static double area(const SurfaceJob &job) {
    double out = 0;
    for (const auto &chunk : job.chunks)
    for (const auto &sf : chunk.second.mesh.surfaces)
        for (size_t i = 0; i < sf.pos.size(); i += 4) {
            const auto normal = sf.nrm[i];
            expect(std::abs(normal.X) + std::abs(normal.Y) + std::abs(normal.Z) == 1,
                    "baked surface contains a diagonal face");
            if (normal.Y != 1) continue;
            out += (sf.pos[i + 1] - sf.pos[i]).crossProduct(sf.pos[i + 3] - sf.pos[i]).getLength();
        }
    return out;
}
int main() {
    expect(surfaceFloor(-1, 16) == -1 && surfaceFloor(-16, 16) == -1 &&
            surfaceFloor(-17, 16) == -2, "negative tile coordinates truncate towards zero");
    const auto wanted = surfaceWanted(-100, 200, 8192);
    expect(wanted.size() < 1024, "tile request set exceeds the resident bound");
    int last = 128;
    for (const auto &key : wanted) {
        expect(key.step <= last || (last <= 16 && key.step <= 16), "refinement scheduled ahead of overview");
        last = key.step;
    }
    std::string raw;
    for (int i = 0; i < 256; ++i) raw += std::string("\xff\xf6\x00\x05\x01\x01\x01", 7);
    const std::string prefix = "surface player 1 abc 128 -1 0 stone|";
    const auto resolve = [](const std::string &) { return CONTENT_UNKNOWN; };
    SurfaceTile decoded;
    expect(decodeSurface(prefix + base64_encode(raw), "player", "abc", resolve, decoded),
            "valid tile rejected");
    expect(decoded.samples[0].height == -10 && decoded.samples[0].water_height == 5,
            "signed height or independent water level lost");
    expect(!decodeSurface(prefix + base64_encode(raw), "other", "abc", resolve, decoded),
            "another player's tile accepted");
    expect(!decodeSurface(prefix + base64_encode(raw), "player", "old", resolve, decoded),
            "stale bake accepted");
    expect(!decodeSurface(prefix + base64_encode(raw) + "A", "player", "abc", resolve, decoded),
            "oversized payload accepted");
    expect(!decodeSurface("surface player 1 abc 128 -2147483648 0 stone|" +
            base64_encode(raw), "player", "abc", resolve, decoded),
            "overflowing coordinate accepted");
    raw[4] = 2;
    expect(!decodeSurface(prefix + base64_encode(raw), "player", "abc", resolve, decoded),
            "out-of-range palette index accepted");

    auto compressed = [](const std::string &bytes) {
        uLongf size=compressBound(bytes.size());
        std::string out(size,'\0');
        expect(compress2(reinterpret_cast<Bytef *>(out.data()),&size,
                reinterpret_cast<const Bytef *>(bytes.data()),bytes.size(),6)==Z_OK,"compression failed");
        out.resize(size);
        return base64_encode(out);
    };
    SurfaceAssembler assembler;
    const auto wanted_part=[](const SurfaceKey &k){return k.step==4 && k.x==0 && k.z==0;};
    std::string assembled;
    const std::string part_header="surface_part player 2 abc 4 0 0 ";
    expect(!assembler.accept(part_header+"1 2 second","player","abc",wanted_part,assembled),
            "incomplete surface tile was published");
    expect(!assembler.accept(part_header+"1 2 second","player","abc",wanted_part,assembled),
            "duplicate surface part completed the tile");
    expect(assembler.accept(part_header+"0 2 first","player","abc",wanted_part,assembled) &&
            assembled=="surface player 2 abc 4 0 0 firstsecond","out-of-order parts lost data");
    expect(!assembler.accept(part_header+"0 129 bad","player","abc",wanted_part,assembled),
            "unbounded part count accepted");
    expect(!assembler.accept(part_header+"0 2 stale","player","new",wanted_part,assembled),
            "old revision allocated an assembly");
    expect(!assembler.accept(part_header+"0 2 unsolicited","player","abc",
            [](const SurfaceKey&){return false;},assembled),"unsolicited tile allocated an assembly");
    FineBlock fine;
    const std::string fine_prefix="farfine player 1 99 -2 3 4 air|";
    const std::string air_run("\x10\x00\x00\x01\xaf\x07",6);
    expect(decodeFineBlock(fine_prefix+compressed(air_run),"player",
            [](const std::string &) {return CONTENT_AIR;},fine),"valid detailed block rejected");
    expect(fine.available && fine.nodes.size()==4096 && fine.position==v3s16(-2,3,4) &&
            fine.nodes[0].param1==175 && fine.nodes[4095].param2==7,"detailed nodes lost lighting or params");
    expect(!decodeFineBlock(fine_prefix+compressed(air_run+air_run),"player",resolve,fine),
            "oversized detailed node runs accepted");
    expect(!decodeFineBlock(fine_prefix+compressed(air_run),"other",resolve,fine),
            "another player's fine block accepted");
    expect(decodeFineBlock("farfine player 1 100 0 0 0 -","player",resolve,fine) &&
            !fine.available && fine.nodes.empty(),"unavailable detailed block became air");
    ForestSpan crown{1,1,12,22,CONTENT_UNKNOWN,0,1,255};
    auto remaining=forestVisibleRuns(crown,{{v3s16(0,0,0),1}},1,1);
    expect(remaining.size()==1 && remaining[0].bottom==16 && remaining[0].top==22,
            "ground block erased the crown in the block above it");
    expect(forestVisibleRuns(crown,{{v3s16(0,0,0),1},{v3s16(0,1,0),1}},1,1).empty(),
            "authoritative empty blocks retained a removed tree");
    remaining=forestVisibleRuns(crown,{{v3s16(0,0,0),4}},1,1);
    expect(remaining.size()==1 && remaining[0].bottom==12,
            "coarse summary downgraded a detailed preview");
    expect(surfaceForestCell(511)==1 && surfaceForestCell(512)==2 &&
            surfaceForestCell(1023)==2 && surfaceForestCell(1024)==4 &&
            surfaceForestCell(2047)==4,"shared forest ladder narrowed a detail band");
    raw[4]=1;
    std::string forest_raw=raw+std::string("\x00\x01\x00\x02\x00\x14\x00\x18\x01\x07\x01\xff",12);
    const std::string forest_prefix="surface player 2 abc 4 -1 0 leaves|";
    expect(decodeSurface(forest_prefix+compressed(forest_raw),"player","abc",resolve,decoded),
            "valid compressed forest rejected");
    const auto &span=decoded.samples[0].forest.at(0);
    expect(span.x==-63 && span.z==2 && span.bottom==20 && span.top==24 && span.param2==7,
            "forest position, vertical bounds or palette parameter lost");
    auto malformed=forest_raw;
    malformed[256*7+10]=3;
    expect(!decodeSurface(forest_prefix+compressed(malformed),"player","abc",resolve,decoded),
            "unsupported forest footprint accepted");
    expect(!decodeSurface(forest_prefix+compressed(std::string(8*1024*1024+1,'x')),
            "player","abc",resolve,decoded),"unbounded compressed forest accepted");

    NodeDefManager ndef;
    expect(decodeFineBlock(fine_prefix+compressed(air_run),"player",
            [](const std::string &) {return CONTENT_AIR;},fine),"air fixture failed");
    auto empty_chain=buildFineChain(fine,&ndef);
    expect(empty_chain && empty_chain->hasCell(1) && !empty_chain->filledAt(1,0,0,0),
            "actual empty block lost its fine authority");
    LodTileCache cache;
    SurfaceJob coarse;
    coarse.ndef = &ndef; coarse.tile_cache = &cache;
    coarse.x = coarse.z = 256; coarse.radius = 256;
    coarse.tiles[{128, 0, 0}] = tile(128, 0, 0, 10);
    coarse.run();
    const double original = area(coarse);
    expect(original > 0, "overview produced no ground");
    SurfaceJob refined;
    refined.ndef = &ndef; refined.tile_cache = &cache;
    refined.x = refined.z = 256; refined.radius = 256;
    refined.tiles = coarse.tiles;
    refined.tiles[{4, 4, 4}] = tile(4, 4, 4, 25);
    refined.run();
    expect(area(refined) == original, "partial refinement opened a hole or overlapped its parent");
    for (const auto &chunk : refined.chunks)
    for (const auto &sf : chunk.second.mesh.surfaces)
        for (const auto &p : sf.pos)
            expect(p.Y >= 11 && p.Y <= 26, "join skirt invented a vertical curtain");
    // A single real ground column must remove one square node, not the
    // complete four-node preview sample its coarse mip happens to occupy.
    auto narrow=std::make_shared<BlockLodChain>();
    auto &narrow_level=narrow->level[0];
    narrow_level.cell=1;narrow_level.n=16;narrow_level.cells.resize(4096);
    auto &ground=narrow_level.at(0,0,0);
    ground.flags=LodLevel::kFilled|LodLevel::kKnown;
    for (auto &face:ground.face) face=CONTENT_UNKNOWN;
    buildLodMipLevels(*narrow,0);buildLodTerrainSurface(&ndef,*narrow,0);
    compactLodFineBoundary(*narrow);
    SurfaceJob narrow_job;
    narrow_job.ndef=&ndef;narrow_job.tile_cache=&cache;
    narrow_job.x=narrow_job.z=256;narrow_job.radius=256;narrow_job.tiles=coarse.tiles;
    narrow_job.sources.push_back({v3s16(16,0,16),1,narrow});
    narrow_job.run();
    expect(area(narrow_job)==original-1,"fine ground removed a coarse square of fallback");
    SurfaceJob not_drawn;
    not_drawn.ndef=&ndef;not_drawn.tile_cache=&cache;not_drawn.x=not_drawn.z=256;
    not_drawn.radius=256;not_drawn.tiles=coarse.tiles;
    not_drawn.sources.push_back({v3s16(16,0,16),1,narrow,false});
    not_drawn.run();
    expect(area(not_drawn)==original,"source occupancy erased ground without an emitted replacement");
    SurfaceJob drawn;
    drawn.ndef=&ndef;drawn.tile_cache=&cache;drawn.x=drawn.z=256;
    drawn.radius=256;drawn.tiles=coarse.tiles;
    drawn.sources=not_drawn.sources;drawn.ground.push_back({256,256,1,1});drawn.run();
    expect(area(drawn)==original-1,"published ground did not remove exactly its emitted face");
    SurfaceJob offset;
    offset.ndef = &ndef; offset.tile_cache = &cache;
    offset.x = offset.z = 256; offset.radius = 256;
    offset.tiles = coarse.tiles;
    offset.tiles[{4, 5, 5}] = tile(4, 5, 5, 25);
    offset.run();
    double raised = 0;
    for (const auto &chunk : offset.chunks)
        for (const auto &sf : chunk.second.mesh.surfaces)
            for (size_t i = 0; i < sf.pos.size(); i += 4)
                if (sf.nrm[i].Y == 1 && sf.pos[i].Y == 26)
                    raised += (sf.pos[i + 1] - sf.pos[i]).crossProduct(
                            sf.pos[i + 3] - sf.pos[i]).getLength();
    expect(raised == 64 * 64, "out-of-order fine tile spread beyond its own footprint");
    expect(area(offset) == original, "offset refinement opened a coverage gap");
    auto unknown = tile(128, 0, 0, 0);
    unknown->samples[0].top = CONTENT_IGNORE;
    expect(!unknown->complete(), "unknown tile counted as a complete horizon");
    SurfaceJob masked;
    masked.ndef = &ndef; masked.tile_cache = &cache;
    masked.x = masked.z = 256; masked.radius = 256;
    masked.tiles = refined.tiles;
    masked.coverage[{64, 64}] = 20;
    masked.run();
    expect(area(masked) == original - 16,
            "published coverage removed more than its own four-node footprint");
    expect(masked.covered == 1, "coverage count incorrect");
    auto forest_tile=tile(4,0,0,10);
    auto &tree=forest_tile->samples[0].forest;
    tree.push_back({2,2,11,15,CONTENT_UNKNOWN,0,1,255});
    for (int z=1;z<=3;++z) for (int x=1;x<=3;++x)
        if (x!=1 || z!=1) tree.push_back({(int16_t)x,(int16_t)z,15,16,CONTENT_UNKNOWN,0,1,255});
    SurfaceJob forest_job;
    forest_job.ndef=&ndef; forest_job.tile_cache=&cache;
    forest_job.x=forest_job.z=32; forest_job.radius=64;
    forest_job.tiles[{4,0,0}]=forest_tile;
    forest_job.run();
    expect(forest_job.forest_columns_count==8 && forest_job.forest_quads>0,
            "forest runs lost their crown footprint");
    double canopy_area=0;
    for (const auto &chunk:forest_job.chunks) for (const auto &sf:chunk.second.mesh.surfaces)
        for (size_t i=0;i<sf.pos.size();i+=4) if (sf.nrm[i].Y==1 && sf.pos[i].Y==16)
            canopy_area+=(sf.pos[i+1]-sf.pos[i]).crossProduct(sf.pos[i+3]-sf.pos[i]).getLength();
    expect(canopy_area==8,"greedy meshing filled a crown opening or removed an overhang");
    SurfaceJob visited;
    visited.ndef=&ndef; visited.tile_cache=&cache;
    visited.x=visited.z=32; visited.radius=64;
    visited.tiles=forest_job.tiles; visited.coverage[{0,0}]=11; visited.forest_blocks[{0,0,0}]=1;
    visited.run();
    expect(visited.forest_quads==0,"predicted forest overlaps published terrain coverage");
    SurfaceJob ground_only;
    ground_only.ndef=&ndef; ground_only.tile_cache=&cache;
    ground_only.x=ground_only.z=32; ground_only.radius=64;
    ground_only.tiles=forest_job.tiles; ground_only.coverage[{0,0}]=11;
    ground_only.run();
    expect(ground_only.forest_quads==forest_job.forest_quads,
            "ground-only summary erased the forest preview");
    auto mixed_tile=tile(4,0,0,10);
    mixed_tile->samples[0].forest={
        {0,0,11,15,CONTENT_UNKNOWN,0,2,255},
        {2,0,11,15,CONTENT_UNKNOWN,0,1,255},
        {2,1,11,15,CONTENT_UNKNOWN,0,1,255}};
    SurfaceJob mixed;
    mixed.ndef=&ndef; mixed.tile_cache=&cache;
    mixed.x=mixed.z=32; mixed.radius=64; mixed.tiles[{4,0,0}]=mixed_tile;
    mixed.run();
    double mixed_top=0;
    for (const auto &chunk:mixed.chunks) for (const auto &sf:chunk.second.mesh.surfaces)
        for (size_t i=0;i<sf.pos.size();i+=4) {
            expect(!(sf.nrm[i].X!=0 && sf.pos[i].X==2 && sf.pos[i].Y>=11),
                    "mixed tree cells left a face inside their shared boundary");
            if (sf.nrm[i].Y==1 && sf.pos[i].Y==15)
                mixed_top+=(sf.pos[i+1]-sf.pos[i]).crossProduct(sf.pos[i+3]-sf.pos[i]).getLength();
        }
    expect(mixed_top==6,"mixed tree cells changed the crown footprint");
    auto canopy_tile=tile(16,0,0,10);
    canopy_tile->samples[0].forest.push_back({0,0,21,25,CONTENT_UNKNOWN,0,16,64});
    SurfaceJob canopy;
    canopy.ndef=&ndef; canopy.tile_cache=&cache;
    canopy.x=canopy.z=32; canopy.radius=64; canopy.tiles[{16,0,0}]=canopy_tile;
    canopy.run();
    expect(canopy.forest_quads==6,"coarse canopy did not retain an independent floating volume");
    double crown_area=0;
    for (const auto &chunk:canopy.chunks) for (const auto &sf:chunk.second.mesh.surfaces)
        for (size_t i=0;i<sf.pos.size();i+=4) {
            if (sf.nrm[i].Y==1 && sf.pos[i].Y==25)
                crown_area+=(sf.pos[i+1]-sf.pos[i]).crossProduct(sf.pos[i+3]-sf.pos[i]).getLength();
            if (sf.pos[i].Y>11 && sf.nrm[i].Y==0)
                for (size_t j=i;j<i+4;++j) expect(sf.pos[j].Y>=21,"canopy side became a wall down to ground");
        }
    expect(crown_area>60 && crown_area<70,"coarse forest ignored its coverage fraction");
    std::cout << "goanna_surface_test: PASS\n";
}
