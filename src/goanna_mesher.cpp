#include "goanna_mesher.h"

#include <map>

#include "goanna_session.h"
#include "mapblock.h"
#include "mapnode.h"

namespace goanna {

namespace {

enum class Kind : uint8_t { Air, Cube, Cross, Skip };

Kind classify(const ContentFeatures &f) {
    switch (f.drawtype) {
    case NDT_AIRLIKE:
        return Kind::Air;
    case NDT_NORMAL:
    case NDT_LIQUID:
    case NDT_FLOWINGLIQUID:
    case NDT_GLASSLIKE:
    case NDT_GLASSLIKE_FRAMED:
    case NDT_GLASSLIKE_FRAMED_OPTIONAL:
    case NDT_ALLFACES:
    case NDT_ALLFACES_OPTIONAL:
    case NDT_NODEBOX:
    case NDT_MESH:
        return Kind::Cube;
    case NDT_PLANTLIKE:
    case NDT_PLANTLIKE_ROOTED:
    case NDT_FIRELIKE:
        return Kind::Cross;
    default:
        return Kind::Skip;
    }
}

bool isOpaque(const ContentFeatures &f) {
    return f.drawtype == NDT_NORMAL && !f.sunlight_propagates && f.alpha == ALPHAMODE_OPAQUE;
}

// Luanti tile order and our DIRS order agree: +Y, -Y, +X, -X, +Z, -Z.
const int DIRS[6][3] = {{0,1,0},{0,-1,0},{1,0,0},{-1,0,0},{0,0,1},{0,0,-1}};

void faceVerts(int d, float x, float y, float z, float (&v)[4][3]) {
    auto set = [&](int k, float a, float b, float c) { v[k][0] = a; v[k][1] = b; v[k][2] = c; };
    switch (d) {
    case 0: set(0,x,y+1,z+1); set(1,x+1,y+1,z+1); set(2,x+1,y+1,z); set(3,x,y+1,z); break;      // +Y
    case 1: set(0,x,y,z); set(1,x+1,y,z); set(2,x+1,y,z+1); set(3,x,y,z+1); break;              // -Y
    case 2: set(0,x+1,y,z+1); set(1,x+1,y,z); set(2,x+1,y+1,z); set(3,x+1,y+1,z+1); break;      // +X
    case 3: set(0,x,y,z); set(1,x,y,z+1); set(2,x,y+1,z+1); set(3,x,y+1,z); break;              // -X
    case 4: set(0,x,y,z+1); set(1,x+1,y,z+1); set(2,x+1,y+1,z+1); set(3,x,y+1,z+1); break;      // +Z
    default: set(0,x+1,y,z); set(1,x,y,z); set(2,x,y+1,z); set(3,x+1,y+1,z); break;             // -Z
    }
}

// UVs matching faceVerts vertex order: for side faces the first two verts are
// the bottom edge, so v=1 there (image top at node top).
const float UV_TOP[4][2]  = {{0,0},{1,0},{1,1},{0,1}};
const float UV_SIDE[4][2] = {{0,1},{1,1},{1,0},{0,0}};

struct Builder {
    std::map<std::string, size_t> index; // key -> surface slot
    MeshData &out;
    explicit Builder(MeshData &o) : out(o) {}

    SurfaceData &surface(const TileDef &tile, AlphaMode alpha, bool double_sided) {
        std::string key = tile.name + (double_sided ? "|x" : "|c") + std::to_string((int)alpha);
        auto it = index.find(key);
        if (it != index.end())
            return out.surfaces[it->second];
        out.surfaces.emplace_back();
        SurfaceData &s = out.surfaces.back();
        s.tex = tile.name;
        s.animation = tile.animation;
        s.alpha = alpha;
        s.double_sided = double_sided;
        index[key] = out.surfaces.size() - 1;
        return s;
    }

