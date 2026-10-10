// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors

// The texture and shader sources used from a mesh worker while the main
// thread adds to them, which is what a session does once content is
// prepared: the far workers resolve tiles (tileFor in goanna_lod.cpp) and a
// near worker asks for a stored carve's crack overlay and every buffer's
// shader info, while the main thread makes entity textures, item meshes and
// their shaders. Each side checks what it gets back, and a build with
// -fsanitize=thread checks the rest:
//   cmake --build build --target goanna_texture_threads_test
//   ./build/goanna_texture_threads_test

#include <atomic>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "goanna_image_hooks.h"
#include "goanna_session.h"
#include "goanna_textures.h"

using namespace goanna;

namespace {

std::atomic<int> g_failures{0};
std::atomic<int> g_checks{0};

void expect(bool condition, const std::string &message) {
    ++g_checks;
    if (!condition) {
        ++g_failures;
        std::cerr << "goanna_texture_threads_test: " << message << "\n";
    }
}

video::IImage *solid(u32 w, u32 h, video::SColor c) {
    video::IImage *img = goanna_create_image(video::ECF_A8R8G8B8, {w, h});
    img->fill(c);
    return img;
}

} // namespace

int main() {
    GoannaSession session;
    GoannaTextureSource *tsrc = session.tsrc();
    GoannaShaderSource &shsrc = session.shsrc();

    // A few source images, as prepared content would hold them.
    constexpr int kImages = 8;
    for (int i = 0; i < kImages; ++i) {
        video::IImage *img = solid(16, 16, video::SColor(255, 20 * i, 100, 200));
        tsrc->insertSourceImage("tile" + std::to_string(i) + ".png", img);
        img->drop();
    }
    const u32 base_shader = shsrc.getShader("nodes_shader", ShaderConstants{}, video::EMT_SOLID);

    constexpr int kRounds = 400;
    std::atomic<bool> go{false};

    // The worker: what tileFor, lodSurfaceTile and MapBlockMesh's crack and
    // material lookups ask for.
    std::thread worker([&] {
        while (!go.load())
            std::this_thread::yield();
        for (int r = 0; r < kRounds; ++r) {
            const std::string base = "tile" + std::to_string(r % kImages) + ".png";
            const u32 id = tsrc->getTextureId(base);
            expect(id != 0, "worker: no id for " + base);
            expect(tsrc->goannaTexture(id) != nullptr, "worker: no texture for " + base);
            expect(tsrc->imageName(id) == base, "worker: wrong name for " + base);
            const video::SColor avg = tsrc->getTextureAverageColor(base);
            expect(avg.getBlue() == 200, "worker: wrong average colour for " + base);
            // A name never seen before, as a liquid's 2D layer or the crack
            // overlay can be on first use.
            const std::string fresh = base + "^[brighten^[colorize:#00ff00:" + std::to_string(r % 255);
            const u32 fid = tsrc->getTextureId(fresh);
            expect(fid != 0 && tsrc->getTextureName(fid) == fresh, "worker: lost " + fresh);
            const ShaderInfo &info = shsrc.getShaderInfo(base_shader);
            expect(info.name == "nodes_shader", "worker: shader info moved");
        }
    });

    // The main thread: entity textures, item meshes and their shaders.
    go.store(true);
    for (int r = 0; r < kRounds; ++r) {
        const std::string base = "tile" + std::to_string((r * 3) % kImages) + ".png";
        const std::string entity = base + "^[multiply:#ff0000^[opacity:" + std::to_string(r % 255);
        const u32 id = tsrc->getTextureId(entity);
        expect(id != 0 && tsrc->getTextureName(id) == entity, "main: lost " + entity);
        ShaderConstants consts;
        consts["MATERIAL_TYPE"] = r;
        const u32 sid = shsrc.getShader("object_shader", consts, video::EMT_SOLID);
        expect(shsrc.getShaderInfo(sid).name == "object_shader", "main: shader lost");
        if (r % 50 == 0) {
            video::IImage *img = solid(16, 16, video::SColor(255, 0, 0, 200));
            tsrc->insertSourceImage("pushed" + std::to_string(r) + ".png", img);
            img->drop();
        }
    }
    worker.join();

    if (g_failures) {
        std::cerr << "goanna_texture_threads_test: " << g_failures << " of " << g_checks
                  << " checks failed\n";
        return 1;
    }
    std::cout << "goanna_texture_threads_test: " << g_checks << " checks passed\n";
    return 0;
}
