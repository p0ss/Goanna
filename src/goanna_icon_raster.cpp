// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>
// Copyright (C) 2024 cx384
//
// The inventory shading here re-expresses Luanti code: applyShadeFactor and
// colorizeMeshBuffer's light from client/mesh.cpp, the projection and light
// of gui/drawItemStack.cpp, and the texel and alpha rules of
// client/shaders/inventory_shader. Each is marked at its definition.

// See goanna_icon_raster.h. The references for every rule below are
// luanti/src/gui/drawItemStack.cpp (projection, light, draw order),
// luanti/src/client/mesh.cpp (colorizeMeshBuffer, applyShadeFactor),
// luanti/client/shaders/inventory_shader (the fragment maths) and
// luanti/irr/src/OpenGL (GL_CW front faces, depth LEQUAL, no blending for
// alpha ref). Alpha blended materials write depth too: their ZWriteEnable is
// EZW_AUTO, which would leave depth alone, but CSceneManager::drawAll sets
// the driver's AllowZWriteOnTransparent every frame and nothing clears it,
// so by the time the HUD and formspecs draw, it is on.

#include "goanna_icon_raster.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include <IIndexBuffer.h>
#include <S3DVertex.h>

namespace goanna {

namespace {

// applyShadeFactor in luanti/src/client/mesh.cpp, which is file static there.
void applyShade(video::SColor &c, f32 factor) {
    auto shade = [factor](u32 v) {
        return (u32)std::clamp((s32)std::floor(v * factor + 0.5f), 0, 255);
    };
    c.setRed(shade(c.getRed()));
    c.setGreen(shade(c.getGreen()));
    c.setBlue(shade(c.getBlue()));
}

struct Rgba {
    f32 r = 0, g = 0, b = 0, a = 0;
};

// Nearest texel at (u, v), as GL samples with NEAREST: texel floor(u * w),
// clamped to the edge or wrapped by the material's wrap mode. Row 0 is the
// image's top row, which is where Irrlicht puts v = 0.
Rgba sampleNearest(const video::IImage *img, f32 u, f32 v, bool clamp_u, bool clamp_v) {
    const core::dimension2du &d = img->getDimension();
    const s32 w = (s32)d.Width, h = (s32)d.Height;
    if (w <= 0 || h <= 0)
        return {1, 1, 1, 1};
    s32 x = (s32)std::floor(u * w), y = (s32)std::floor(v * h);
    if (clamp_u)
        x = std::clamp(x, 0, w - 1);
    else
        x = ((x % w) + w) % w;
    if (clamp_v)
        y = std::clamp(y, 0, h - 1);
    else
        y = ((y % h) + h) % h;
    video::SColor c;
    if (img->getColorFormat() == video::ECF_A8R8G8B8) {
        const u8 *row = (const u8 *)img->getData() + (size_t)y * img->getPitch();
        c.color = ((const u32 *)row)[x];
    } else {
        c = img->getPixel((u32)x, (u32)y);
    }
    const f32 k = 1.0f / 255.0f;
    return {c.getRed() * k, c.getGreen() * k, c.getBlue() * k, c.getAlpha() * k};
}

// Straight alpha "over": what blending onto the screen with
// SRC_ALPHA, ONE_MINUS_SRC_ALPHA gives, kept associative so the icon drawn
// over any slot background matches drawing the mesh onto it directly.
void over(Rgba &dst, const Rgba &src) {
    const f32 out_a = src.a + dst.a * (1.0f - src.a);
    if (out_a <= 0.0f) {
        dst = {};
        return;
    }
    const f32 kd = dst.a * (1.0f - src.a);
    dst.r = (src.r * src.a + dst.r * kd) / out_a;
    dst.g = (src.g * src.a + dst.g * kd) / out_a;
    dst.b = (src.b * src.a + dst.b * kd) / out_a;
    dst.a = out_a;
}

struct ScreenVertex {
    f32 x, y, z;    // window pixels, y up; mesh z, larger is further
    f32 r, g, b;    // vertex colour, 0 to 1
    f32 u, v;
    u16 aux;
};

inline f32 edge(const ScreenVertex &a, const ScreenVertex &b, f32 px, f32 py) {
    return (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x);
}

// Top-left fill rule for a counter-clockwise triangle in y-up coordinates:
// a left edge runs downwards, a top edge is horizontal and runs leftwards.
// Pixels exactly on such an edge belong to this triangle, so two triangles
// sharing an edge never both draw, or both skip, the pixels on it.
inline bool topLeft(const ScreenVertex &a, const ScreenVertex &b) {
    return (a.y == b.y && b.x < a.x) || b.y < a.y;
}

} // namespace

video::SColor shadeInventoryVertex(video::SColor base, v3f normal) {
    // drawItemStack's light, in view space; the mesh is already rotated.
    static const v3f dir_light = [] {
        v3f d(-0.6f, -1.2f, 0.4f);
        d.normalize();
        return d * 0.7f;
    }();
    if (normal == v3f())
        return base; // colorizeMeshBuffer leaves it "fully lit"
    normal.normalize();
    const f32 intensity = std::fabs(normal.dotProduct(-dir_light));
    applyShade(base, std::min(1.0f, 0.5f + intensity));
    return base;
}

void rasteriseItemIcon(const IconJob &job, u32 size, std::vector<u8> &rgba) {
    const u32 npx = size * size;
    std::vector<Rgba> colour(npx);
    std::vector<f32> depth(npx, std::numeric_limits<f32>::infinity());
    // The projection is buildProjectionMatrixOrthoLH(2, 2, -1, 100) with a
    // view that, for an unclipped slot, only rescales z: mesh x and y in
    // -1 to 1 fill the slot, and depth order is mesh z order.
    const f32 half = size * 0.5f;
    std::vector<ScreenVertex> sv;

    for (const IconBuffer &b : job.buffers) {
        const scene::IMeshBuffer *buf = b.buffer;
        if (!buf || buf->getVertexType() != video::EVT_STANDARD)
            continue;
        const auto *verts = (const video::S3DVertex *)buf->getVertices();
        const u32 nv = buf->getVertexCount();
        const u32 ni = buf->getIndexCount();
        const bool idx16 = buf->getIndexType() == video::EIT_16BIT;
        const void *idx = buf->getIndexBuffer()->getData();
        if (!nv || ni < 3 || !idx)
            continue;
        auto index = [&](u32 i) -> u32 {
            return idx16 ? ((const u16 *)idx)[i] : ((const u32 *)idx)[i];
        };

        sv.resize(nv);
        for (u32 i = 0; i < nv; ++i) {
            const video::S3DVertex &v = verts[i];
            // setMeshBufferColor or colorizeMeshBuffer replace the vertex
            // colours the mesh was generated with; alpha does not reach the
            // shader's output.
            video::SColor c = job.needs_shading ? shadeInventoryVertex(b.color, v.Normal) : b.color;
            ScreenVertex &s = sv[i];
            s.x = (v.Pos.X + 1.0f) * half;
            s.y = (v.Pos.Y + 1.0f) * half;
            s.z = v.Pos.Z + (b.depth_bias ? 1e-4f : 0.0f);
            s.r = c.getRed() / 255.0f;
            s.g = c.getGreen() / 255.0f;
            s.b = c.getBlue() / 255.0f;
            s.u = v.TCoords.X;
            s.v = v.TCoords.Y;
            s.aux = v.Aux;
        }

        for (u32 t = 0; t + 2 < ni; t += 3) {
            u32 i0 = index(t), i1 = index(t + 1), i2 = index(t + 2);
            if (i0 >= nv || i1 >= nv || i2 >= nv)
                continue;
            // GL's flat varyings come from the last vertex (the array layer).
            const u16 aux = sv[i2].aux;
            f32 area = edge(sv[i0], sv[i1], sv[i2].x, sv[i2].y);
            if (area == 0.0f)
                continue;
            // Irrlicht sets glFrontFace(GL_CW): clockwise in window
            // coordinates (y up) is the front. Counter-clockwise is the back.
            if (area > 0.0f && b.cull_back)
                continue;
            if (area < 0.0f) {
                std::swap(i1, i2);
                area = -area;
            }
            const ScreenVertex &v0 = sv[i0], &v1 = sv[i1], &v2 = sv[i2];

            const f32 minx = std::min({v0.x, v1.x, v2.x}), maxx = std::max({v0.x, v1.x, v2.x});
            const f32 miny = std::min({v0.y, v1.y, v2.y}), maxy = std::max({v0.y, v1.y, v2.y});
            // Pixel centres at i + 0.5 inside the box.
            const s32 x0 = std::max(0, (s32)std::ceil(minx - 0.5f));
            const s32 x1 = std::min((s32)size - 1, (s32)std::floor(maxx - 0.5f));
            const s32 y0 = std::max(0, (s32)std::ceil(miny - 0.5f));
            const s32 y1 = std::min((s32)size - 1, (s32)std::floor(maxy - 0.5f));
            if (x0 > x1 || y0 > y1)
                continue;
            const bool tl0 = topLeft(v1, v2), tl1 = topLeft(v2, v0), tl2 = topLeft(v0, v1);
            const video::IImage *tex = nullptr;
            if (!b.layers.empty())
                tex = b.layers[aux < b.layers.size() ? aux : 0];
            const f32 inv_area = 1.0f / area;

            for (s32 py = y0; py <= y1; ++py) {
                const f32 cy = py + 0.5f;
                for (s32 px = x0; px <= x1; ++px) {
                    const f32 cx = px + 0.5f;
                    const f32 w0 = edge(v1, v2, cx, cy);
                    const f32 w1 = edge(v2, v0, cx, cy);
                    const f32 w2 = edge(v0, v1, cx, cy);
                    if (w0 < 0 || w1 < 0 || w2 < 0)
                        continue;
                    if ((w0 == 0 && !tl0) || (w1 == 0 && !tl1) || (w2 == 0 && !tl2))
                        continue;
                    const f32 l0 = w0 * inv_area, l1 = w1 * inv_area, l2 = w2 * inv_area;
                    const u32 at = (size - 1 - (u32)py) * size + (u32)px;
                    const f32 z = l0 * v0.z + l1 * v1.z + l2 * v2.z;
                    if (z > depth[at]) // ECFN_LESSEQUAL
                        continue;
                    Rgba base{1, 1, 1, 1};
                    if (tex) {
                        const f32 u = l0 * v0.u + l1 * v1.u + l2 * v2.u;
                        const f32 v = l0 * v0.v + l1 * v1.v + l2 * v2.v;
                        base = sampleNearest(tex, u, v, b.clamp_u, b.clamp_v);
                    }
                    // inventory_shader: USE_DISCARD for alpha blended
                    // materials, USE_DISCARD_REF for alpha ref ones.
                    if (b.blend == IconBlend::AlphaBlend && base.a == 0.0f)
                        continue;
                    if (b.blend == IconBlend::AlphaRef && base.a < 0.5f)
                        continue;
                    Rgba frag{base.r * (l0 * v0.r + l1 * v1.r + l2 * v2.r),
                            base.g * (l0 * v0.g + l1 * v1.g + l2 * v2.g),
                            base.b * (l0 * v0.b + l1 * v1.b + l2 * v2.b), base.a};
                    if (b.blend == IconBlend::AlphaBlend) {
                        over(colour[at], frag);
                    } else {
                        frag.a = 1.0f;
                        colour[at] = frag;
                    }
                    depth[at] = z;
                }
            }
        }
    }

    if (job.overlay) {
        // draw2DImageFilterScaled over the whole slot, unfiltered.
        const core::dimension2du &d = job.overlay->getDimension();
        if (d.Width && d.Height) {
            for (u32 row = 0; row < size; ++row) {
                for (u32 col = 0; col < size; ++col) {
                    const f32 u = (col + 0.5f) / size, v = (row + 0.5f) / size;
                    over(colour[row * size + col], sampleNearest(job.overlay, u, v, true, true));
                }
            }
        }
    }

    rgba.resize((size_t)npx * 4);
    auto to8 = [](f32 f) { return (u8)std::clamp((s32)std::floor(f * 255.0f + 0.5f), 0, 255); };
    for (u32 i = 0; i < npx; ++i) {
        const Rgba &c = colour[i];
        rgba[i * 4 + 0] = to8(c.r);
        rgba[i * 4 + 1] = to8(c.g);
        rgba[i * 4 + 2] = to8(c.b);
        rgba[i * 4 + 3] = to8(c.a);
    }
}

} // namespace goanna
