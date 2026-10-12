// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
//
// Offline checks of a shader pack's own shadow map (docs/design/
// iris-compat.md, rung 7): the settings read from a pack's const
// directives, the shadowModelView and shadowProjection matrices
// (iris_shadow.h), and the shadow program's translation, with the gbuffers
// programs' reads of the map it makes (iris_gbuffers.h). No Godot and no
// GPU. Built on request:
//
//   cmake --build build --target check (or goanna_iris_shadow_test)
//   build/goanna_iris_shadow_test
//
// With a pack directory and an output directory it also translates the
// pack's shadow program for each surface and writes the shaders there:
//
//   build/goanna_iris_shadow_test /path/to/pack /path/to/out

#include "iris/iris_gbuffers.h"
#include "iris/iris_pack.h"
#include "iris/iris_shadow.h"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>

using namespace goanna::iris;

static int g_failures = 0;

static void check(bool ok, const std::string &what) {
    if (!ok) {
        ++g_failures;
        std::printf("FAIL: %s\n", what.c_str());
    }
}

static bool near(float a, float b, float eps = 1e-4f) { return std::fabs(a - b) <= eps; }

static bool contains(const std::string &s, const std::string &part) { return s.find(part) != std::string::npos; }

static void testSettings() {
    ShadowSettings d = readShadowSettings({}, {});
    check(d.resolution == 1024 && near(d.distance, 160.0f) && near(d.interval, 2.0f), "defaults");
    check(near(d.near_plane, 0.05f) && near(d.far_plane, 256.0f), "default depth range");
    // Eclipse's own lines, as the loader gathers them.
    ShadowSettings e = readShadowSettings(
            {{"shadowMapResolution", "1024"}, {"sunPathRotation", "-40.0f"}, {"shadowDistance", "120.0f"}}, {});
    check(e.resolution == 1024, "shadowMapResolution read");
    check(near(e.distance, 120.0f), "shadowDistance with an f suffix");
    check(near(e.sun_path_rotation, -40.0f) && !e.notes.empty(), "sunPathRotation read, and noted as not applied");
    // A directive written as an option's name, as menus do.
    ShadowSettings o = readShadowSettings({{"shadowMapResolution", "SHADOW_RES"}}, {{"SHADOW_RES", "2048"}});
    check(o.resolution == 2048, "resolution through an option");
    ShadowSettings big = readShadowSettings({{"shadowMapResolution", "65536"}}, {});
    check(big.resolution == 8192 && !big.notes.empty(), "resolution clamped and noted");
    ShadowSettings fov = readShadowSettings({{"shadowMapFov", "90.0"}}, {});
    check(!fov.notes.empty(), "a perspective shadow map is noted as unsupported");
}

