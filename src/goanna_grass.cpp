// SPDX-License-Identifier: LGPL-2.1-or-later
#include "goanna_grass.h"
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <set>
#include <string>
#include <vector>

using namespace godot;

void goanna::append_grass(const Ref<ArrayMesh> &mesh, bool lod, Node *owner) {
    // Remember the coordinate convention even when disabled, so the saved
    // graphics option can add grass to already-published terrain in place.
    mesh->set_meta("goanna_grass_lod", lod);
    if (!(bool)owner->get_meta("goanna_grass_enabled", false)) return;
    PackedVector3Array vertices;
    PackedColorArray colours;
    PackedFloat32Array bounds, roots;
    PackedInt32Array indices;
    struct Patch { float x0,z0,x1,z1,y; Color col; float sky,ao; };
    std::vector<Patch> patches;
    // A top quad arrives as two triangles with the same rectangular bounds.
    std::set<std::array<float, 6>> seen;
    const int source_count = mesh->get_surface_count();
    for (int s = 0; s < source_count; ++s) {
        Ref<Material> material = mesh->surface_get_material(s);
        if (material.is_null() || !material->has_meta("goanna_grass_layers")) continue;
        const Dictionary layers = material->get_meta("goanna_grass_layers");
        if (layers.is_empty()) continue;
        const Array a = mesh->surface_get_arrays(s);
        const PackedVector3Array v = a[Mesh::ARRAY_VERTEX], n = a[Mesh::ARRAY_NORMAL];
        const PackedVector2Array uv2 = a[Mesh::ARRAY_TEX_UV2];
        const PackedColorArray c = a[Mesh::ARRAY_COLOR];
        const PackedInt32Array ix = a[Mesh::ARRAY_INDEX];
        const PackedByteArray light = a[Mesh::ARRAY_CUSTOM0];
        if (n.size() != v.size() || uv2.size() != v.size()) continue;
        for (int j = 0; j + 2 < ix.size(); j += 3) {
            const int i0 = ix[j], i1 = ix[j + 1], i2 = ix[j + 2];
            const int layer = (int)std::round(uv2[i0].x);
            if (!layers.has(layer) || n[i0].y < 0.999f || n[i1].y < 0.999f || n[i2].y < 0.999f) continue;
            const Vector3 p = v[i0], q = v[i1], r = v[i2];
            if (std::abs(p.y - q.y) > 0.001f || std::abs(p.y - r.y) > 0.001f) continue;
            const float x0 = std::min({p.x, q.x, r.x}), x1 = std::max({p.x, q.x, r.x});
            const float z0 = std::min({p.z, q.z, r.z}), z1 = std::max({p.z, q.z, r.z});
            const float area = (q - p).cross(r - p).length();
            if (x1 - x0 < 0.1f || z1 - z0 < 0.1f || std::abs(area - (x1-x0)*(z1-z0)) > 0.001f) continue;
            if (!seen.insert({x0, z0, x1, z1, p.y, (float)layer}).second) continue;
            Color col = layers[layer];
            if (c.size() == v.size()) col *= c[i0];
            const float sky = light.size() == v.size()*4 ? light[i0*4+1]/255.0f : 1.0f;
            const float ao = light.size() == v.size()*4 ? light[i0*4+2]/255.0f : 1.0f;
            const float offset = lod ? 0.0f : 0.5f;
            patches.push_back({std::floor(x0+offset+0.0001f)-offset,
                    std::floor(z0+offset+0.0001f)-offset,
                    std::ceil(x1+offset-0.0001f)-offset,
                    std::ceil(z1+offset-0.0001f)-offset,p.y,col,sky,ao});
        }
    }
    // Merge coplanar equal-colour patches in two sorted passes. This keeps
    // volume overdraw proportional to terrain shape, not to individual nodes.
    for (bool along_z : {false,true}) {
        auto key = [along_z](const Patch &p) {
            return std::array<float,10>{p.y,p.col.r,p.col.g,p.col.b,p.sky,p.ao,
                along_z?p.x0:p.z0,along_z?p.x1:p.z1,along_z?p.z0:p.x0,along_z?p.z1:p.x1};
        };
        std::sort(patches.begin(),patches.end(),[&](const Patch &a,const Patch &b){ return key(a)<key(b); });
        std::vector<Patch> merged;
        for (const Patch &p : patches) {
            if (!merged.empty()) {
                auto a=key(merged.back()), b=key(p);
                if (std::equal(a.begin(),a.begin()+8,b.begin()) && std::abs(a[9]-b[8])<0.001f) {
                    if (along_z) merged.back().z1=p.z1; else merged.back().x1=p.x1;
                    continue;
                }
            }
            merged.push_back(p);
        }
        patches=std::move(merged);
    }
    for (const Patch &p : patches) {
            const float x0=p.x0,z0=p.z0,x1=p.x1,z1=p.z1;
            const int base = vertices.size();
            // Margin includes bent blades rooted inside this patch. Adjacent
            // patches can overlap in volume; real hit depth resolves visibility.
            for (int k = 0; k < 8; ++k) {
                vertices.push_back(Vector3(k&1 ? x1+0.9f : x0-0.9f,
                        p.y + (k&2 ? 1.24f : 0.002f), k&4 ? z1+0.9f : z0-0.9f));
                colours.push_back(p.col);
                for (float f : {x0, z0, x1, z1}) bounds.push_back(f);
                for (float f : {p.y, p.sky, p.ao, 0.0f}) roots.push_back(f);
            }
            // Godot clockwise outward faces; the shader draws the exit faces.
            const int cube[] = {0,1,3,0,3,2,4,6,7,4,7,5,0,4,5,0,5,1,
                    2,3,7,2,7,6,0,2,6,0,6,4,1,5,7,1,7,3};
            for (int k : cube) indices.push_back(base + k);
    }
    if (vertices.is_empty()) return;
    Array a;
    a.resize(Mesh::ARRAY_MAX);
    a[Mesh::ARRAY_VERTEX] = vertices;
    a[Mesh::ARRAY_COLOR] = colours;
    a[Mesh::ARRAY_CUSTOM0] = bounds;
    a[Mesh::ARRAY_CUSTOM1] = roots;
    a[Mesh::ARRAY_INDEX] = indices;
    const uint64_t flags = (uint64_t)Mesh::ARRAY_CUSTOM_RGBA_FLOAT << Mesh::ARRAY_FORMAT_CUSTOM0_SHIFT |
            (uint64_t)Mesh::ARRAY_CUSTOM_RGBA_FLOAT << Mesh::ARRAY_FORMAT_CUSTOM1_SHIFT;
    Ref<ShaderMaterial> material;
    if (owner->has_meta("goanna_grass_material")) material=owner->get_meta("goanna_grass_material");
    if (material.is_null()) {
        material.instantiate();
        material->set_shader(ResourceLoader::get_singleton()->load("res://shaders/grass_volume.gdshader"));
        material->set_meta("goanna_grass_volume", true);
        owner->set_meta("goanna_grass_material",material);
    }
    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, a, TypedArray<Array>(), Dictionary(), flags);
    mesh->surface_set_material(source_count, material);
}

void goanna::update_grass_interactors(Node *owner, const PackedVector4Array &actors) {
    if (!owner->has_meta("goanna_grass_material")) return;
    Ref<ShaderMaterial> material=owner->get_meta("goanna_grass_material");
    material->set_shader_parameter("interaction_count",std::min(8,(int)actors.size()));
    PackedVector4Array padded=actors;
    padded.resize(8);
    material->set_shader_parameter("interaction_centres",padded);
}
