// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_lava.h"
#include "goanna_session.h"
#include "mapblock.h"
#include "nodedef.h"
#include "IImage.h"
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <algorithm>
#include <cmath>
#include <map>
#include <vector>

namespace goanna {
using namespace godot;
void configureLavaMaterial(const Ref<ShaderMaterial> &material, video::IImage *image) {
    if (!image)
        return;
    const auto size = image->getDimension();
    if (!size.Width || !size.Height)
        return;
    auto linear = [](u32 c) {
        const float v = c/255.0f;
        return v <= 0.04045f ? v/12.92f : std::pow((v+0.055f)/1.055f, 2.4f);
    };
    std::vector<float> values;
    const u32 nx = std::min(64u, size.Width), ny = std::min(64u, size.Height);
    for (u32 y = 0; y < ny; ++y)
        for (u32 x = 0; x < nx; ++x) {
            const auto c = image->getPixel(x*size.Width/nx, y*size.Height/ny);
            values.push_back(0.2126f*linear(c.getRed()) + 0.7152f*linear(c.getGreen())
                    + 0.0722f*linear(c.getBlue()));
        }
    std::sort(values.begin(), values.end());
    auto percentile = [&](float p) { return values[(size_t)(p*(values.size()-1))]; };
    const float low = percentile(0.20f), high = std::max(low+0.015f, percentile(0.80f));
    // A nearly uniform or wholly bright tile should not acquire invented
    // islands. Otherwise use its own range, not Minetest Game's palette.
    const float contrast = std::clamp((percentile(0.95f)-percentile(0.05f)-0.015f)/0.06f, 0.0f, 1.0f);
    const float cool = 1.0f-std::clamp((low-0.20f)/0.25f, 0.0f, 1.0f);
    material->set_shader_parameter("crust_range", Vector2(low,high));
    material->set_shader_parameter("crust_strength", contrast*cool);
}
namespace {
// Node-centred velocities, interpolated in world space. Faces on opposite
// sides of a mapblock boundary therefore ask exactly the same field.
class LavaFlow {
    GoannaSession &session;
    const NodeDefManager *ndef;
    std::map<v3s16, Vector3> cache;
    std::map<v3s16, bool> liquid_cache;