static void testMatrices() {
    // The sun overhead, the camera off grid.
    const float sun[3] = {0.0f, 3.0f, 0.0f};
    const float cam[3] = {10.3f, 64.7f, -5.2f};
    Mat4 mv;
    shadowModelView(sun, cam, 2.0f, mv);
    // The light's direction is the view's +z: the eye looks down -z at
    // the player, from the sun.
    float dir[4] = {0.0f, 1.0f, 0.0f, 0.0f}, out[4];
    transform(mv, dir, out);
    check(near(out[0], 0.0f) && near(out[1], 0.0f) && near(out[2], 1.0f), "the sun's direction is +z");
    // A rotation: columns of unit length and at right angles.
    for (int a = 0; a < 3; ++a)
        for (int b = 0; b < 3; ++b) {
            float dot = 0.0f;
            for (int r = 0; r < 3; ++r) dot += mv[a * 4 + r] * mv[b * 4 + r];
            check(near(dot, a == b ? 1.0f : 0.0f), "orthonormal " + std::to_string(a) + std::to_string(b));
        }
    // The grid point under the camera (10, 64, -6 for a 2 node interval)
    // is 100 nodes in front of the eye, on its axis.
    float grid[4] = {10.0f - cam[0], 64.0f - cam[1], -6.0f - cam[2], 1.0f};
    transform(mv, grid, out);
    check(near(out[0], 0.0f, 1e-3f) && near(out[1], 0.0f, 1e-3f) && near(out[2], -100.0f, 1e-3f),
            "grid point on the axis, 100 out: " + std::to_string(out[0]) + " " + std::to_string(out[1]) + " " +
                    std::to_string(out[2]));
    // Something above the player is nearer the sun's eye.
    float up[4] = {0.0f, 10.0f, 0.0f, 1.0f}, base[4] = {0.0f, 0.0f, 0.0f, 1.0f}, o2[4];
    transform(mv, up, out);
    transform(mv, base, o2);
    check(out[2] > o2[2], "higher is nearer the light");
    // Snapping: two cameras in the same cell put a world point at the same
    // place in the light's view, so texels do not crawl as the player walks.
    const float cam2[3] = {11.1f, 65.9f, -4.1f};
    Mat4 mv2;
    shadowModelView(sun, cam2, 2.0f, mv2);
    float w[3] = {3.0f, 60.0f, 7.0f};
    float p1[4] = {w[0] - cam[0], w[1] - cam[1], w[2] - cam[2], 1.0f};
    float p2[4] = {w[0] - cam2[0], w[1] - cam2[1], w[2] - cam2[2], 1.0f};
    float q1[4], q2[4];
    transform(mv, p1, q1);
    transform(mv2, p2, q2);
    check(near(q1[0], q2[0], 1e-3f) && near(q1[1], q2[1], 1e-3f) && near(q1[2], q2[2], 1e-3f),
            "same cell, same light space");
    // Interval 0 follows the camera exactly.
    Mat4 mv0;
    shadowModelView(sun, cam, 0.0f, mv0);
    transform(mv0, base, out);
    check(near(out[0], 0.0f) && near(out[1], 0.0f) && near(out[2], -100.0f), "interval 0: the player on the axis");
    // A low sun in the east: its direction is still +z, and the light's x
    // axis stays across the sun's path (no spin as the sun moves).
    const float east[3] = {1.0f, 0.2f, 0.0f};
    Mat4 me;
    shadowModelView(east, cam, 2.0f, me);
    float ed[4] = {1.0f, 0.2f, 0.0f, 0.0f};
    transform(me, ed, out);
    float len = std::sqrt(1.0f + 0.04f);
    check(near(out[2], len), "low sun along +z");
    check(near(me[2 * 4 + 0], 0.0f) && near(mv[2 * 4 + 0], 0.0f), "x stays perpendicular to the sun's axis");

    Mat4 proj;
    shadowProjection(120.0f, 0.05f, 256.0f, proj);
    float corner[4] = {120.0f, 120.0f, -0.05f, 1.0f};
    transform(proj, corner, out);
    check(near(out[0], 1.0f) && near(out[1], 1.0f) && near(out[2], -1.0f) && near(out[3], 1.0f),
            "near corner to (1, 1, -1)");
    float back[4] = {-120.0f, -120.0f, -256.0f, 1.0f};
    transform(proj, back, out);
    check(near(out[0], -1.0f) && near(out[1], -1.0f) && near(out[2], 1.0f), "far corner to (-1, -1, 1)");
    // The player, 100 out, lies between: the map has room for the ground
    // and for what stands up to 100 nodes above it.
    float player[4] = {0.0f, 0.0f, -100.0f, 1.0f};
    transform(proj, player, out);
    check(out[2] > -1.0f && out[2] < 1.0f, "the player inside the depth range");
    // The depth convention through the shell and the copy: the shell writes
    // (w - z) / 2 as Vulkan depth into a reversed buffer, the copy stores
    // one minus it, and that is the pack's own z * 0.5 + 0.5.
    float clip[4];
    Mat4 vp;
    mul(proj, mv, vp);
    float some[4] = {4.0f, -3.0f, 9.0f, 1.0f};
    transform(vp, some, clip);
    float stored = 1.0f - 0.5f * (clip[3] - clip[2]) / clip[3];
    check(near(stored, clip[2] / clip[3] * 0.5f + 0.5f), "stored depth is the pack's window depth");

    // Inverses.
    Mat4 inv, id;
    affineInverse(mv, inv);
    mul(mv, inv, id);
    bool ok = true;
    for (int k = 0; k < 16; ++k) ok = ok && near(id[k], (k % 5 == 0) ? 1.0f : 0.0f, 1e-4f);
    check(ok, "modelview inverse");
    affineInverse(proj, inv);
    mul(proj, inv, id);
    ok = true;
    for (int k = 0; k < 16; ++k) ok = ok && near(id[k], (k % 5 == 0) ? 1.0f : 0.0f, 1e-4f);
    check(ok, "projection inverse");
}

