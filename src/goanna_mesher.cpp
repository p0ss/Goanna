#include "goanna_mesher.h"

#include <cmath>
#include <cstdint>
#include <string>

#include "goanna_session.h"
#include "mapblock.h"
#include "mapnode.h"
#include "nodedef.h"

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
    return f.drawtype == NDT_NORMAL && !f.sunlight_propagates;
}

// Stable pseudo-colour from a texture/node name, HSV-ish.
void colourFor(const ContentFeatures &f, float *rgb) {
    const std::string &key = f.tiledef[0].name.empty() ? f.name : f.tiledef[0].name;
    uint32_t h = 2166136261u;
    for (unsigned char c : key) { h ^= c; h *= 16777619u; }
    float hue = (h % 360) / 360.0f;
    float sat = 0.35f + ((h >> 9) % 40) / 100.0f;
    float val = 0.55f + ((h >> 17) % 40) / 100.0f;
    // crude hints so the world reads at a glance
    if (key.find("water") != std::string::npos) { hue = 0.58f; sat = 0.6f; val = 0.9f; }
    else if (key.find("grass") != std::string::npos) { hue = 0.30f; sat = 0.6f; val = 0.75f; }
    else if (key.find("dirt") != std::string::npos) { hue = 0.08f; sat = 0.55f; val = 0.5f; }
    else if (key.find("stone") != std::string::npos) { hue = 0.0f; sat = 0.0f; val = 0.55f; }
    else if (key.find("sand") != std::string::npos) { hue = 0.13f; sat = 0.35f; val = 0.9f; }
    else if (key.find("leaves") != std::string::npos) { hue = 0.33f; sat = 0.7f; val = 0.45f; }
    else if (key.find("tree") != std::string::npos || key.find("wood") != std::string::npos) { hue = 0.09f; sat = 0.6f; val = 0.4f; }
    else if (key.find("lava") != std::string::npos) { hue = 0.06f; sat = 0.9f; val = 1.0f; }
    else if (key.find("snow") != std::string::npos || key.find("ice") != std::string::npos) { hue = 0.55f; sat = 0.05f; val = 1.0f; }
    // hsv -> rgb
    float i = std::floor(hue * 6), fr = hue * 6 - i;
    float p = val * (1 - sat), q = val * (1 - fr * sat), t = val * (1 - (1 - fr) * sat);
    switch ((int)i % 6) {
    case 0: rgb[0] = val; rgb[1] = t; rgb[2] = p; break;
    case 1: rgb[0] = q; rgb[1] = val; rgb[2] = p; break;
    case 2: rgb[0] = p; rgb[1] = val; rgb[2] = t; break;
    case 3: rgb[0] = p; rgb[1] = q; rgb[2] = val; break;
    case 4: rgb[0] = t; rgb[1] = p; rgb[2] = val; break;
    default: rgb[0] = val; rgb[1] = p; rgb[2] = q; break;
    }
}

struct Ctx {
    MeshData &out;
    void quad(const float (&v)[4][3], const float n[3], const float rgb[3], float shade) {
        int32_t base = out.positions.size() / 3;
        for (int k = 0; k < 4; ++k) {
            // Luanti (x, y, z) -> Godot (x, y, -z)
            out.positions.push_back(v[k][0]);
            out.positions.push_back(v[k][1]);
            out.positions.push_back(-v[k][2]);
            out.normals.push_back(n[0]);
            out.normals.push_back(n[1]);
            out.normals.push_back(-n[2]);
            out.colors.push_back(rgb[0] * shade);
            out.colors.push_back(rgb[1] * shade);
            out.colors.push_back(rgb[2] * shade);
            out.colors.push_back(1.0f);
        }
        // Faces are CCW-from-outside in Luanti's left-handed space; mirroring z
        // makes that clockwise in Godot, which is Godot's front-face winding.
        out.indices.push_back(base + 0); out.indices.push_back(base + 1); out.indices.push_back(base + 2);
        out.indices.push_back(base + 0); out.indices.push_back(base + 2); out.indices.push_back(base + 3);
    }
};