    void quad(SurfaceData &s, const float (&v)[4][3], const float n[3], const float (&uv)[4][2],
            const float rgba[4]) {
        int32_t base = s.positions.size() / 3;
        for (int k = 0; k < 4; ++k) {
            // Luanti (x, y, z) -> Godot (x, y, -z)
            s.positions.insert(s.positions.end(), {v[k][0], v[k][1], -v[k][2]});
            s.normals.insert(s.normals.end(), {n[0], n[1], -n[2]});
            s.uvs.insert(s.uvs.end(), {uv[k][0], uv[k][1]});
            s.colors.insert(s.colors.end(), {rgba[0], rgba[1], rgba[2], rgba[3]});
        }
        // CCW-from-outside in Luanti's left-handed space becomes clockwise
        // after mirroring z, which is Godot's front-face winding.
        s.indices.insert(s.indices.end(), {base, base + 1, base + 2, base, base + 2, base + 3});
    }
};

} // namespace

MeshData meshBlock(GoannaSession &session, MapBlock *block) {
    MeshData out;
    Builder b(out);
    const NodeDefManager *ndef = session.nodeDefs();
    const v3s16 bp = block->getPos();
    const int BS16 = MAP_BLOCKSIZE;

    auto nodeAt = [&](int x, int y, int z, bool &ok) -> MapNode {
        int bx = 0, by = 0, bz = 0;
        if (x < 0) { bx = -1; x += BS16; } else if (x >= BS16) { bx = 1; x -= BS16; }
        if (y < 0) { by = -1; y += BS16; } else if (y >= BS16) { by = 1; y -= BS16; }
        if (z < 0) { bz = -1; z += BS16; } else if (z >= BS16) { bz = 1; z -= BS16; }
        MapBlock *blk = block;
        if (bx || by || bz) {
            blk = session.getBlock(bp + v3s16(bx, by, bz));
            if (!blk) { ok = false; return MapNode(CONTENT_AIR); }
        }
        ok = true;
        return blk->getNodeNoCheck(x, y, z);
    };

    for (int z = 0; z < BS16; ++z)
    for (int y = 0; y < BS16; ++y)
    for (int x = 0; x < BS16; ++x) {
        MapNode n = block->getNodeNoCheck(x, y, z);
        const ContentFeatures &f = ndef->get(n);
        Kind k = classify(f);
        if (k == Kind::Air || k == Kind::Skip)
            continue;
        float rgba[4] = {f.color.getRed() / 255.0f, f.color.getGreen() / 255.0f,
                f.color.getBlue() / 255.0f, 1.0f};
        float wx = bp.X * BS16 + x, wy = bp.Y * BS16 + y, wz = bp.Z * BS16 + z;
        if (k == Kind::Cross) {
            SurfaceData &s = b.surface(f.tiledef[0], f.alpha == ALPHAMODE_OPAQUE ? ALPHAMODE_CLIP : f.alpha, true);
            float v[4][3];
            float n1[3] = {0.7f, 0, -0.7f};
            v[0][0]=wx; v[0][1]=wy; v[0][2]=wz; v[1][0]=wx+1; v[1][1]=wy; v[1][2]=wz+1;
            v[2][0]=wx+1; v[2][1]=wy+1; v[2][2]=wz+1; v[3][0]=wx; v[3][1]=wy+1; v[3][2]=wz;
            b.quad(s, v, n1, UV_SIDE, rgba);
            float n2[3] = {-0.7f, 0, -0.7f};
            v[0][0]=wx+1; v[0][1]=wy; v[0][2]=wz; v[1][0]=wx; v[1][1]=wy; v[1][2]=wz+1;
            v[2][0]=wx; v[2][1]=wy+1; v[2][2]=wz+1; v[3][0]=wx+1; v[3][1]=wy+1; v[3][2]=wz;
            b.quad(s, v, n2, UV_SIDE, rgba);
            continue;
        }
        for (int d = 0; d < 6; ++d) {
            bool ok;
            MapNode nb = nodeAt(x + DIRS[d][0], y + DIRS[d][1], z + DIRS[d][2], ok);
            if (ok) {
                const ContentFeatures &fb = ndef->get(nb);
                if (isOpaque(fb))
                    continue;
                if (nb.getContent() == n.getContent() && f.drawtype != NDT_NORMAL)
                    continue; // merge same liquid/glass/leaf volumes
                if (f.drawtype == NDT_LIQUID || f.drawtype == NDT_FLOWINGLIQUID) {
                    // liquid against liquid of the other flavour: skip too
                    if (fb.drawtype == NDT_LIQUID || fb.drawtype == NDT_FLOWINGLIQUID)
                        continue;
                }
            }
            SurfaceData &s = b.surface(f.tiledef[d], f.alpha, false);
            float v[4][3];
            faceVerts(d, wx, wy, wz, v);
            float nn[3] = {(float)DIRS[d][0], (float)DIRS[d][1], (float)DIRS[d][2]};
            b.quad(s, v, nn, d < 2 ? UV_TOP : UV_SIDE, rgba);
        }
    }
    return out;
}

} // namespace goanna