static std::string translate(const std::string &vsh, const std::string &fsh, GbuffersSurface s, bool shadow,
        GbuffersResult &r, std::string &err) {
    Program p;
    p.name = shadow ? "shadow" : "test";
    p.vsh = vsh;
    p.fsh = fsh;
    GbuffersOptions o;
    o.surface = s;
    o.shadow_pass = shadow;
    o.label = "test";
    err.clear();
    if (!translateGbuffers(p, o, r, err)) return "";
    return r.code;
}

static void testTranslation() {
    GbuffersResult r;
    std::string err;
    // Eclipse's shadow program, in its shape: water moved out of the clip
    // volume, everything else through ftransform and a distortion.
    const std::string vsh = "#version 460 compatibility\nattribute vec4 mc_Entity;\nvarying vec2 texcoord;\n"
                            "varying vec4 glcolor;\n"
                            "vec3 distort(vec3 pos) { float f = length(pos.xy) + 0.1; return vec3(pos.xy / f, pos.z * 0.5); }\n"
                            "void main() {\n texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;\n"
                            " glcolor = gl_Color;\n"
                            " if (abs(mc_Entity.x - 10060.0) < 0.1) { gl_Position = vec4(10.0); } else {\n"
                            "  gl_Position = ftransform();\n  gl_Position.xyz = distort(gl_Position.xyz);\n }\n}\n";
    const std::string fsh = "#version 460 compatibility\nuniform sampler2D texture;\nvarying vec2 texcoord;\n"
                            "varying vec4 glcolor;\nvoid main() {\n vec4 color = texture2D(texture, texcoord) * glcolor;\n"
                            " gl_FragData[0] = color;\n}\n";
    std::string code = translate(vsh, fsh, GbuffersSurface::ArrayOpaque, true, r, err);
    check(err.empty(), "shadow program translates: " + err);
    check(contains(code, "iris_shadow_gl_ModelViewProjectionMatrix"), "ftransform uses the light's matrices");
    check(!contains(code, "iris_gl_ModelViewProjectionMatrix"), "and not the camera's");
    check(contains(code, "POSITION = goanna_shadow_position(goanna_gl_Position, CAMERA_VISIBLE_LAYERS);"),
            "clip position straight to POSITION, in the shadow camera only: " + code);
    check(!contains(code, "goanna_unproject"), "no unprojection through the player camera");
    check(contains(code, "#define GOANNA_IRIS_SHADOW"), "the shell's shadow helpers");
    check(contains(code, "cull_disabled"), "both faces cast");
    check(contains(code, "ALBEDO = clamp(goanna_out_0.rgb, 0.0, 1.0);"), "shadowcolor0 as written, not linearised");
    check(contains(code, "texture(albedo_array"), "the atlas read goes to the array");
    check(r.moves_vertices, "the distortion moves vertices");

    // The fixed function matrices by name are the light's.
    code = translate("void main() { gl_Position = gl_ProjectionMatrix * (gl_ModelViewMatrix * gl_Vertex); }\n",
            "void main() { gl_FragData[0] = vec4(1.0); }\n", GbuffersSurface::SingleCutout, true, r, err);
    check(err.empty(), "matrix shadow program translates: " + err);
    check(contains(code, "iris_shadowProjection") && contains(code, "iris_shadow_gl_ModelViewMatrix"),
            "gl_ProjectionMatrix and gl_ModelViewMatrix are the light's: " + code);
    check(contains(code, "discard"), "a cut-out surface is alpha tested in the shadow pass too");
    // The same program as a gbuffers program keeps the camera's.
    code = translate("void main() { gl_Position = gl_ProjectionMatrix * (gl_ModelViewMatrix * gl_Vertex); }\n",
            "void main() { gl_FragData[0] = vec4(1.0); }\n", GbuffersSurface::ArrayOpaque, false, r, err);
    check(contains(code, "iris_gbufferProjection") && !contains(code, "iris_shadow_gl_"),
            "a gbuffers program is untouched");
    check(!contains(code, "POSITION ="), "a gbuffers program does not write POSITION");

    // A gbuffers program reading the map: plain reads and comparisons.
    code = translate("void main() { gl_Position = ftransform(); }\n",
            "uniform sampler2D shadowtex0;\nuniform sampler2D shadowtex1;\nuniform sampler2D shadowcolor0;\n"
            "uniform sampler2DShadow shadow;\nvarying vec4 sp;\nvoid main() {\n"
            " float a = texture2D(shadowtex1, sp.xy).r;\n float b = texture2D(shadowtex0, sp.xy).r;\n"
            " vec4 c = texture2D(shadowcolor0, sp.xy);\n float d = shadow2D(shadow, sp.xyz).r;\n"
            " gl_FragData[0] = vec4(a, b, d, 1.0) * c;\n}\n",
            GbuffersSurface::ArrayOpaque, false, r, err);
    check(err.empty(), "shadow reads translate: " + err);
    check(contains(code, "texture(iris_shadowtex1, "), "shadowtex1 is the map: " + code);
    check(contains(code, "texture(iris_shadowtex0, "), "shadowtex0 is the map");
    check(contains(code, "texture(iris_shadowcolor0, "), "shadowcolor0 is the map's colour");
    check(contains(code, "vec4(step((sp.xyz).z, texture(iris_shadowtex0, (sp.xyz).xy).r))"),
            "shadow2D compares against the map");
    check(contains(code, "global uniform sampler2D iris_shadowtex0 : filter_nearest, repeat_disable;"),
            "the map is sampled nearest, unrepeated");
}