// Face tables in Luanti space; CCW when viewed from outside.
const int DIRS[6][3] = {{0,1,0},{0,-1,0},{1,0,0},{-1,0,0},{0,0,1},{0,0,-1}};
const float SHADE[6] = {1.0f, 0.55f, 0.8f, 0.8f, 0.7f, 0.7f};

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

} // namespace

MeshData meshBlock(GoannaSession &session, MapBlock *block) {
    MeshData out;
    const NodeDefManager *ndef = session.nodeDefs();
    const v3s16 bp = block->getPos();
    const int BS16 = MAP_BLOCKSIZE;
    Ctx ctx{out};

    auto nodeAt = [&](int x, int y, int z, bool &ok) -> MapNode {
        // x,y,z relative to this block; may step into neighbours
        int bx = 0, by = 0, bz = 0;
        if (x < 0) { bx = -1; x += BS16; } else if (x >= BS16) { bx = 1; x -= BS16; }
        if (y < 0) { by = -1; y += BS16; } else if (y >= BS16) { by = 1; y -= BS16; }
        if (z < 0) { bz = -1; z += BS16; } else if (z >= BS16) { bz = 1; z -= BS16; }
        MapBlock *b = block;
        if (bx || by || bz) {
            b = session.getBlock(bp + v3s16(bx, by, bz));
            if (!b) { ok = false; return MapNode(CONTENT_AIR); }
        }
        ok = true;
        return b->getNodeNoCheck(x, y, z);
    };

    for (int z = 0; z < BS16; ++z)
    for (int y = 0; y < BS16; ++y)
    for (int x = 0; x < BS16; ++x) {
        MapNode n = block->getNodeNoCheck(x, y, z);
        const ContentFeatures &f = ndef->get(n);
        Kind k = classify(f);
        if (k == Kind::Air || k == Kind::Skip)
            continue;
        float rgb[3];
        colourFor(f, rgb);
        float wx = bp.X * BS16 + x, wy = bp.Y * BS16 + y, wz = bp.Z * BS16 + z;
        if (k == Kind::Cross) {
            float v[4][3];
            float n1[3] = {0.7f, 0, -0.7f};
            v[0][0]=wx; v[0][1]=wy; v[0][2]=wz; v[1][0]=wx+1; v[1][1]=wy; v[1][2]=wz+1;
            v[2][0]=wx+1; v[2][1]=wy+1; v[2][2]=wz+1; v[3][0]=wx; v[3][1]=wy+1; v[3][2]=wz;
            ctx.quad(v, n1, rgb, 0.85f);
            float n2[3] = {-0.7f, 0, -0.7f};
            v[0][0]=wx+1; v[0][1]=wy; v[0][2]=wz; v[1][0]=wx; v[1][1]=wy; v[1][2]=wz+1;
            v[2][0]=wx; v[2][1]=wy+1; v[2][2]=wz+1; v[3][0]=wx+1; v[3][1]=wy+1; v[3][2]=wz;
            ctx.quad(v, n2, rgb, 0.85f);
            continue;
        }
        for (int d = 0; d < 6; ++d) {
            bool ok;
            MapNode nb = nodeAt(x + DIRS[d][0], y + DIRS[d][1], z + DIRS[d][2], ok);
            if (ok) {
                const ContentFeatures &fb = ndef->get(nb);
                if (isOpaque(fb))
                    continue;
                if (nb.getContent() == n.getContent() && k == Kind::Cube && classify(fb) == Kind::Cube
                        && f.drawtype != NDT_NORMAL)
                    continue; // merge same liquid/glass volumes
            }
            float v[4][3];
            faceVerts(d, wx, wy, wz, v);
            float nn[3] = {(float)DIRS[d][0], (float)DIRS[d][1], (float)DIRS[d][2]};
            ctx.quad(v, nn, rgb, SHADE[d]);
        }
    }
    return out;
}

} // namespace goanna