    MapNode node(v3s16 p) {
        v3s16 bp = getNodeBlockPos(p);
        MapBlock *block = session.getBlock(bp);
        return block ? block->getNodeNoCheck(p - bp * MAP_BLOCKSIZE)
                     : MapNode(CONTENT_IGNORE);
    }
    float level(MapNode n, float fallback) {
        const auto &f = ndef->get(n);
        if (!f.isLiquid())
            return f.walkable || n.getContent() == CONTENT_IGNORE ? fallback : -0.5f;
        if (f.liquid_type == LIQUID_SOURCE)
            return 0.5f;
        int range = std::clamp((int)f.liquid_range, 1, 8);
        int amount = std::max(0, (n.param2 & LIQUID_LEVEL_MASK) - (8 - range));
        return -0.5f + (amount + 0.5f) / range;
    }
    Vector3 at(v3s16 p) {
        auto found = cache.find(p);
        if (found != cache.end())
            return found->second;
        MapNode n = node(p);
        const auto &f = ndef->get(n);
        Vector3 v;
        if (f.isLiquid() && f.light_source >= 6) {
            float h = level(n, 0.5f);
            v.x = level(node(p + v3s16(-1,0,0)), h)
                    - level(node(p + v3s16(1,0,0)), h);
            // Godot's Z is mirrored against Luanti's.
            v.z = level(node(p + v3s16(0,0,1)), h)
                    - level(node(p + v3s16(0,0,-1)), h);
            const auto &below = ndef->get(node(p + v3s16(0,-1,0)));
            v.y = below.walkable && !below.isLiquid() ? 0.0f : -0.8f;
            if (v.length() > 1.0f)
                v.normalize();
        }
        cache.emplace(p, v);
        return v;
    }
    bool liquid(v3s16 p) {
        auto found = liquid_cache.find(p);
        if (found != liquid_cache.end())
            return found->second;
        const auto &f = ndef->get(node(p));
        const bool value = f.isLiquid() && f.light_source >= 6;
        liquid_cache.emplace(p, value);
        return value;
    }
public:
    explicit LavaFlow(GoannaSession &s) : session(s), ndef(s.nodeDefs()) {}
    Vector3 direction(Vector3 world) {
        // Outward gradient of the trilinear liquid occupancy. Unlike the
        // face normal, this is identical on both sides of a mesh corner.
        Vector3 p(world.x, world.y, -world.z);
        v3s16 base((s16)std::floor(p.x), (s16)std::floor(p.y), (s16)std::floor(p.z));
        Vector3 f(p.x-base.X, p.y-base.Y, p.z-base.Z), gradient;
        for (int z = 0; z < 2; ++z)
            for (int y = 0; y < 2; ++y)
                for (int x = 0; x < 2; ++x) {
                    if (!liquid(base + v3s16(x,y,z)))
                        continue;
                    const float wx = x ? f.x : 1-f.x;
                    const float wy = y ? f.y : 1-f.y;
                    const float wz = z ? f.z : 1-f.z;
                    gradient += Vector3((x ? 1 : -1)*wy*wz,
                            (y ? 1 : -1)*wx*wz, (z ? 1 : -1)*wx*wy);
                }
        Vector3 outward(-gradient.x, -gradient.y, gradient.z);
        return outward.length_squared() > 0.001f ? outward.normalized() : Vector3(0,1,0);
    }
    float edgeWeight(Vector3 world) {
        // Distance to the actual liquid footprint, not to each tile's UV
        // border. Internal block edges keep full relief. Include the layer
        // immediately below so a waterfall/lower pool join stays connected.
        Vector3 p(world.x, world.y, -world.z);
        v3s16 base((s16)std::floor(p.x+0.5f), (s16)std::floor(p.y+0.5f),
                (s16)std::floor(p.z+0.5f));
        // Shore taper belongs to shallow spreading liquid, not the sides
        // of a descending column. Include cells touching either side of a
        // boundary so the result is the same for neighbouring mesh faces.
        for (int z = -1; z <= 0; ++z)
            for (int y = -1; y <= 0; ++y)
                for (int x = -1; x <= 0; ++x) {
                    const v3s16 q = base + v3s16(x,y,z);
                    if (std::abs(p.x-q.X) > 0.501f || std::abs(p.y-q.Y) > 0.501f ||
                            std::abs(p.z-q.Z) > 0.501f || !liquid(q))
                        continue;
                    const MapNode n = node(q);
                    if ((ndef->get(n).liquid_type == LIQUID_FLOWING && (n.param2 & LIQUID_FLOW_DOWN_MASK)) ||
                            (liquid(q+v3s16(0,1,0)) && liquid(q+v3s16(0,-1,0))))
                        return 1.0f;
                }
        float distance = 0.6f;
        for (int z = -1; z <= 1; ++z)
            for (int x = -1; x <= 1; ++x) {
                const v3s16 q = base + v3s16(x,0,z);
                if (liquid(q) || liquid(q + v3s16(0,-1,0)))
                    continue;
                const float dx = std::max(0.0f, std::abs(p.x-q.X)-0.5f);
                const float dz = std::max(0.0f, std::abs(p.z-q.Z)-0.5f);
                distance = std::min(distance, std::sqrt(dx*dx+dz*dz));
            }
        float w = std::clamp(distance/0.6f, 0.0f, 1.0f);
        return w*w*(3.0f-2.0f*w);
    }
    Vector2 sample(Vector3 world) {
        Vector3 p(world.x, world.y, -world.z);
        v3s16 base((s16)std::floor(p.x), (s16)std::floor(p.y), (s16)std::floor(p.z));
        Vector3 f(p.x-base.X, p.y-base.Y, p.z-base.Z), v;
        for (int z = 0; z < 2; ++z)
            for (int y = 0; y < 2; ++y)
                for (int x = 0; x < 2; ++x)
                    v += at(base + v3s16(x,y,z)) * (x ? f.x : 1-f.x)
                            * (y ? f.y : 1-f.y) * (z ? f.z : 1-f.z);
        // Same oblique projection as the shader. It is continuous around
        // top/side corners, unlike switching UV axes at each face.
        return Vector2(v.x + 0.43f*v.y, v.z + 0.71f*v.y);
    }
};
}

void prepareLavaSurface(Array &arrays, GoannaSession &session) {
    const PackedVector3Array pos = arrays[Mesh::ARRAY_VERTEX];
    const PackedVector3Array norm = arrays[Mesh::ARRAY_NORMAL];
    const PackedColorArray colour = arrays[Mesh::ARRAY_COLOR];
    const PackedVector2Array uv2 = arrays[Mesh::ARRAY_TEX_UV2];
    const PackedByteArray light = arrays[Mesh::ARRAY_CUSTOM0];
    const PackedInt32Array indices = arrays[Mesh::ARRAY_INDEX];
    PackedVector3Array out_pos, out_norm;
    PackedVector2Array out_uv, out_uv2;
    PackedColorArray out_colour;
    PackedByteArray out_light;
    PackedInt32Array out_indices;
    PackedFloat32Array out_direction;
    LavaFlow flow(session);
    for (int t = 0; t < indices.size(); t += 3) {
        const int a = indices[t], b = indices[t+1], c = indices[t+2];
        // Eight segments per node. Both halves of a quad and neighbouring
        // faces share the edge samples, so displaced silhouettes stay closed.
        const Vector3 extent = (pos[b]-pos[a]).abs().max((pos[c]-pos[a]).abs());
        const int steps = std::max(1, (int)std::ceil(std::max({extent.x, extent.y, extent.z}))) * 8;
        std::vector<std::vector<int>> grid(steps+1);
        for (int y = 0; y <= steps; ++y) {
            grid[y].resize(steps-y+1);
            for (int x = 0; x <= steps-y; ++x) {
                float wb = (float)x/steps, wc = (float)y/steps, wa = 1-wb-wc;
                Vector3 p = pos[a]*wa + pos[b]*wb + pos[c]*wc;
                grid[y][x] = out_pos.size();
                out_pos.push_back(p);
                const Vector3 direction = flow.direction(p);
                out_direction.push_back(direction.x);
                out_direction.push_back(direction.y);
                out_direction.push_back(direction.z);
                out_norm.push_back((norm[a]*wa + norm[b]*wb + norm[c]*wc).normalized());
                out_uv.push_back(flow.sample(p));
                out_uv2.push_back(uv2[a]);
                Color tint = colour[a]*wa + colour[b]*wb + colour[c]*wc;
                // Lava is opaque; alpha carries shoreline relief coverage.
                tint.a = flow.edgeWeight(p);
                out_colour.push_back(tint);
                for (int k = 0; k < 4; ++k)
                    out_light.push_back((uint8_t)std::clamp((int)std::lround(
                            light[a*4+k]*wa + light[b*4+k]*wb + light[c*4+k]*wc), 0, 255));
            }
        }
        for (int y = 0; y < steps; ++y)
            for (int x = 0; x < steps-y; ++x) {
                out_indices.push_back(grid[y][x]);
                out_indices.push_back(grid[y][x+1]);
                out_indices.push_back(grid[y+1][x]);
                if (x+1 < steps-y) {
                    out_indices.push_back(grid[y][x+1]);
                    out_indices.push_back(grid[y+1][x+1]);
                    out_indices.push_back(grid[y+1][x]);
                }
            }
    }
    arrays[Mesh::ARRAY_VERTEX] = out_pos;
    arrays[Mesh::ARRAY_NORMAL] = out_norm;
    arrays[Mesh::ARRAY_TANGENT] = Variant(); // world-space relief needs no tangent basis
    arrays[Mesh::ARRAY_TEX_UV] = out_uv;
    arrays[Mesh::ARRAY_TEX_UV2] = out_uv2;
    arrays[Mesh::ARRAY_COLOR] = out_colour;
    arrays[Mesh::ARRAY_CUSTOM0] = out_light;
    arrays[Mesh::ARRAY_CUSTOM1] = out_direction;
    arrays[Mesh::ARRAY_INDEX] = out_indices;
}
}