int main(int argc, char **argv) {
    if (argc >= 3) {
        Pack pack;
        std::string err;
        if (!pack.load(argv[1], err)) {
            std::printf("load failed: %s\n", err.c_str());
            return 1;
        }
        ShadowSettings st = readShadowSettings(pack.consts(), pack.options());
        std::printf("%s: resolution %d, distance %.1f, interval %.1f\n", pack.name().c_str(), st.resolution,
                st.distance, st.interval);
        for (auto &n : st.notes) std::printf("  note: %s\n", n.c_str());
        Program p;
        if (!pack.program("shadow", p, err)) {
            std::printf("no shadow program: %s\n", err.c_str());
            return 1;
        }
        const char *names[] = {"shadow_terrain", "shadow_cutout", "shadow_foliage"};
        const GbuffersSurface kinds[] = {GbuffersSurface::ArrayOpaque, GbuffersSurface::ArrayCutout,
                GbuffersSurface::SingleCutout};
        int bad = 0;
        for (int i = 0; i < 3; ++i) {
            GbuffersOptions o;
            o.surface = kinds[i];
            o.shadow_pass = true;
            o.label = pack.name() + "/shadow";
            GbuffersResult r;
            if (!translateGbuffers(p, o, r, err)) {
                std::printf("%s: %s\n", names[i], err.c_str());
                ++bad;
                continue;
            }
            std::ofstream(std::string(argv[2]) + "/" + names[i] + ".gdshader") << r.code;
            std::printf("%s: %zu warnings\n", names[i], r.warnings.size());
            for (auto &w : r.warnings) std::printf("  %s\n", w.c_str());
        }
        return bad ? 1 : 0;
    }
    testSettings();
    testMatrices();
    testTranslation();
    if (g_failures) {
        std::printf("%d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("goanna_iris_shadow_test: all passed\n");
    return 0;
}
